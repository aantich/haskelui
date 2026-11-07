{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE LambdaCase #-}

module Main (main) where

import Control.Concurrent.STM
  ( TQueue
  , atomically
  , newTQueueIO
  , readTQueue
  , writeTQueue
  )
import Control.Exception (finally, bracket)
import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (withAsync, wait)
import Control.Monad (unless, when)
import qualified Data.Map.Strict as Map
import qualified Data.Text as Text
import qualified Data.Text.IO as TextIO
import Data.Aeson (eitherDecode)
import qualified Data.ByteString.Lazy as LazyBytes
import Data.Time.Clock (diffUTCTime, getCurrentTime)
import System.Directory
  ( findExecutable
  , getTemporaryDirectory
  , makeAbsolute
  , removeFile
  , listDirectory
  , doesFileExist
  )
import System.Environment (lookupEnv, setEnv, unsetEnv)
import System.FilePath ((</>))
import System.IO (hClose, openTempFile)
import System.IO.Temp (withSystemTempDirectory)
import System.Timeout (timeout)
import VisualHaskell.Analysis.Client
import VisualHaskell.Analysis.Ghc910
import VisualHaskell.Analysis.Protocol
import VisualHaskell.Semantic

main :: IO ()
main = withSystemTempDirectory "vh-symbol-cache-test" $ \cacheRoot ->
  bracket (lookupEnv "XDG_CACHE_HOME")
    (maybe (unsetEnv "XDG_CACHE_HOME") (setEnv "XDG_CACHE_HOME")) $ \_ -> do
      setEnv "XDG_CACHE_HOME" cacheRoot
      runTests cacheRoot

runTests :: FilePath -> IO ()
runTests cacheRoot = do
  -- A Stack cradle launches @stack repl@. Running that while an enclosing
  -- @stack test@ owns Stack's build lock can deadlock, so the repository's
  -- self-hosted cradle check is an explicit post-build validation. The direct
  -- fixture below still exercises hie-bios during every ordinary test run.
  selfHostedRequested <- (== Just "1") <$> lookupEnv "VISUAL_HASKELL_TEST_SELF_HOSTED_CRADLE"
  when selfHostedRequested $ do
    repositoryRoot <- makeAbsolute (".." </> ".." </> "..")
    let repositoryModule = repositoryRoot </> "vh" </> "src" </> "VisualHaskell" </> "WorkspaceState.hs"
    selfHosted <- discoverCompilerInvocation repositoryModule [repositoryModule]
    selfHostedInvocation <- either (fail . show) pure selfHosted
    assert "hie-bios loads the repository's real Stack component" $
      selfHostedInvocation.invocationCompilerVersion == "9.10.3"
        && not (null selfHostedInvocation.invocationCompilerOptions)
    selfHostedSource <- TextIO.readFile repositoryModule
    let selfHostedDocument = DocumentId "self-hosted:WorkspaceState"
        selfHostedFirst =
          snapshot selfHostedDocument repositoryModule (TextRevision 1) selfHostedSource
        selfHostedEdited =
          snapshot selfHostedDocument repositoryModule (TextRevision 2) (selfHostedSource <> "\n")
    (selfStartupMilliseconds, selfStarted) <- timed (startAnalysisEngine selfHostedInvocation)
    selfEngine <- either (fail . show) pure selfStarted
    (selfFirstMilliseconds, selfWarmMilliseconds) <-
      flip finally (stopAnalysisEngine selfEngine) $ do
        (firstMilliseconds, firstResult) <-
          timed
            ( analyzeWithEngine
                selfEngine
                (Map.singleton selfHostedDocument selfHostedFirst)
                selfHostedDocument
                (WorkspaceGeneration 1)
            )
        firstAnalysis <- either (fail . show) pure firstResult
        assert "the real Visual Haskell component initially typechecks" $
          firstAnalysis.analysisCompleteness == Typechecked
        (warmMilliseconds, warmResult) <-
          timed
            ( analyzeWithEngine
                selfEngine
                (Map.singleton selfHostedDocument selfHostedEdited)
                selfHostedDocument
                (WorkspaceGeneration 1)
            )
        warmAnalysis <- either (fail . show) pure warmResult
        assert "the real Visual Haskell component rechecks an in-memory edit" $
          warmAnalysis.analysisCompleteness == Typechecked
            && warmAnalysis.analysisRevision == TextRevision 2
        pure (firstMilliseconds, warmMilliseconds)
    putStrLn $
      "Self-hosted persistent GHC timings: startup="
        <> show selfStartupMilliseconds
        <> "ms first-load="
        <> show selfFirstMilliseconds
        <> "ms warm-edit="
        <> show selfWarmMilliseconds
        <> "ms"
    assert "the real Visual Haskell warm edit remains below the interactive one-second budget" $
      selfWarmMilliseconds < 1000

  fixture <- makeAbsolute ("test" </> "fixtures" </> "two-module")
  discovered <- discoverCompilerInvocation (fixture </> "A.hs") [fixture </> "A.hs", fixture </> "B.hs"]
  invocation <- either (fail . show) pure discovered
  assert "hie-bios selected the fixture component root" (invocation.invocationComponentRoot == fixture)
  assert "hie-bios selected GHC 9.10.3" (invocation.invocationCompilerVersion == "9.10.3")
  let aPath = fixture </> "A.hs"
      bPath = fixture </> "B.hs"
      unrelatedPath = fixture </> "Unrelated.hs"
      aSource = Text.unlines
        [ "module A where"
        , "import B (value)"
        , "import qualified Data.List as L"
        , "data Tree a = Leaf { leafValue :: a } | Branch (Tree a) (Tree a)"
        , "newtype UserId = UserId Int"
        , "type Forest a = [Tree a]"
        , "class Eq a => Renderable a where"
        , "  renderValue :: a -> String"
        , "type TraceSink = String -> IO ()"
        , "data DebugLogger = DebugLogger { debugLogPath :: FilePath, debugTraceSink :: TraceSink }"
        , "message :: String"
        , "message = value"
        , "toText :: Int -> String"
        , "toText = show"
        , "textLength :: String -> Int"
        , "textLength = length"
        , "negateInt :: Int -> Int"
        , "negateInt = negate"
        , "identity :: a -> a"
        , "identity input = input"
        , "vhInput0 :: Int -> String"
        , "vhInput0 = show"
        , "renderAny :: Show a => a -> String"
        , "renderAny = show"
        , "sorted = L.sort [3 :: Int, 1]"
        , "unicodeValue = \"😀\" ++ value"
        ]
      bSource = Text.unlines
        [ "module B (value) where"
        , "value :: String"
        , "value = \"unsaved 😀\""
        ]
      aSnapshot = snapshot (DocumentId "A") aPath (TextRevision 1) aSource
      bSnapshot = snapshot (DocumentId "B") bPath (TextRevision 1) bSource
      unrelatedSnapshot =
        snapshot
          (DocumentId "Unrelated")
          unrelatedPath
          (TextRevision 1)
          "module Unrelated where\nunrelated = missingIdentifier\n"
      documents =
        Map.fromList
          [ (DocumentId "A", aSnapshot)
          , (DocumentId "B", bSnapshot)
          , (DocumentId "Unrelated", unrelatedSnapshot)
          ]
  let brokenSource = Text.unlines
        [ "module B (value) where"
        , "value :: String"
        , "value = missingIdentifier"
        ]
      brokenSnapshot = snapshot (DocumentId "B") bPath (TextRevision 2) brokenSource
      brokenDocuments = Map.insert (DocumentId "B") brokenSnapshot documents
      recoveredSnapshot = snapshot (DocumentId "B") bPath (TextRevision 3) bSource
      recoveredDocuments = Map.insert (DocumentId "B") recoveredSnapshot documents
  (startupMilliseconds, startedEngine) <- timed (startAnalysisEngine invocation)
  engine <- either (fail . show) pure startedEngine
  (firstLoadMilliseconds, warmBrokenMilliseconds, warmRecoveredMilliseconds) <-
    flip finally (stopAnalysisEngine engine) $ do
      (firstMilliseconds, successful) <-
        timed (analyzeWithEngine engine documents (DocumentId "A") (WorkspaceGeneration 3))
      analyzed <- either (fail . show) pure successful
      assert "two dependent unsaved modules typecheck" (analyzed.analysisCompleteness == Typechecked)
      assert "analyzing one target does not load an unrelated broken open module" (null analyzed.analysisDiagnostics)
      assert "GHC returns the requested top-level declaration" (any ((== "message") . declarationName) analyzed.analysisDeclarations)
      assert "GHC types normalize into the stable type table" (not (Map.null analyzed.analysisTypes))
      assert "successful unsaved analysis has no errors" (null analyzed.analysisDiagnostics)
      let functionNodes = buildFunctionUniverse analyzed
          functionId name = case [node.functionIdentity | node <- functionNodes, node.functionName == name] of
            identifier : _ -> identifier
            [] -> error ("Missing function node " <> Text.unpack name)
      validComposition <- checkCompositionWithEngine engine documents (DocumentId "A")
        (CompositionQuery [functionId "identity", functionId "toText", functionId "textLength"]) >>= either (fail . show) pure
      assert "GHC validates the entire polymorphic composition chain" (validComposition.compositionValid && validComposition.compositionSignature /= Nothing)
      captured <- checkCompositionWithEngine engine documents (DocumentId "A")
        (CompositionQuery [functionId "vhInput0", functionId "textLength"]) >>= either (fail . show) pure
      assert "generated composition binders cannot capture user function names" captured.compositionValid
      invalidComposition <- checkCompositionWithEngine engine documents (DocumentId "A")
        (CompositionQuery [functionId "toText", functionId "negateInt"]) >>= either (fail . show) pure
      assert "GHC returns an actual mismatch for incompatible ports" (not invalidComposition.compositionValid && invalidComposition.compositionError /= Nothing)
      constrained <- checkCompositionWithEngine engine documents (DocumentId "A")
        (CompositionQuery [functionId "identity", functionId "renderAny"]) >>= either (fail . show) pure
      assert "composition preserves inferred typeclass constraints" $
        constrained.compositionValid && maybe False (Text.isInfixOf "Show") constrained.compositionSignature
      indexed <- searchSymbolsWithEngine engine documents (DocumentId "A")
        (SymbolQuery "C.unopened" FunctionSymbols 0 50 []) >>= either (fail . show) pure
      assert "unopened, unimported declared module is indexed" $
        any (\symbol -> symbol.indexedModule == ModuleName "C" && symbol.indexedDeclaration.declarationName == "unopened"
          && symbol.indexedSourcePath == Just (fixture </> "C.hs")) indexed.symbolSearchSymbols
      assert "unrelated broken open buffers do not poison the component index" (indexed.symbolSearchLocalModules >= 3)
      let unopened = case indexed.symbolSearchSymbols of symbol : _ -> symbol.indexedDeclaration.declarationId; [] -> error "Unopened symbol missing"
      reversePage <- searchSymbolsWithEngine engine documents (DocumentId "A")
        (SymbolQuery "Data.List.reverse" FunctionSymbols 0 50 [unopened]) >>= either (fail . show) pure
      let reverseSymbols = [symbol | symbol <- reversePage.symbolSearchSymbols, symbol.indexedModule == ModuleName "Data.List", symbol.indexedDeclaration.declarationName == "reverse"]
      assert "unimported library export keeps its import route, version, and no fake source range" $
        any (\symbol -> symbol.indexedPackage == "base" && not (Text.null symbol.indexedPackageVersion)
          && symbol.indexedDeclaration.declarationSelectionRange == Nothing && symbol.indexedSourcePath == Nothing
          && not (Map.null symbol.indexedTypes)) reverseSymbols
      assert "pinned cards survive filtering and paging" (any ((== unopened) . declarationId . indexedDeclaration) reversePage.symbolSearchPinned)
      let reverseId = case reverseSymbols of symbol : _ -> symbol.indexedDeclaration.declarationId; [] -> error "Library reverse missing"
      crossModule <- checkCompositionWithEngine engine documents (DocumentId "A")
        (CompositionQuery [unopened, reverseId, functionId "textLength"]) >>= either (fail . show) pure
      assert "GHC composes unopened module, unimported dependency and local function" crossModule.compositionValid
      rejectedExternal <- checkCompositionWithEngine engine documents (DocumentId "A")
        (CompositionQuery [unopened, functionId "negateInt"]) >>= either (fail . show) pure
      assert "GHC rejects incompatible indexed functions" (not rejectedExternal.compositionValid)
      privatePage <- searchSymbolsWithEngine engine documents (DocumentId "A")
        (SymbolQuery "C.privateFunction" FunctionSymbols 0 50 []) >>= either (fail . show) pure
      assert "private definitions are not exposed as importable palette entries" (null privatePage.symbolSearchSymbols)
      typePage <- searchSymbolsWithEngine engine documents (DocumentId "A")
        (SymbolQuery "C.Box" TypeSymbols 0 50 []) >>= either (fail . show) pure
      assert "unopened type declarations retain constructors and parameter kinds" $
        any (\symbol -> case symbol.indexedDeclaration.declarationTypeSemantics of
          Just semantics -> not (null semantics.typeDeclarationSemanticParameters) && case semantics.typeDeclarationSemanticDefinition of
            AlgebraicTypeSemantics constructors -> not (null constructors)
            _ -> False
          Nothing -> False) typePage.symbolSearchSymbols
      operatorPage <- searchSymbolsWithEngine engine documents (DocumentId "A")
        (SymbolQuery "Data.Function.&" FunctionSymbols 0 50 []) >>= either (fail . show) pure
      let operatorId = case [symbol.indexedDeclaration.declarationId | symbol <- operatorPage.symbolSearchSymbols,
              symbol.indexedDeclaration.declarationName == "&"] of identifier : _ -> identifier; [] -> error "Library operator missing"
      operatorComposition <- checkCompositionWithEngine engine documents (DocumentId "A")
        (CompositionQuery [unopened, operatorId]) >>= either (fail . show) pure
      assert "qualified symbolic operators compose without textual name guessing" operatorComposition.compositionValid
      let editedC = snapshot (DocumentId "C") (fixture </> "C.hs") (TextRevision 1)
            "module C (unopened) where\nunopened :: String -> Int\nunopened = length\n"
          withC = Map.insert (DocumentId "C") editedC documents
      staleIndexed <- checkCompositionWithEngine engine withC (DocumentId "A")
        (CompositionQuery [unopened, reverseId])
      assert "dependency edits invalidate old index authority before refresh" (case staleIndexed of Left _ -> True; Right _ -> False)
      editedIndex <- searchSymbolsWithEngine engine withC (DocumentId "A")
        (SymbolQuery "C.unopened" FunctionSymbols 0 50 []) >>= either (fail . show) pure
      assert "unsaved indexed-module signature changes are reflected" $
        any ((== Just "String -> Int") . declarationSignatureText . indexedDeclaration) editedIndex.symbolSearchSymbols
      changedComposition <- checkCompositionWithEngine engine withC (DocumentId "A")
        (CompositionQuery [unopened, reverseId]) >>= either (fail . show) pure
      assert "new indexed types, not cached signatures, govern compatibility" (not changedComposition.compositionValid)
      let valueOffset = Text.length (fst (Text.breakOn "value\n" aSource))
      hover <- queryWithEngine engine documents (DocumentId "A") (PositionQuery HoverQuery valueOffset) >>= either (fail . show) pure
      assert "hover resolves the imported occurrence and its inferred type" $
        case hover.resultHover of
          Just info -> info.hoverName == "value" && not (Text.null info.hoverSignature)
          Nothing -> False
      definition <- queryWithEngine engine documents (DocumentId "A") (PositionQuery DefinitionQuery valueOffset) >>= either (fail . show) pure
      assert "definition resolves into the dependent unsaved module" $
        any (\target -> target.definitionPath == bPath && target.definitionContentHash == bSnapshot.snapshotContentHash) definition.resultDefinitions
      endDefinition <- queryWithEngine engine documents (DocumentId "A") (PositionQuery DefinitionQuery (valueOffset + 5)) >>= either (fail . show) pure
      assert "keyboard definition also works at the end of an identifier" (endDefinition.resultDefinitions == definition.resultDefinitions)
      completions <- queryWithEngine engine documents (DocumentId "A") (PositionQuery CompletionQuery (valueOffset + 2)) >>= either (fail . show) pure
      assert "completion uses GHC scope and returns an exact replacement range" $
        any ((== "value") . (.completionLabel)) completions.resultCompletions
          && completions.resultReplacementStart == valueOffset
          && completions.resultReplacementLength == 2
      let localOffset = Text.length (fst (Text.breakOn "identity input = input" aSource)) + Text.length "identity input = "
          qualifiedOffset = Text.length (fst (Text.breakOn "L.sort [" aSource))
          unicodeOffset = Text.length (fst (Text.breakOn "unicodeValue =" aSource)) + Text.length "unicodeValue = \"😀\" ++ "
      local <- queryWithEngine engine documents (DocumentId "A") (PositionQuery CompletionQuery (localOffset + 2)) >>= either (fail . show) pure
      assert "local completion respects the typed lexical scope" (any ((== "input") . (.completionLabel)) local.resultCompletions)
      outside <- queryWithEngine engine documents (DocumentId "A") (PositionQuery CompletionQuery 0) >>= either (fail . show) pure
      assert "local binders do not leak to module scope" (not (any ((== "input") . (.completionLabel)) outside.resultCompletions))
      qualified <- queryWithEngine engine documents (DocumentId "A") (PositionQuery CompletionQuery (qualifiedOffset + 4)) >>= either (fail . show) pure
      assert "completion preserves import aliases" (any ((== "L.sort") . (.completionLabel)) qualified.resultCompletions)
      unicode <- queryWithEngine engine documents (DocumentId "A") (PositionQuery HoverQuery unicodeOffset) >>= either (fail . show) pure
      assert "hover uses scalar ranges after a non-BMP character on the same line" $
        maybe False (\info -> info.hoverName == "value" && info.hoverStart == unicodeOffset && info.hoverLength == 5) unicode.resultHover
      switched <- queryWithEngine engine documents (DocumentId "B")
        (PositionQuery HoverQuery (Text.length (fst (Text.breakOn "value ::" bSource)))) >>= either (fail . show) pure
      assert "queries refresh their typed context when switching open buffers" (switched.resultHover /= Nothing)
      let shiftedB = snapshot (DocumentId "B") bPath (TextRevision 2) ("-- shifted unsaved dependency\n" <> bSource)
          shiftedDocuments = Map.insert (DocumentId "B") shiftedB documents
      shiftedDefinition <- queryWithEngine engine shiftedDocuments (DocumentId "A") (PositionQuery DefinitionQuery valueOffset) >>= either (fail . show) pure
      assert "dependency edits cannot mix an old definition range with a new content hash" $
        any (\target -> target.definitionContentHash == shiftedB.snapshotContentHash && target.definitionRange.sourceRangeStart.sourceLine == 3)
          shiftedDefinition.resultDefinitions
      let semanticsNamed name =
            [ semantics
            | declaration <- analyzed.analysisDeclarations
            , declaration.declarationName == name
            , Just semantics <- [declaration.declarationTypeSemantics]
            ]
          treeSemantics = semanticsNamed "Tree"
          userIdSemantics = semanticsNamed "UserId"
          forestSemantics = semanticsNamed "Forest"
          renderableSemantics = semanticsNamed "Renderable"
          debugLoggerSemantics = semanticsNamed "DebugLogger"
          universe =
            buildTypeUniverse
              (CurrentDocumentTypes aSnapshot.snapshotDocumentId)
              [analyzed]
          debugProjection = renderTypeUniverseDebug (Text.pack . show) universe
      assert "GHC projects an algebraic type and all constructors" $
        case treeSemantics of
          [TypeDeclarationSemantics _ [TypeParameterSemantics "a" (Just _)] (AlgebraicTypeSemantics constructors)] ->
            fmap (.typeConstructorSemanticName) constructors == ["Leaf", "Branch"]
              && any (any ((== "leafValue") . (.typeFieldSemanticName)) . (.typeConstructorSemanticFields)) constructors
          _ -> False
      assert "GHC distinguishes newtypes" $
        case userIdSemantics of
          [TypeDeclarationSemantics _ [] (NewtypeSemantics constructor)] ->
            constructor.typeConstructorSemanticName == "UserId"
          _ -> False
      assert "GHC projects type-synonym right-hand sides" $
        case forestSemantics of
          [TypeDeclarationSemantics _ [_] (TypeAliasSemantics _)] -> True
          _ -> False
      assert "GHC projects class constraints and methods" $
        case renderableSemantics of
          [TypeDeclarationSemantics _ [_] (TypeClassSemantics constraints methods)] ->
            not (null constraints)
              && fmap (.typeMethodSemanticName) methods == ["renderValue"]
          _ -> False
      let debugLoggerFieldTypes =
            case debugLoggerSemantics of
              [TypeDeclarationSemantics _ [] (AlgebraicTypeSemantics [constructor])] ->
                [ Map.lookup field.typeFieldSemanticType analyzed.analysisTypes
                | field <- constructor.typeConstructorSemanticFields
                ]
              _ -> []
      unless
        ( case debugLoggerFieldTypes of
            [Just (TypeConstructor filePathName), Just (FunctionType _ _)] ->
              ".FilePath" `Text.isSuffixOf` filePathName || filePathName == "FilePath"
            _ -> False
        )
        (fail ("record fields preserve GHC-retained aliases and structured function shape: " <> show debugLoggerFieldTypes))
      assert "the Type Universe derives recursive type relationships" $
        any ((== RecursiveTypeReference) . (.typeRelationKind)) universe.typeUniverseRelations
      assert "the inspector debug projection exposes rich declaration semantics" $
        all
          (`Text.isInfixOf` debugProjection)
          [ "definition: algebraic (2 constructors)"
          , "name: Branch"
          , "name: leafValue"
          , "definition: newtype UserId"
          , "alias-target:"
          , "superclass-constraints:"
          , "name: renderValue"
          , "--recursive-reference-->"
          ]

      (brokenMilliseconds, failed) <-
        timed (analyzeWithEngine engine brokenDocuments (DocumentId "B") (WorkspaceGeneration 3))
      failedAnalysis <- either (fail . show) pure failed
      assert "a typecheck failure remains a semantic result" (failedAnalysis.analysisCompleteness == PartiallyFailed)
      assert "GHC diagnostics are captured" (not (null failedAnalysis.analysisDiagnostics))
      assert "diagnostics retain the exact unsaved revision" $
        all ((== TextRevision 2) . sourceRangeRevision . diagnosticRange) failedAnalysis.analysisDiagnostics

      (recoveredMilliseconds, recovered) <-
        timed (analyzeWithEngine engine recoveredDocuments (DocumentId "B") (WorkspaceGeneration 3))
      recoveredAnalysis <- either (fail . show) pure recovered
      assert "the warm session recovers after correcting an unsaved error" $
        recoveredAnalysis.analysisCompleteness == Typechecked
          && recoveredAnalysis.analysisRevision == TextRevision 3
          && null recoveredAnalysis.analysisDiagnostics
      running <- analysisEngineIsRunning engine
      assert "all edits reused one live GHC session" running
      pure (firstMilliseconds, brokenMilliseconds, recoveredMilliseconds)
  putStrLn $
    "Persistent GHC timings: startup="
      <> show startupMilliseconds
      <> "ms first-load="
      <> show firstLoadMilliseconds
      <> "ms warm-broken="
      <> show warmBrokenMilliseconds
      <> "ms warm-recovered="
      <> show warmRecoveredMilliseconds
      <> "ms"
  assert "warm erroneous edit remains below the interactive one-second budget" $
    warmBrokenMilliseconds < 1000
  assert "warm corrected edit remains below the interactive one-second budget" $
    warmRecoveredMilliseconds < 1000
  let indexCache = cacheRoot </> "visual-haskell/symbol-index/v2"
  cachedFiles <- listDirectory indexCache
  assert "immutable library projections are persisted" (not (null cachedFiles))
  case cachedFiles of
    file : _ -> do
      let path = indexCache </> file
      writeFile path "{ corrupt cache"
      restarted <- startAnalysisEngine invocation >>= either (fail . show) pure
      cachedResult <- flip finally (stopAnalysisEngine restarted) $
        searchSymbolsWithEngine restarted documents (DocumentId "A")
          (SymbolQuery "Data.List.reverse" FunctionSymbols 0 50 []) >>= either (fail . show) pure
      assert "new sessions reuse valid library cache modules" (cachedResult.symbolSearchCacheHits > 0)
      assert "corrupt cache does not hide library functions" (not (null cachedResult.symbolSearchSymbols))
      repaired <- eitherDecode <$> LazyBytes.readFile path
      assert "corrupt cache is atomically replaced with a valid projection" $
        case (repaired :: Either String (Text.Text, [IndexedSymbol])) of Right _ -> True; Left _ -> False
    [] -> fail "Library cache empty"
  closedSourceRace
  symbolIndexRegressions
  (_, protocolAnalysis, warmProtocolAnalysis) <- analyzeThroughWorker fixture aSnapshot bSnapshot []
  assert "the real worker protocol returns typechecked unsaved analysis" (protocolAnalysis.analysisCompleteness == Typechecked)
  assert "the real worker protocol preserves content identity" (protocolAnalysis.analysisContentHash == aSnapshot.snapshotContentHash)
  assert "the worker protocol transports rich declared-type semantics" $
    any
      (maybe False (const True) . (.declarationTypeSemantics))
      protocolAnalysis.analysisDeclarations
  let protocolDebugProjection =
        renderTypeUniverseDebug
          (Text.pack . show)
          ( buildTypeUniverse
              (CurrentDocumentTypes aSnapshot.snapshotDocumentId)
              [protocolAnalysis]
          )
  assert "the transported semantics are present in the inspector debug projection" $
    all
      (`Text.isInfixOf` protocolDebugProjection)
      ["definition: algebraic (2 constructors)", "name: leafValue", "name: renderValue"]
  assert "the real worker protocol reuses its session for a later document revision" $
    warmProtocolAnalysis.analysisCompleteness == Typechecked
      && warmProtocolAnalysis.analysisRevision == TextRevision 2
  temporary <- getTemporaryDirectory
  (marker, markerHandle) <- openTempFile temporary "visual-haskell-ghc-worker-crash-"
  hClose markerHandle
  removeFile marker
  (recoveredGeneration, recoveredAnalysis, recoveredWarmAnalysis) <-
    analyzeThroughWorker fixture aSnapshot bSnapshot ["--crash-once-marker", marker]
      `finally` removeFile marker
  assert "the GHC worker was replaced after the forced process crash" (recoveredGeneration > WorkerGeneration 1)
  assert "the replacement worker replays unsaved buffers and completes analysis" $
    recoveredAnalysis.analysisCompleteness == Typechecked
      && recoveredAnalysis.analysisContentHash == aSnapshot.snapshotContentHash
      && recoveredWarmAnalysis.analysisCompleteness == Typechecked
  putStrLn "Visual Haskell GHC 9.10 project discovery, unsaved analysis, protocol, and crash/replay tests passed"

snapshot :: DocumentId -> FilePath -> TextRevision -> Text.Text -> DocumentSnapshot
snapshot document path revision contents =
  DocumentSnapshot document path revision (contentHash contents) contents LF

analyzeThroughWorker
  :: FilePath
  -> DocumentSnapshot
  -> DocumentSnapshot
  -> [String]
  -> IO
      ( WorkerGeneration
      , AnalysisSnapshot RevisionedSourceRange
      , AnalysisSnapshot RevisionedSourceRange
      )
analyzeThroughWorker fixture aSnapshot bSnapshot arguments = do
  executable <-
    findExecutable "visual-haskell-analysis-ghc910"
      >>= maybe (fail "GHC analysis worker executable was not on PATH") pure
  events <- newTQueueIO
  let generation = WorkspaceGeneration 8
      workspace = WorkspaceId "ghc-fixture"
      hello =
        protocolEnvelope generation $
          ClientHelloMessage
            ( ClientHello
                "visual-haskell-ghc-worker-test/0.1"
                (Just fixture)
                TrustedWorkspace
                [ WorkspaceLoadingCapability
                , FullDocumentSnapshotsCapability
                , DiagnosticsCapability
                , DocumentDeclarationsCapability
                , StructuredTypesCapability
                ]
            )
      record event = atomically (writeTQueue events event)
  let launch = (defaultWorkerLaunch executable) {workerArguments = arguments}
  client <- startAnalysisClient launch hello record
  (do
      workerGeneration <- awaitMatching events $ \case
        AnalysisWorkerReady readyGeneration _ -> Just readyGeneration
        _ -> Nothing
      sendAnalysisMessage client $
        (protocolEnvelope generation (OpenWorkspace (WorkspaceRequest workspace fixture TrustedWorkspace)))
          { envelopeWorkspace = Just workspace }
      sendAnalysisMessage client (documentEnvelope generation workspace aSnapshot (OpenDocument aSnapshot))
      sendAnalysisMessage client (documentEnvelope generation workspace bSnapshot (OpenDocument bSnapshot))
      sendAnalysisMessage client (documentEnvelope generation workspace aSnapshot (AnalyzeDocument aSnapshot.snapshotDocumentId))
      firstAnalysis <- awaitMatching events $ \case
        AnalysisWorkerMessage actual envelope
          | actual >= workerGeneration
          , AnalysisCompleted analysis <- envelope.envelopePayload -> Just (actual, analysis)
        _ -> Nothing
      let query = PositionQuery HoverQuery (Text.length (fst (Text.breakOn "value\n" aSnapshot.snapshotText)))
          request = RequestId 902
          queryEnvelope = (documentEnvelope generation workspace aSnapshot (QueryPosition query))
            { envelopeRequestId = Just request, envelopeSession = Just (snd firstAnalysis).analysisSession }
      sendAnalysisMessage client queryEnvelope
      queryResponse <- awaitMatching events $ \case
        AnalysisWorkerMessage _ response
          | response.envelopeRequestId == Just request
          , PositionQueryCompleted answer <- response.envelopePayload -> Just answer
        _ -> Nothing
      assert "position queries traverse the real worker protocol with request identity" $
        queryResponse.resultQuery == query && queryResponse.resultHover /= Nothing
      sendAnalysisMessage client queryEnvelope {envelopeRequestId = Just (RequestId 903), envelopeRevision = Just (TextRevision 999)}
      staleRejected <- awaitMatching events $ \case
        AnalysisWorkerMessage _ response
          | response.envelopeRequestId == Just (RequestId 903)
          , WorkerRequestFailed _ rejected <- response.envelopePayload -> Just rejected.requestFailureCode
        _ -> Nothing
      assert "the worker rejects a cursor query for an obsolete snapshot" (staleRejected == "stale-query")
      let warmRevision = TextRevision (bSnapshot.snapshotRevision.unTextRevision + 1)
          warmSnapshot =
            snapshot
              bSnapshot.snapshotDocumentId
              bSnapshot.snapshotPath
              warmRevision
              (bSnapshot.snapshotText <> "\n")
      sendAnalysisMessage client (documentEnvelope generation workspace warmSnapshot (UpdateDocumentSnapshot warmSnapshot))
      sendAnalysisMessage client (documentEnvelope generation workspace warmSnapshot (AnalyzeDocument warmSnapshot.snapshotDocumentId))
      warmAnalysis <- awaitMatching events $ \case
        AnalysisWorkerMessage actual envelope
          | actual >= workerGeneration
          , AnalysisCompleted analysis <- envelope.envelopePayload
          , analysis.analysisDocument == warmSnapshot.snapshotDocumentId
          , analysis.analysisRevision == warmRevision -> Just analysis
        _ -> Nothing
      pure (fst firstAnalysis, snd firstAnalysis, warmAnalysis)
    ) `finally` (stopAnalysisClient client >> waitAnalysisClient client)

documentEnvelope
  :: WorkspaceGeneration
  -> WorkspaceId
  -> DocumentSnapshot
  -> ClientMessage
  -> ProtocolEnvelope ClientMessage
documentEnvelope generation workspace document payload =
  (protocolEnvelope generation payload)
    { envelopeWorkspace = Just workspace
    , envelopeDocument = Just document.snapshotDocumentId
    , envelopeRevision = Just document.snapshotRevision
    , envelopeContentHash = Just document.snapshotContentHash
    }

awaitMatching :: TQueue AnalysisClientEvent -> (AnalysisClientEvent -> Maybe value) -> IO value
awaitMatching events select = do
  result <- timeout 30000000 loop
  maybe (fail "timed out waiting for GHC worker event") pure result
  where
    loop = do
      event <- atomically (readTQueue events)
      case select event of
        Just value -> pure value
        Nothing -> case event of
          AnalysisWorkerProtocolFailure _ message -> fail (Text.unpack message)
          AnalysisWorkerMessage _ envelope | WorkerRequestFailed _ failure <- envelope.envelopePayload ->
            fail (Text.unpack failure.requestFailureCode <> ": " <> Text.unpack failure.requestFailureMessage)
          _ -> loop

-- Deterministic closed-file race: C's trusted splice signals when the full
-- index load reaches it, then pauses while an external writer changes C.
-- No span from the old GHC module may be paired with the new file's hash.
closedSourceRace :: IO ()
closedSourceRace = withSystemTempDirectory "vh-closed-index-source" $ \temporary -> do
  root <- makeAbsolute temporary
  let aPath = root </> "A.hs"
      cPath = root </> "C.hs"
      marker = root </> "index-started"
      aText = "module A where\nidentity :: a -> a\nidentity = id\n"
      replacement = "module C where\nchanging :: String -> Int\nchanging = length\n"
      slow = Text.unlines
        ["{-# LANGUAGE TemplateHaskell #-}", "module C where", "import Language.Haskell.TH", "import Control.Concurrent",
         "changing :: Int -> String", "changing = $(do runIO (writeFile " <> Text.pack (show marker) <>
          " \"ready\" >> threadDelay 500000); [| show |])"]
  TextIO.writeFile aPath aText
  TextIO.writeFile cPath slow
  writeFile (root </> "hie.yaml") "cradle:\n  direct:\n    arguments: [-i., -package, template-haskell, A.hs, C.hs]\n"
  invocation <- discoverCompilerInvocation aPath [aPath, cPath] >>= either (fail . show) pure
  engine <- startAnalysisEngine invocation >>= either (fail . show) pure
  let documents = Map.singleton (DocumentId "A") (snapshot (DocumentId "A") aPath (TextRevision 1) aText)
      rewrite 0 = fail "Index load did not reach the source-race marker"
      rewrite attempts = do
        exists <- doesFileExist marker
        if exists then TextIO.writeFile cPath replacement else threadDelay 10000 >> rewrite (attempts - 1)
      query = SymbolQuery "C.changing" FunctionSymbols 0 50 []
  flip finally (stopAnalysisEngine engine) $ withAsync (rewrite (1000 :: Int)) $ \writer -> do
    raced <- searchSymbolsWithEngine engine documents (DocumentId "A") query >>= either (fail . show) pure
    wait writer
    assert "closed source changes during indexing never publish mismatched spans and hashes" $
      raced.symbolSearchLocalModules == 0 && null raced.symbolSearchSymbols
        && not raced.symbolSearchComplete
        && any (Text.isInfixOf "Sources changed") raced.symbolSearchWarnings
    refreshed <- searchSymbolsWithEngine engine documents (DocumentId "A") query >>= either (fail . show) pure
    assert "source-race refresh indexes the new source without restarting the compiler" $
      any ((== Just "String -> Int") . declarationSignatureText . indexedDeclaration) refreshed.symbolSearchSymbols

symbolIndexRegressions :: IO ()
symbolIndexRegressions = withSystemTempDirectory "vh-index-regressions" $ \temporary -> do
  root <- makeAbsolute temporary
  let aPath = root </> "A.hs"
      bPath = root </> "B.hs"
      zPath = root </> "Z.hs"
      modePath = root </> "mode.txt"
      aText = "module A where\nlocal :: Int\nlocal = 1\n"
      bText = "module B (g) where\ng :: Int -> String\ng = show\n"
      paths = map (root </>) ["A.hs", "B.hs", "C.hs", "D.hs", "Z.hs"]
      documents = Map.singleton (DocumentId "A") (snapshot (DocumentId "A") aPath (TextRevision 1) aText)
      changing = Text.unlines
        [ "{-# LANGUAGE TemplateHaskell #-}", "module D where", "import Language.Haskell.TH"
        , "import Language.Haskell.TH.Syntax (addDependentFile)"
        , "$(do addDependentFile " <> Text.pack (show modePath)
        , "     mode <- runIO (readFile " <> Text.pack (show modePath) <> ")"
        , "     if mode == \"bool\" then [d| changing :: Bool -> Bool; changing = id |]"
        , "                       else [d| changing :: Int -> String; changing = show |])"
        ]
  TextIO.writeFile aPath aText
  TextIO.writeFile bPath bText
  TextIO.writeFile (root </> "C.hs") "module C (g) where\nimport B (g)\n"
  TextIO.writeFile (root </> "D.hs") changing
  TextIO.writeFile zPath "module Z where\nokay :: Int\nokay = 1\n"
  writeFile modePath "int"
  writeFile (root </> "hie.yaml") "cradle:\n  direct:\n    arguments: [-i., -package, template-haskell, A.hs, B.hs, C.hs, D.hs, Z.hs]\n"
  invocation <- discoverCompilerInvocation aPath paths >>= either (fail . show) pure
  engine <- startAnalysisEngine invocation >>= either (fail . show) pure
  flip finally (stopAnalysisEngine engine) $ do
    let search docs text pinned = searchSymbolsWithEngine engine docs (DocumentId "A")
          (SymbolQuery text FunctionSymbols 0 50 pinned) >>= either (fail . show) pure
        named :: Text.Text -> Text.Text -> SymbolSearchResult -> IO IndexedSymbol
        named moduleName name result = case [s | s <- result.symbolSearchSymbols,
            s.indexedModule == ModuleName moduleName, s.indexedDeclaration.declarationName == name] of
          symbol : _ -> pure symbol
          [] -> fail ("Missing indexed symbol " <> Text.unpack moduleName <> "." <> Text.unpack name)
        compose docs identifiers = checkCompositionWithEngine engine docs (DocumentId "A")
          (CompositionQuery identifiers) >>= either (fail . show) pure
    defined <- search documents "B.g" [] >>= named "B" "g"
    reexported <- search documents "C.g" [] >>= named "C" "g"
    let gId = defined.indexedDeclaration.declarationId
        hasDefiningSource :: IndexedSymbol -> Bool
        hasDefiningSource symbol = symbol.indexedSourcePath == Just bPath
          && symbol.indexedSourceHash == Just (contentHash bText)
          && symbol.indexedDeclaration.declarationSelectionRange == defined.indexedDeclaration.declarationSelectionRange
          && symbol.indexedDeclaration.declarationSelectionRange /= Nothing
    assert "re-export import routes retain the defining module's real source" $
      reexported.indexedDeclaration.declarationId == gId && hasDefiningSource reexported
    reversePage <- search documents "Data.List.reverse" [gId]
    assert "pinned re-export dedup never replaces a real source with the exporting file" $
      not (null reversePage.symbolSearchPinned) && all hasDefiningSource reversePage.symbolSearchPinned
    reversed <- named "Data.List" "reverse" reversePage
    counted <- search documents "Data.List.length" [] >>= named "Data.List" "length"
    let chain = map (.indexedDeclaration.declarationId) [reversed, counted]
    before <- compose documents chain
    assert "library-only composition starts valid" before.compositionValid
    old <- search documents "D.changing" []
    oldFunction <- named "D" "changing" old
    writeFile modePath "bool"
    new <- search documents "D.changing" []
    newFunction <- named "D" "changing" new
    assert "TH dependent-file changes revise index authority without an open-document edit" $
      old.symbolSearchRevision /= new.symbolSearchRevision
        && oldFunction.indexedDeclaration.declarationId == newFunction.indexedDeclaration.declarationId
        && oldFunction.indexedDeclaration.declarationSignatureText == Just "Int -> String"
        && newFunction.indexedDeclaration.declarationSignatureText == Just "Bool -> Bool"
    let broken = Map.insert (DocumentId "Z")
          (snapshot (DocumentId "Z") zPath (TextRevision 2) "module Z where\nokay :: Int\nokay = missing\n") documents
    active <- analyzeWithEngine engine broken (DocumentId "A") (WorkspaceGeneration 1) >>= either (fail . show) pure
    assert "an unrelated declared error leaves active document analysis usable" (active.analysisCompleteness == Typechecked)
    partial <- search broken "Data.List.reverse" [gId]
    assert "local failure is explicitly incomplete rather than revoking missing local pins" $
      not partial.symbolSearchComplete && partial.symbolSearchLocalModules == 0
        && null partial.symbolSearchPinned && not (null partial.symbolSearchSymbols)
    after <- compose broken chain
    assert "library-only composition survives a failed local graph" after.compositionValid
    recovered <- search documents "C.g" [] >>= named "C" "g"
    assert "partial indexes are retried and local source navigation recovers" (hasDefiningSource recovered)

assert :: String -> Bool -> IO ()
assert message condition = unless condition (fail message)

timed :: IO value -> IO (Integer, value)
timed operation = do
  started <- getCurrentTime
  result <- operation
  finished <- getCurrentTime
  pure (round (diffUTCTime finished started * 1000), result)
