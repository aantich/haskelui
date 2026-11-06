{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

-- Stage 0 research harness, deliberately separate from product session routing.
-- Run the built binary outside `stack test`: Stack cradles acquire build locks.
module Main (main) where

import Control.Exception (finally)
import Control.Monad (forM_, unless, when)
import Control.Monad.IO.Class (liftIO)
import Data.Aeson (FromJSON (..), eitherDecode, withObject, (.:))
import qualified Data.ByteString.Lazy as LazyByteString
import Data.IORef (modifyIORef', newIORef, readIORef, writeIORef)
import Data.List (isInfixOf, isPrefixOf, nub)
import qualified Data.Map.Strict as Map
import qualified Data.Text as Text
import qualified Data.Text.IO as TextIO
import Data.Time.Clock (addUTCTime, diffUTCTime, getCurrentTime)
import Data.Void (Void, absurd)
import qualified GHC
import GHC.ResponseFile (escapeArgs)
import GHC.Data.StringBuffer (stringToStringBuffer)
import GHC.Driver.Monad (pushLogHookM)
import GHC.Utils.Outputable (showSDocUnsafe)
import HIE.Bios
import qualified HIE.Bios.Config as Config
import HIE.Bios.Cradle (getCradleWithConfig)
import HIE.Bios.Environment (extractUnits, getRuntimeGhcLibDir, getRuntimeGhcVersion, initSession')
import HIE.Bios.Types (CacheDir (..), LoadMode (..), TargetWithContext (..))
import System.Directory (canonicalizePath, copyFile, createDirectoryIfMissing, doesDirectoryExist, doesFileExist, listDirectory, makeAbsolute)
import System.Environment (getArgs)
import System.Exit (ExitCode (ExitSuccess))
import System.FilePath ((</>), isAbsolute, normalise, takeBaseName)
import System.IO (BufferMode (LineBuffering), hSetBuffering, stdout)
import System.IO.Temp (withSystemTempDirectory)
import System.Process (CreateProcess (..), proc, readCreateProcessWithExitCode)
import System.Timeout (timeout)
import VisualHaskell.Analysis.Ghc910
import VisualHaskell.Semantic

data BuildTool = Cabal | Stack deriving (Eq, Show)

main :: IO ()
main = do
  hSetBuffering stdout LineBuffering
  arguments <- getArgs
  (fixture, tools) <- case arguments of
    [path] -> (,) <$> makeAbsolute path <*> pure [Cabal, Stack]
    [path, "stack"] -> (,) <$> makeAbsolute path <*> pure [Stack]
    [path, "cabal"] -> (,) <$> makeAbsolute path <*> pure [Cabal]
    _ -> fail "Usage: visual-haskell-project-loading-spike FIXTURE_DIRECTORY [cabal|stack]"
  forM_ tools $ \tool ->
    withSystemTempDirectory ("vh-project-stage0-" <> show tool <> "-") $ \temporaryRoot -> do
      root <- canonicalizePath temporaryRoot
      copyFixture tool fixture root
      completed <- timeout (300 * 1000000) (runProjectProbe tool root)
      case completed of
        Just () -> pure ()
        Nothing -> fail (show tool <> " Stage 0 probe exceeded five minutes")

runProjectProbe :: BuildTool -> FilePath -> IO ()
runProjectProbe tool root = do
  putStrLn ("\nStage 0: " <> show tool)
  let downstream = root </> "consumer/src/Downstream.hs"
      upstream = root </> "upstream/src/Upstream.hs"
      runConfig = defaultCradleRunConfig {cradleCacheDir = Just (CacheDir (root </> "bios-cache"))}
  implicit <- loadImplicitCradleWithConfig mempty runConfig downstream :: IO (Cradle Void)
  implicitOptions <- timed "implicit discovery" $
    getCompilerOptions (TargetWithContext downstream []) LoadFile implicit >>= requireSuccess
  version <- getRuntimeGhcVersion implicit >>= requireSuccess
  libdir <- getRuntimeGhcLibDir implicit >>= requireSuccess
  assert "exact project compiler" (version == "9.10.3")
  assert "compiler environment has flags" (not (null implicitOptions.componentOptions))
  -- Use the real production engine too, not just the raw-GHC proof below.
  source <- TextIO.readFile downstream
  let invocation = CompilerInvocation implicitOptions.componentRoot implicitOptions.componentOptions
        implicitOptions.componentDependencies libdir (Text.pack version)
      snapshot = document "Downstream" downstream source
  started <- startAnalysisEngine invocation >>= either (fail . show) pure
  flip finally (stopAnalysisEngine started) $ do
    analyzed <- timed "production engine, implicit component" $
      analyzeWithEngine started (Map.singleton snapshot.snapshotDocumentId snapshot)
        snapshot.snapshotDocumentId (WorkspaceGeneration 1) >>= either (fail . show) pure
    assert "implicit component typechecks in production engine" (analyzed.analysisCompleteness == Typechecked)

  forM_ [("consumer/app/Main.hs", executableTarget tool, "EXECUTABLE_CONTEXT"),
         ("consumer/test/Main.hs", testTarget tool, "TEST_CONTEXT")] $ \(relative, target, flag) -> do
    cradle <- explicitCradle tool root runConfig [target]
    options <- timed ("explicit " <> target) $
      getCompilerOptions (TargetWithContext (root </> relative) []) LoadFile cradle >>= requireSuccess
    assert "component-specific CPP option" (any (isInfixOf flag) options.componentOptions)
    rawTypecheck root libdir options

  cradle <- explicitCradle tool root runConfig (libraryTargets tool)
  options <- timed "local dependency environment" $
    getCompilerOptions (TargetWithContext downstream [upstream])
      LoadUnitsFromCradle cradle >>= requireSuccess
  let (units, _) = extractUnits options.componentOptions
  putStrLn ("  returned home-unit response files: " <> show (length units))
  forM_ units $ \response -> do
    let path = case response of '@' : rest -> rest; _ -> response
        absolute = if isAbsolute path then path else options.componentRoot </> path
    exists <- doesFileExist absolute
    assert "home-unit response file survives discovery" exists
  if null units
    then do
      assert "only Stack currently returns a flattened environment" (tool == Stack)
      putStrLn "  LIMITATION: Stack cradle flattens components; not a unit-preserving cross-package environment."
      resolved <- timed "Stack per-unit build metadata" (resolveStackBuildInfo root)
      unsavedDependencyProof root libdir resolved
    else unsavedDependencyProof root libdir options
  putStrLn ("  PASS: " <> show tool <> " discovery, component selection, and unsaved cross-package proof")

explicitCradle :: BuildTool -> FilePath -> CradleRunConfig -> [String] -> IO (Cradle Void)
explicitCradle tool root config targets =
  getCradleWithConfig mempty config absurd (Config.CradleConfig [] tree, root)
  where
    selected = case targets of target : _ -> Just target; [] -> Nothing
    tree = case tool of
      Cabal -> Config.Cabal (Config.CabalType selected Nothing (Just targets))
      Stack -> Config.Stack (Config.StackType selected Nothing (Just targets))

rawTypecheck :: FilePath -> FilePath -> ComponentOptions -> IO ()
rawTypecheck root libdir options = GHC.runGhc (Just libdir) $ do
  targets <- initSession' (Just (CacheDir (root </> "interfaces"))) options
  GHC.setTargets targets
  result <- GHC.load GHC.LoadAllTargets
  liftIO $ assert "explicit component typechecks with its own CPP context" (succeeded result)

unsavedDependencyProof :: FilePath -> FilePath -> ComponentOptions -> IO ()
unsavedDependencyProof root libdir options = do
  let upstream = root </> "upstream/src/Upstream.hs"
      downstream = root </> "consumer/src/Downstream.hs"
  originalUpstream <- TextIO.readFile upstream
  originalDownstream <- TextIO.readFile downstream
  now <- getCurrentTime
  GHC.runGhc (Just libdir) $ do
    targets <- initSession' (Just (CacheDir (root </> "multi-interfaces"))) options
    liftIO $ assert "GHC targets preserve distinct home-unit identities" $
      length (nub (map GHC.targetUnitId targets)) >= 2
    messages <- liftIO (newIORef [])
    pushLogHookM $ \_ _ _ _ message -> modifyIORef' messages (showSDocUnsafe message :)
    GHC.setTargets targets
    baseline <- timedGhc "multi-unit initial analysis" (GHC.load GHC.LoadAllTargets)
    liftIO $ assert "separate local home units initially typecheck" (succeeded baseline)
    let changedUpstream = "module Upstream (value) where\nvalue :: String\nvalue = \"unsaved\"\n"
        changedDownstream = "module Downstream (answer) where\nimport Upstream (value)\nanswer :: String\nanswer = value\n"
        overlay timestamp sources target =
          case lookupSource sources target of
            Just text -> target {GHC.targetContents = Just (stringToStringBuffer (Text.unpack text), timestamp)}
            Nothing -> target
        brokenSources = [(upstream, changedUpstream), (downstream, originalDownstream)]
        recoveredSources = [(upstream, changedUpstream), (downstream, changedDownstream)]
    liftIO $ assert "both home-unit source targets are available for overlays" $
      all (\sources -> length (filter (\target -> lookupSource sources target /= Nothing) targets) >= 2)
        [brokenSources, recoveredSources]
    GHC.setTargets (map (overlay (addUTCTime 1 now) brokenSources) targets)
    broken <- timedGhc "multi-unit unsaved mismatch" $
      GHC.handleSourceError (const (pure GHC.Failed)) (GHC.load GHC.LoadAllTargets)
    errors <- liftIO (readIORef messages)
    liftIO $ assert "unsaved upstream type change breaks unchanged downstream" $
      not (succeeded broken) && any (isInfixOf "Int") errors
    liftIO (writeIORef messages [])
    GHC.setTargets (map (overlay (addUTCTime 2 now) recoveredSources) targets)
    recovered <- timedGhc "multi-unit unsaved recovery" (GHC.load GHC.LoadAllTargets)
    liftIO $ assert "unsaved downstream correction recovers in the same multi-unit session" (succeeded recovered)
  currentUpstream <- TextIO.readFile upstream
  currentDownstream <- TextIO.readFile downstream
  assert "cross-package proof did not save either source" $
    currentUpstream == originalUpstream && currentDownstream == originalDownstream
  putStrLn "  PASS: unsaved upstream mismatch and downstream recovery, preserving both home units"

-- Stack repl merges settings. Cabal's build-info.json, produced by Stack's own
-- configured build, preserves actual unit IDs and flags without another solver.
-- Its schema is experimental: this is an isolated version-checked proof only.
data BuildInfo = BuildInfo String String [UnitBuildInfo]
data UnitBuildInfo = UnitBuildInfo String String [String] [String] [String]

instance FromJSON BuildInfo where
  parseJSON = withObject "Cabal build info" $ \value -> do
    compiler <- value .: "compiler"
    identifier <- withObject "compiler" (.: "compiler-id") compiler
    BuildInfo <$> value .: "cabal-lib-version" <*> pure identifier <*> value .: "components"

instance FromJSON UnitBuildInfo where
  parseJSON = withObject "unit build info" $ \value ->
    UnitBuildInfo <$> value .: "type" <*> value .: "unit-id" <*> value .: "compiler-args" <*> value .: "modules" <*> value .: "src-files"

resolveStackBuildInfo :: FilePath -> IO ComponentOptions
resolveStackBuildInfo root = do
  let directory = root </> "unit-responses"
  createDirectoryIfMissing True directory
  _ <- runStack root (["build", "--fast", "--jobs", "1"] <> libraryTargets Stack)
  responses <- traverse (\package -> do
      let packageRoot = root </> package
      dist <- trim <$> runStack packageRoot ["path", "--dist-dir"]
      BuildInfo cabalVersion compiler units <-
        LazyByteString.readFile (packageRoot </> dist </> "build-info.json") >>= either fail pure . eitherDecode
      assert "build metadata came from the tested Cabal library" ("3.12." `isPrefixOf` cabalVersion)
      assert "build metadata matches the selected compiler" (compiler == "ghc-9.10.3")
      case [unit | unit@(UnitBuildInfo kind _ _ _ _) <- units, kind == "lib"] of
        [UnitBuildInfo _ identifier arguments modules sources] -> do
          let (own, other) = if package == "upstream" then ("STAGE0_UPSTREAM", "STAGE0_DOWNSTREAM") else ("STAGE0_DOWNSTREAM", "STAGE0_UPSTREAM")
          assert "Stack metadata retains separate per-unit CPP settings" $
            any (isInfixOf own) arguments && not (any (isInfixOf other) arguments)
          let response = directory </> identifier <> ".rsp"
              analysisArguments = [argument | argument <- arguments, argument `notElem` ["--make", "-dynamic-too"]]
          writeFile response (escapeArgs (["-working-dir", packageRoot] <> analysisArguments <> modules <> sources <> ["-fno-code", "-fwrite-interface", "-O0"]))
          pure response
        _ -> fail "Stage 0 expected exactly one built library component per package") ["upstream", "consumer"]
  pure (ComponentOptions (concatMap (\response -> ["-unit", "@" <> response]) responses) root [])

runStack :: FilePath -> [String] -> IO String
runStack directory arguments = do
  (exitCode, output, errors) <- readCreateProcessWithExitCode ((proc "stack" arguments) {cwd = Just directory}) ""
  unless (exitCode == ExitSuccess) (fail ("Stack metadata preparation failed: " <> output <> errors))
  pure output

trim :: String -> String
trim = Text.unpack . Text.strip . Text.pack

lookupSource :: [(FilePath, Text.Text)] -> GHC.Target -> Maybe Text.Text
lookupSource sources target = case GHC.targetId target of
  GHC.TargetFile path _ -> lookup (normalise path) [(normalise file, text) | (file, text) <- sources]
  GHC.TargetModule name -> case [text | (file, text) <- sources, takeBaseName file == GHC.moduleNameString name] of
    [text] -> Just text
    _ -> Nothing

executableTarget, testTarget :: BuildTool -> String
executableTarget Cabal = "stage0-consumer:exe:stage0-consumer"
executableTarget Stack = "stage0-consumer:exe:stage0-consumer"
testTarget Cabal = "stage0-consumer:test:stage0-consumer-test"
testTarget Stack = "stage0-consumer:test:stage0-consumer-test"

libraryTargets :: BuildTool -> [String]
libraryTargets Cabal = ["stage0-consumer:lib:stage0-consumer", "stage0-upstream:lib:stage0-upstream"]
libraryTargets Stack = ["stage0-consumer:lib", "stage0-upstream:lib"]

copyFixture :: BuildTool -> FilePath -> FilePath -> IO ()
copyFixture tool source destination = do
  createDirectoryIfMissing True destination
  entries <- listDirectory source
  forM_ entries $ \entry -> when (keep entry) $ do
    let from = source </> entry
        to = destination </> entry
    directory <- doesDirectoryExist from
    if directory then copyFixture tool from to else copyFile from to
  where
    keep entry = entry `notElem` [".stack-work", "dist-newstyle", "stack.yaml.lock"]
      && (tool /= Cabal || entry /= "stack.yaml")
      && (tool /= Stack || entry /= "cabal.project")

document :: Text.Text -> FilePath -> Text.Text -> DocumentSnapshot
document identifier path text = DocumentSnapshot (DocumentId identifier) path (TextRevision 1) (contentHash text) text LF

requireSuccess :: Show a => CradleLoadResult a -> IO a
requireSuccess result = case result of
  CradleSuccess value -> pure value
  _ -> fail (show result)

succeeded :: GHC.SuccessFlag -> Bool
succeeded GHC.Succeeded = True
succeeded GHC.Failed = False

assert :: String -> Bool -> IO ()
assert label condition = unless condition (fail ("Stage 0 assertion failed: " <> label))

timed :: String -> IO a -> IO a
timed label action = do
  start <- getCurrentTime
  result <- action
  end <- getCurrentTime
  putStrLn ("  " <> label <> ": " <> show (round (diffUTCTime end start * 1000) :: Integer) <> "ms")
  pure result

timedGhc :: String -> GHC.Ghc a -> GHC.Ghc a
timedGhc label action = do
  start <- liftIO getCurrentTime
  result <- action
  end <- liftIO getCurrentTime
  liftIO $ putStrLn ("  " <> label <> ": " <> show (round (diffUTCTime end start * 1000) :: Integer) <> "ms")
  pure result
