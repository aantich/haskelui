{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE OverloadedRecordDot #-}
module Main (main) where
import Control.Exception (finally)
import Control.Monad (forM_, unless, when)
import qualified Data.Map.Strict as Map
import qualified Data.Text.IO as T
import Data.List (find)
import System.Directory
import System.Environment
import System.FilePath
import System.IO (stderr, stdout, hSetBuffering, BufferMode (LineBuffering))
import System.IO.Temp
import VisualHaskell.Analysis.Ghc910
import VisualHaskell.Projects
import VisualHaskell.Semantic
import qualified GHC
import HIE.Bios.Environment (initSession)
import HIE.Bios.Types (ComponentOptions (..))
import GHC.Data.StringBuffer (stringToStringBuffer)
import Control.Monad.IO.Class (liftIO)
import Data.Time.Clock
import ProtocolCheck (protocolCheck)
import qualified Data.Text as Text

main :: IO ()
main = do
  hSetBuffering stdout LineBuffering
  args <- getArgs
  case args of
    ["--self-host", root] -> selfHost root
    _ -> fixtureChecks args

fixtureChecks :: [String] -> IO ()
fixtureChecks args = do
  let fixture = case args of path : _ -> path; _ -> "vh/workers/ghc-9.10/test/fixtures/project-loading"
      tools = case drop 1 args of ["cabal"] -> [CabalProject]; ["stack"] -> [StackProject]; _ -> [CabalProject, StackProject]
  forM_ tools $ \tool -> withSystemTempDirectory "vh-project-loading-" $ \temporary -> do
    root <- canonicalizePath temporary
    copyTree fixture root
    -- Prove Stack does not rely on special project flags/build-info generation.
    when (tool == StackProject) $ do
      writeFile (root </> "stack.yaml")
        "resolver: lts-24.50\npackages: [upstream, consumer]\nsystem-ghc: true\ninstall-ghc: false\ncompiler-check: match-exact\n"
      removeFile (root </> "upstream/stage0-upstream.cabal")
      writeFile (root </> "upstream/package.yaml")
        "name: stage0-upstream\nversion: 0.1.0.0\ndependencies: [base >= 4.20 && < 4.21]\nlibrary:\n  source-dirs: src\n  exposed-modules: Upstream\n  cpp-options: -DSTAGE0_UPSTREAM\n"
    profiles <- discoverProfiles root
    profile <- maybe (fail "missing profile") pure (find ((== tool) . profileTool) profiles)
    let runner = runTool (T.hPutStrLn stderr)
        cache = root </> ".ide-cache"
    catalog <- discoverProject True runner root (Just profile.profileId) cache
    check "4 discoverable components" (length catalog.catalogComponents == 4)
    selected <- maybe (fail "missing consumer library") pure (find (\c -> c.projectComponentPackage == "stage0-consumer" && c.projectComponentKind == LibraryComponent) catalog.catalogComponents)
    context <- prepareProjectContext runner cache catalog selected
    check "local home units preserved" (length context.resolvedUnitRoots == 2)
    let invocation = CompilerInvocation context.resolvedRoot context.resolvedArguments context.resolvedConfigurationFiles
          context.resolvedCompilerLibDir context.resolvedCompilerVersion.unCompilerVersion context.resolvedPrimaryUnit context.resolvedUnitRoots (Just context.resolvedSession) context.resolvedUnitDirectories
        downstream = doc "downstream" (root </> "consumer/src/Downstream.hs")
        upstream = doc "upstream" (root </> "upstream/src/Upstream.hs")
    originalDown <- T.readFile (root </> "consumer/src/Downstream.hs")
    originalUp <- T.readFile (root </> "upstream/src/Upstream.hs")
    when (tool == CabalProject) $ GHC.runGhc (Just context.resolvedCompilerLibDir) $ do
      targets <- initSession (ComponentOptions context.resolvedArguments context.resolvedRoot context.resolvedConfigurationFiles)
      GHC.setTargets targets
      _ <- GHC.load GHC.LoadAllTargets
      now <- liftIO getCurrentTime
      let overlay target = case GHC.targetId target of
            GHC.TargetModule name | GHC.moduleNameString name == "Upstream" -> target {GHC.targetContents = Just (stringToStringBuffer "module Upstream (value) where\nvalue :: String\nvalue = \"unsaved\"\n", now)}
            _ -> target
      GHC.setTargets (map overlay targets)
      raw <- GHC.handleSourceError (const (pure GHC.Failed)) (GHC.load GHC.LoadAllTargets)
      liftIO (check "raw GHC reference detects an unsaved dependency mismatch" (case raw of GHC.Succeeded -> False; GHC.Failed -> True))
    engine <- startAnalysisEngine invocation >>= either (fail . show) pure
    flip finally (stopAnalysisEngine engine) $ do
      let analyze up down = analyzeWithEngine engine (Map.fromList [(DocumentId "upstream", upstream up),(DocumentId "downstream", downstream down)])
            (DocumentId "downstream") (WorkspaceGeneration 1) >>= either (fail . show) pure
      first <- analyze originalUp originalDown
      check "real selected component typechecks" (first.analysisCompleteness == Typechecked)
      broken <- analyze "module Upstream (value) where\nvalue :: String\nvalue = \"unsaved\"\n" originalDown
      check "unsaved local-library edit invalidates consumer" (broken.analysisCompleteness == PartiallyFailed)
      fixed <- analyze "module Upstream (value) where\nvalue :: String\nvalue = \"unsaved\"\n"
        "module Downstream (answer) where\nimport Upstream\nanswer :: String\nanswer = value\n"
      check "unsaved consumer correction recovers" (fixed.analysisCompleteness == Typechecked)
    forM_ [ExecutableComponent, TestComponent] $ \kind -> do
      component <- maybe (fail "missing exe/test") pure (find ((== kind) . projectComponentKind) catalog.catalogComponents)
      resolved <- prepareProjectContext runner cache catalog component
      let invocation' = CompilerInvocation resolved.resolvedRoot resolved.resolvedArguments resolved.resolvedConfigurationFiles
            resolved.resolvedCompilerLibDir resolved.resolvedCompilerVersion.unCompilerVersion resolved.resolvedPrimaryUnit resolved.resolvedUnitRoots (Just resolved.resolvedSession) resolved.resolvedUnitDirectories
          path = root </> (if kind == ExecutableComponent then "consumer/app/Main.hs" else "consumer/test/Main.hs")
      source <- T.readFile path
      engine' <- startAnalysisEngine invocation' >>= either (fail . show) pure
      analysis <- flip finally (stopAnalysisEngine engine') $
        analyzeWithEngine engine' (Map.singleton (DocumentId "main") (doc "main" path source)) (DocumentId "main") (WorkspaceGeneration 1) >>= either (fail . show) pure
      unless (analysis.analysisCompleteness == Typechecked) $ do
        print analysis.analysisDiagnostics
        forM_ [drop 1 flag | flag <- resolved.resolvedArguments, take 1 flag == "@"] $ \response -> readFile response >>= putStrLn
      check "duplicate Main uses its own component flags" (analysis.analysisCompleteness == Typechecked)
    putStrLn ("PASS: " <> show tool <> " real discovery, preparation, local buffers, component isolation")
    protocolCheck root profile catalog
  variantChecks (takeDirectory fixture </> "project-variants") tools
  where
    doc name path source = DocumentSnapshot (DocumentId name) path (TextRevision (unContentHash (contentHash source))) (contentHash source) source LF

check :: String -> Bool -> IO ()
check label condition = unless condition (fail label)

selfHost :: FilePath -> IO ()
selfHost directory = withSystemTempDirectory "vh-project-self-host-" $ \cache -> do
  root <- canonicalizePath directory
  profiles <- discoverProfiles root
  profile <- maybe (fail "missing self-host Stack profile") pure (find ((== StackProject) . profileTool) profiles)
  let runner = runTool (T.hPutStrLn stderr)
  catalog <- discoverProject True runner root (Just profile.profileId) cache
  forM_ [(LibraryComponent, "library", "vh/src/VisualHaskell.hs"),
         (TestComponent, "vh-model-test", "vh/test/model/ModelSpec.hs")] $ \(kind, name, path) -> do
    component <- maybe (fail ("missing self-host component " <> Text.unpack name)) pure $
      find (\c -> c.projectComponentPackage == "visual-haskell" && c.projectComponentKind == kind && c.projectComponentName == name) catalog.catalogComponents
    context <- prepareProjectContext runner (cache </> Text.unpack name) catalog component
    check "self-host preserves multiple local library units" (length context.resolvedUnitRoots > 3)
    result <- checkContext context (root </> path)
    check "self-host extracts typed declarations" (not (null result.analysisDeclarations))
    putStrLn ("PASS: self-host " <> Text.unpack component.projectComponentTarget <> " (" <> show (length context.resolvedUnitRoots) <> " home units)")

variantChecks :: FilePath -> [BuildTool] -> IO ()
variantChecks fixture tools = do
  forM_ tools $ \tool -> withSystemTempDirectory "vh project variants " $ \temporary -> do
    root <- canonicalizePath temporary
    copyTree fixture root
    createDirectory (root </> ".git")
    writeFile (root </> "cabal.project") "packages: .\nwith-compiler: ghc-9.10.3\n"
    writeFile (root </> "cabal.project.alternate") "packages: .\nwith-compiler: ghc-9.10.3\npackage project-variants\n  flags: +alternate\n"
    let yaml flag = "resolver: lts-24.50\npackages: [.]\nsystem-ghc: true\ninstall-ghc: false\nflags:\n  project-variants:\n    alternate: " <> flag <> "\n"
    writeFile (root </> "stack.yaml") (yaml "false")
    writeFile (root </> "stack-alternate.yaml") (yaml "true")
    profiles <- discoverProfiles root
    check "alternative profiles are discoverable" (length profiles == 4)
    let runner = runTool (const (pure ()))
        cache = root </> ".ide-cache"
        wanted = if tool == StackProject then "stack.yaml" else "cabal.project"
    standard <- maybe (fail "missing standard profile") pure (find ((== Just (root </> wanted)) . profileConfiguration) profiles)
    catalog <- discoverProject True runner root (Just standard.profileId) cache
    check "all five component kinds discovered" (length catalog.catalogComponents == 5)
    forM_ catalog.catalogComponents $ \component -> do
      context <- prepareProjectContext runner (cache </> show (unContentHash (contentHash component.projectComponentId.unComponentId))) catalog component
      let relative = case component.projectComponentKind of
            LibraryComponent | component.projectComponentName == "library" -> "src/Variants.hs"
            LibraryComponent -> "internal/Details.hs"
            ExecutableComponent -> "app/Main.hs"
            TestComponent -> "test/Main.hs"
            BenchmarkComponent -> "bench/Main.hs"
            _ -> error "unexpected variant component"
      result <- checkContext context (root </> relative)
      when (relative == "src/Variants.hs") $
        check "standard flag chooses Int source" (signature "chosen" result == Just "Int")
      when (component.projectComponentKind == ExecutableComponent) $
        check "executable closure includes main and internal libraries" (length context.resolvedUnitRoots == 3)
    let alternateName = if tool == StackProject then "stack-alternate.yaml" else "cabal.project.alternate"
    alternate <- maybe (fail "missing alternate profile") pure (find ((== Just (root </> alternateName)) . profileConfiguration) profiles)
    alternateCatalog <- discoverProject True runner root (Just alternate.profileId) cache
    library <- maybe (fail "missing alternate library") pure (find (\c -> c.projectComponentKind == LibraryComponent && c.projectComponentName == "library") alternateCatalog.catalogComponents)
    context <- prepareProjectContext runner (cache </> "alternate") alternateCatalog library
    result <- checkContext context (root </> "src/Variants.hs")
    check "alternate configuration chooses Bool source" (signature "chosen" result == Just "Bool")
    check "inactive conditional source directory is excluded" (root </> "standard" `notElem` context.resolvedSourceRoots)
    putStrLn ("PASS: " <> show tool <> " internal libraries, benchmarks, spaces, conditional roots, named configurations")
  forM_ tools $ \tool -> withSystemTempDirectory "vh custom setup " $ \temporary -> do
    root <- canonicalizePath temporary
    copyTree (takeDirectory fixture </> "project-custom") root
    createDirectory (root </> ".git")
    if tool == StackProject
      then writeFile (root </> "stack.yaml") "resolver: lts-24.50\npackages: [.]\nsystem-ghc: true\ninstall-ghc: false\n"
      else writeFile (root </> "cabal.project") "packages: .\nwith-compiler: ghc-9.10.3\n"
    let runner = runTool (const (pure ()))
        cache = root </> ".ide-cache"
    catalog <- discoverProject True runner root Nothing cache
    component <- case catalog.catalogComponents of [one] -> pure one; _ -> fail "custom Setup library discovery"
    context <- prepareProjectContext runner cache catalog component
    _ <- checkContext context (root </> "src/Custom.hs")
    check "custom Setup generated source" =<< doesFileExist (root </> "src/Generated.hs")
    putStrLn ("PASS: " <> show tool <> " custom Setup-generated sources")
  when (CabalProject `elem` tools) $ withSystemTempDirectory "vh-standalone-cabal-" $ \temporary -> do
    root <- canonicalizePath temporary
    copyTree fixture root
    createDirectory (root </> ".git")
    catalog <- discoverProject True (runTool (const (pure ()))) root Nothing (root </> ".ide-cache")
    library <- maybe (fail "missing standalone library") pure (find (\c -> c.projectComponentName == "library") catalog.catalogComponents)
    context <- prepareProjectContext (runTool (const (pure ()))) (root </> ".ide-cache/context") catalog library
    _ <- checkContext context (root </> "src/Variants.hs")
    check "standalone Cabal creates no user project files" . not =<< doesFileExist (root </> "cabal.project")
    putStrLn "PASS: standalone .cabal package (no cabal.project or hie.yaml)"
  where
    signature :: Text.Text -> AnalysisSnapshot RevisionedSourceRange -> Maybe Text.Text
    signature name result = find ((== name) . declarationName) result.analysisDeclarations >>= declarationSignatureText

checkContext :: ResolvedContext -> FilePath -> IO (AnalysisSnapshot RevisionedSourceRange)
checkContext context path = do
  source <- T.readFile path
  let snapshot = DocumentSnapshot (DocumentId "variant") path (TextRevision 1) (contentHash source) source LF
      invocation = CompilerInvocation context.resolvedRoot context.resolvedArguments context.resolvedConfigurationFiles
        context.resolvedCompilerLibDir context.resolvedCompilerVersion.unCompilerVersion context.resolvedPrimaryUnit context.resolvedUnitRoots (Just context.resolvedSession) context.resolvedUnitDirectories
  engine <- startAnalysisEngine invocation >>= either (fail . show) pure
  result <- flip finally (stopAnalysisEngine engine) $
    analyzeWithEngine engine (Map.singleton snapshot.snapshotDocumentId snapshot) snapshot.snapshotDocumentId (WorkspaceGeneration 1) >>= either (fail . show) pure
  check ("variant context typechecks: " <> path) (result.analysisCompleteness == Typechecked)
  pure result

copyTree :: FilePath -> FilePath -> IO ()
copyTree source destination = do
  createDirectoryIfMissing True destination
  entries <- listDirectory source
  forM_ entries $ \entry -> when (entry `notElem` [".stack-work", "dist-newstyle", "stack.yaml.lock"]) $ do
    let from = source </> entry; to = destination </> entry
    directory <- doesDirectoryExist from
    if directory then copyTree from to else copyFile from to
