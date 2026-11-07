{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
module ToolchainCheck (toolchainChecks) where

import Control.Concurrent.STM hiding (check)
import Control.Exception (finally)
import Control.Monad (forM_, unless, when)
import Data.List (find)
import qualified Data.Text as T
import qualified Data.Text.IO as T
import System.Directory
import System.Environment (getEnvironment)
import System.FilePath
import System.IO (stderr)
import System.IO.Temp
import System.Timeout (timeout)
import VisualHaskell.Analysis.Client
import VisualHaskell.Analysis.Protocol
import VisualHaskell.Projects.Process
import VisualHaskell.Projects.Toolchains
import VisualHaskell.Semantic

-- Intentionally runs through the compiler-independent executable, not the GHC
-- API linked into this acceptance runner. Both GHCs must already be installed.
toolchainChecks :: IO ()
toolchainChecks = do
  inventory <- getCurrentDirectory >>= discoverToolchains (runToolWithEnvironment (T.hPutStrLn stderr))
  compilers <- mapM (\version -> maybe (fail ("Install GHC " <> T.unpack version <> " externally before this acceptance test")) pure
    (find ((== version) . compilerVersion) inventory.installedCompilers)) supportedCompilerVersions
  coordinator <- resolveCoordinator
  withSystemTempDirectory "vh-multiple-ghcs" $ \temporary -> do
    root <- canonicalizePath temporary
    createDirectory (root </> ".git")
    writeFile (root </> "multi-ghc-fixture.cabal") $ unlines
      ["cabal-version: 3.0", "name: multi-ghc-fixture", "version: 0.1.0.0", "build-type: Simple",
       "library", "  exposed-modules: Fixture, Other", "  hs-source-dirs: src", "  build-depends: base >= 4.18 && < 4.21",
       "  default-language: Haskell2010"]
    createDirectory (root </> "src")
    createDirectoryLink (root </> "src") (root </> "open sources")
    let source = "{-# LANGUAGE TemplateHaskell #-}\nmodule Fixture where\nvalue :: Int\nvalue = $( [| 41 |] )\nfirst :: Int -> String\nfirst = show\nsecond :: String -> Int\nsecond = length\n"
        broken = T.replace "value :: Int" "value :: String" source
        corrected = T.replace "value = $( [| 41 |] )" "value = $( [| \"unsaved\" |] )" broken
        document text = DocumentSnapshot (DocumentId "fixture") (root </> "open sources/Fixture.hs")
          (TextRevision (unContentHash (contentHash text))) (contentHash text) text LF
    T.writeFile (root </> "src/Fixture.hs") source
    T.writeFile (root </> "src/Other.hs")
      "module Other (unopened) where\nunopened :: Int -> String\nunopened = show\n"
    forM_ compilers $ \compiler -> do
      let suffix = T.unpack compiler.compilerVersion
      writeFile (root </> "cabal.project." <> suffix) $ unlines
        ["packages: .", "with-compiler: " <> compiler.compilerExecutable]
      writeFile (root </> "stack-" <> suffix <.> "yaml") $ unlines
        ["resolver: ghc-" <> suffix, "packages: [.]", "system-ghc: true", "install-ghc: false", "compiler-check: match-exact"]
    events <- newTQueueIO
    cabal <- resolveTool "VH_CABAL" "cabal" >>= maybe (fail "cabal-install missing") pure
    stack <- resolveTool "VH_STACK" "stack" >>= maybe (fail "Stack missing") pure
    createDirectory (root </> "renamed tools")
    let cabalAlias = root </> "renamed tools/cabal-selected"
        stackAlias = root </> "renamed tools/stack-selected"
    createFileLink cabal cabalAlias
    createFileLink stack stackAlias
    inherited <- getEnvironment
    let overrides = [("PATH", "/usr/bin:/bin"), ("VH_CABAL", cabalAlias), ("VH_STACK", stackAlias),
          ("VH_GHC", (last compilers).compilerExecutable)]
        launch = (defaultWorkerLaunch coordinator)
          {workerEnvironment = Just (overrides <> filter (\(name, _) -> name `notElem` map fst overrides) inherited)}
    let workspace = WorkspaceId "multi-ghc"
        generation = WorkspaceGeneration 19
        base payload = (protocolEnvelope generation payload) {envelopeWorkspace = Just workspace}
        hello = base (ClientHelloMessage (ClientHello "toolchain-acceptance" Nothing TrustedWorkspace []))
    client <- startAnalysisClient launch hello (atomically . writeTQueue events)
    flip finally (stopAnalysisClient client >> waitAnalysisClient client) $ do
      let send = sendAnalysisMessage client . base
          analyze snapshot = do
            send (UpdateDocumentSnapshot snapshot)
            sendAnalysisMessage client ((base (AnalyzeDocument snapshot.snapshotDocumentId))
              {envelopeDocument = Just snapshot.snapshotDocumentId, envelopeRevision = Just snapshot.snapshotRevision,
               envelopeContentHash = Just snapshot.snapshotContentHash, envelopeInputHash = Just (analysisInputsHash [snapshot])})
            await events $ \message -> case message of
              AnalysisCompleted result | result.analysisContentHash == snapshot.snapshotContentHash -> Just result
              _ -> Nothing
          load :: BuildTool -> CompilerIdentity -> IO ()
          load tool compiler = do
            let suffix = compiler.compilerVersion
                profile = if tool == CabalProject then "cabal:cabal.project." <> suffix else "stack:stack-" <> suffix <> ".yaml"
            send (DiscoverProject (Just profile))
            resolved <- await events $ \message -> case message of
              ToolchainsDiscovered value | fmap compilerFingerprint value.selectedCompiler == Just compiler.compilerFingerprint -> Just value
              _ -> Nothing
            when (resolved.selectedWorker == Nothing) $ do
              send BuildAnalysisWorker
              _ <- await events $ \message -> case message of
                ToolchainsDiscovered value | value.selectedWorker /= Nothing -> Just value
                _ -> Nothing
              send (DiscoverProject (Just profile))
            _ <- await events $ \message -> case message of
              ProjectDiscovered value | value.catalogSelectedProfile == Just profile && not (null value.catalogComponents) -> Just value
              _ -> Nothing
            pure ()
      send (OpenWorkspace (WorkspaceRequest workspace root TrustedWorkspace))
      -- The first missing adapter is built through the same protocol action as
      -- the Project panel, with the already installed GHC and normal Cabal store.
      forM_ ([(CabalProject, compiler) | compiler <- compilers] <> [(StackProject, compiler) | compiler <- compilers]) $ \(tool, compiler) -> do
        load tool compiler
        original <- analyze (document source)
        check "selected compiler typechecks Template Haskell" (original.analysisCompleteness == Typechecked)
        rejected <- analyze (document broken)
        check "selected compiler diagnoses unsaved type mismatch" (rejected.analysisCompleteness == PartiallyFailed)
        fixed <- analyze (document corrected)
        check "selected compiler recovers from unsaved correction" (fixed.analysisCompleteness == Typechecked)
        send (OpenWorkspace (WorkspaceRequest workspace root TrustedWorkspace))
        sendAnalysisMessage client ((protocolEnvelope (WorkspaceGeneration 18) (DiscoverProject (Just "obsolete-profile")))
          {envelopeWorkspace = Just workspace})
        let named name = find ((== name) . declarationName) fixed.analysisDeclarations
        case (named "first", named "second") of
          (Just first, Just second) -> do
            let current = document corrected
            sendAnalysisMessage client ((base (CheckComposition (CompositionQuery [first.declarationId, second.declarationId])))
              {envelopeDocument = Just current.snapshotDocumentId, envelopeRevision = Just current.snapshotRevision,
               envelopeContentHash = Just current.snapshotContentHash, envelopeSession = Just fixed.analysisSession,
               envelopeInputHash = Just (analysisInputsHash [current])})
            result <- await events $ \message -> case message of CompositionChecked value -> Just value; _ -> Nothing
            check "visual composition uses the selected compiler's typechecker" result.compositionValid
            let search text = do
                  let query = SymbolQuery text FunctionSymbols 0 50 []
                  sendAnalysisMessage client ((base (QuerySymbols query))
                    {envelopeDocument = Just current.snapshotDocumentId, envelopeRevision = Just current.snapshotRevision,
                     envelopeContentHash = Just current.snapshotContentHash, envelopeSession = Just fixed.analysisSession,
                     envelopeInputHash = Just (analysisInputsHash [current])})
                  await events $ \message -> case message of SymbolsFound value -> Just value; _ -> Nothing
            own <- search "Fixture.first"
            check "indexed sources restore symlinked open-buffer paths and unsaved hashes"
              (any (\symbol -> symbol.indexedModule == ModuleName "Fixture"
                && symbol.indexedDeclaration.declarationName == "first"
                && symbol.indexedSourcePath == Just current.snapshotPath
                && symbol.indexedSourceHash == Just current.snapshotContentHash
                && symbol.indexedDeclaration.declarationSelectionRange /= Nothing) own.symbolSearchSymbols)
            local <- search "Other.unopened"
            library <- search "Data.List.reverse"
            case (local.symbolSearchSymbols, library.symbolSearchSymbols) of
              (unopened : _, reverseFunction : _) -> do
                check "selected compiler indexes unopened local and library modules"
                  (local.symbolSearchLocalModules >= 2 && library.symbolSearchLibraryModules > 0)
                sendAnalysisMessage client ((base (CheckComposition (CompositionQuery
                  [unopened.indexedDeclaration.declarationId, reverseFunction.indexedDeclaration.declarationId, second.declarationId])))
                  {envelopeDocument = Just current.snapshotDocumentId, envelopeRevision = Just current.snapshotRevision,
                   envelopeContentHash = Just current.snapshotContentHash, envelopeSession = Just fixed.analysisSession,
                   envelopeInputHash = Just (analysisInputsHash [current])})
                imported <- await events $ \message -> case message of CompositionChecked value -> Just value; _ -> Nothing
                check "selected compiler checks unopened and unimported function composition" imported.compositionValid
              _ -> fail "selected compiler did not return local/library symbols"
          _ -> fail "typed function declarations missing"
        restartAnalysisWorker client
        replayed <- await events $ \message -> case message of AnalysisCompleted value -> Just value; _ -> Nothing
        check "compiler restart preserves unsaved buffers and profile" (replayed.analysisContentHash == contentHash corrected && replayed.analysisCompleteness == Typechecked)
        putStrLn ("PASS: " <> show tool <> " GHC " <> T.unpack compiler.compilerVersion <> " discovery/build, TH, diagnostics, indexing, imported composition and replay")
      -- Switch the compiler without resending the current document: the
      -- coordinator and client replay store remain authoritative.
      case compilers of
        compiler : _ -> do
          load CabalProject compiler
          send (SelectCompiler (Just compiler.compilerExecutable))
          send (AnalyzeDocument (DocumentId "fixture"))
          switched <- await events $ \message -> case message of AnalysisCompleted value -> Just value; _ -> Nothing
          check "compiler selection preserves authoritative unsaved text" (switched.analysisContentHash == contentHash corrected)
        _ -> fail "No test compilers"
    -- The same restricted GUI environment must discover the compiler through
    -- a nested explicit cradle, even when PATH/VH_GHC selects the other GHC.
    forM_ [(tool, compiler) | tool <- [CabalProject, StackProject], compiler <- compilers] $ \(cradleTool, compiler) -> do
      writeFile (root </> "src/hie.yaml") $ unlines $ case cradleTool of
        StackProject -> ["cradle:", "  stack:", "    stackYaml: ../stack-" <> T.unpack compiler.compilerVersion <> ".yaml",
          "    component: multi-ghc-fixture:lib"]
        _ -> ["cradle:", "  cabal:", "    cabalProject: ../cabal.project." <> T.unpack compiler.compilerVersion,
          "    component: multi-ghc-fixture:lib:multi-ghc-fixture"]
      cradleEvents <- newTQueueIO
      let cradleWorkspace = WorkspaceId "nested-cradle"
          cradleGeneration = WorkspaceGeneration 25
          cradleEnvelope payload = (protocolEnvelope cradleGeneration payload) {envelopeWorkspace = Just cradleWorkspace}
      cradleClient <- startAnalysisClient launch
        (cradleEnvelope (ClientHelloMessage (ClientHello "cradle-acceptance" Nothing TrustedWorkspace [])))
        (atomically . writeTQueue cradleEvents)
      flip finally (stopAnalysisClient cradleClient >> waitAnalysisClient cradleClient) $ do
        let send = sendAnalysisMessage cradleClient . cradleEnvelope
        send (OpenWorkspace (WorkspaceRequest cradleWorkspace (root </> "src") TrustedWorkspace))
        send (DiscoverProject Nothing)
        resolved <- await cradleEvents $ \message -> case message of
          ToolchainsDiscovered value | value.selectedCompiler /= Nothing -> Just value
          _ -> Nothing
        check "nested hie.yaml selects the actual project compiler, not the PATH compiler"
          (fmap compilerFingerprint resolved.selectedCompiler == Just compiler.compilerFingerprint)
        _ <- await cradleEvents $ \message -> case message of
          ProjectDiscovered value | not (null value.catalogComponents) -> Just value
          _ -> Nothing
        let snapshot = document corrected
        send (UpdateDocumentSnapshot snapshot)
        sendAnalysisMessage cradleClient ((cradleEnvelope (AnalyzeDocument snapshot.snapshotDocumentId))
          {envelopeDocument = Just snapshot.snapshotDocumentId, envelopeRevision = Just snapshot.snapshotRevision,
           envelopeContentHash = Just snapshot.snapshotContentHash, envelopeInputHash = Just (analysisInputsHash [snapshot])})
        checked <- await cradleEvents $ \message -> case message of AnalysisCompleted value -> Just value; _ -> Nothing
        check "nested cradle typechecks authoritative unsaved text with its selected adapter"
          (checked.analysisCompleteness == Typechecked && checked.analysisContentHash == snapshot.snapshotContentHash)
        restartAnalysisWorker cradleClient
        replayed <- await cradleEvents $ \message -> case message of AnalysisCompleted value -> Just value; _ -> Nothing
        check "nested cradle restart replays the same compiler and unsaved text"
          (replayed.analysisCompleteness == Typechecked && replayed.analysisContentHash == snapshot.snapshotContentHash)
        putStrLn ("PASS: nested hie.yaml " <> show cradleTool <> " GHC " <> T.unpack compiler.compilerVersion <> " with minimal GUI PATH, renamed tools and restart replay")

await :: TQueue AnalysisClientEvent -> (WorkerMessage -> Maybe a) -> IO a
await events select = do
  result <- timeout (15 * 60 * 1000000) loop
  maybe (fail "Multi-GHC acceptance operation timed out") pure result
  where loop = do
          event <- atomically (readTQueue events)
          case event of
            AnalysisWorkerProtocolFailure _ message -> fail (T.unpack message)
            AnalysisWorkerMessage _ envelope -> case select envelope.envelopePayload of
              Just value -> pure value
              Nothing -> case envelope.envelopePayload of
                WorkerRequestFailed _ failure -> fail (T.unpack failure.requestFailureCode <> ": " <> T.unpack failure.requestFailureMessage)
                ProjectProgress message -> T.hPutStrLn stderr (T.take 400 message) >> loop
                _ -> loop
            _ -> loop

check :: String -> Bool -> IO ()
check label valid = unless valid (fail label)
