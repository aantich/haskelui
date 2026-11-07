{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
module Main (main) where
import Control.Monad (unless)
import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (async, cancel, waitCatch)
import Control.Exception (try, IOException, bracket)
import Data.IORef
import Data.Text (Text)
import System.Directory
import System.FilePath
import System.Environment (lookupEnv, setEnv, unsetEnv)
import System.IO.Temp
import System.Posix.Signals (nullSignal, signalProcess)
import VisualHaskell.Projects
import VisualHaskell.Semantic
import ToolchainSpec (runToolchainChecks)

main :: IO ()
main = withSystemTempDirectory "vh-project-contracts" $ \root -> do
  createDirectory (root </> ".git")
  writeFile (root </> "stack.yaml") "resolver: lts-24.50\npackages: [.]\n"
  writeFile (root </> "cabal.project") "packages: .\n"
  calls <- newIORef (0 :: Int)
  let runner _ _ _ = modifyIORef' calls (+1) >> fail "ambiguous/untrusted discovery invoked a tool"
  catalog <- discoverProject True runner root Nothing (root </> "cache")
  check "both build tools require an explicit choice" (length catalog.catalogProfiles == 2 && catalog.catalogSelectedProfile == Nothing)
  preview <- discoverProjectProfiles root (Just "stack:stack.yaml")
  check "restored profile exposes alternatives before running tools"
    (length preview.catalogProfiles == 2 && preview.catalogSelectedProfile == Just "stack:stack.yaml" && null preview.catalogComponents)
  untrusted <- discoverProject False runner root (Just "stack:stack.yaml") (root </> "cache")
  count <- readIORef calls
  check "untrusted project cannot invoke tools" (count == 0 && null untrusted.catalogComponents)
  let profile = ProjectProfile "fixture" CabalProject root (Just (root </> "cabal.project"))
      package = root </> "fixture.cabal"
  writeFile package "cabal-version: 3.0\nname: fixture\nversion: 0.1\nlibrary\n hs-source-dirs: src\n exposed-modules: Shared\n build-depends: base\n default-language: Haskell2010\nexecutable app\n main-is: Main.hs\n hs-source-dirs: app src\n other-modules: Shared\n build-depends: base, fixture\n default-language: Haskell2010\n"
  createDirectory (root </> "src")
  createDirectory (root </> "app")
  writeFile (root </> "src/Shared.hs") "module Shared where\n"
  writeFile (root </> "app/Main.hs") "main = pure ()\n"
  components <- readPackageComponents profile package
  check "library and executable are distinct descriptors" (case components of
    [first, second] -> first.projectComponentId /= second.projectComponentId
    _ -> False)
  check "shared source preserves both contexts" (length (ownersForPath components (root </> "src/Shared.hs")) == 2)
  check "source prefix does not claim sibling directory" (null (ownersForPath components (root </> "src-other/New.hs")))
  check "local dependency closure contains library" (length (componentDependencyClosure components (last components)) == 2)
  let internalPackage = root </> "internal.cabal"
  writeFile internalPackage "cabal-version: 3.0\nname: internal-fixture\nversion: 0.1\nlibrary details\n hs-source-dirs: src\n exposed-modules: Shared\n build-depends: base\n default-language: Haskell2010\nexecutable app\n main-is: Main.hs\n hs-source-dirs: app\n build-depends: base, internal-fixture:details\n default-language: Haskell2010\n"
  internalComponents <- readPackageComponents profile internalPackage
  check "internal-library dependency names retain component identity"
    (length (componentDependencyClosure internalComponents (last internalComponents)) == 2)
  writeFile (root </> "cabal.project") "packages: .\nimport: \"local config.project\"\n"
  writeFile (root </> "local config.project") "import: not-created-yet.config\n"
  configurations <- configurationPaths profile [package]
  check "Cabal's parser finds recursive imported project files, including absent imports"
    (all (`elem` configurations) [root </> "local config.project", root </> "not-created-yet.config"])
  writeFile (root </> "cabal.project.alternate") "packages: .\n"
  writeFile (root </> "cabal.project.alternate.local") "import: alternate-extra.config\n"
  writeFile (root </> "cabal.project.alternate.freeze") "constraints: base installed\n"
  profiles <- discoverProfiles root
  check "alternate local/freeze files are not selectable profiles" (length profiles == 3)
  createDirectory (root </> "nested-cradle")
  writeFile (root </> "nested-cradle/hie.yaml") "cradle:\n  direct:\n    arguments: [-isrc]\n"
  nested <- discoverProfiles (root </> "nested-cradle")
  check "nested explicit cradles do not inherit enclosing build-tool profiles"
    (case nested of [value] -> value.profileTool == CradleProject; _ -> False)
  namedConfigurations <- configurationPaths (profile {profileConfiguration = Just (root </> "cabal.project.alternate")}) [package]
  check "named Cabal configurations watch their own local/freeze files and imports"
    (all (`elem` namedConfigurations) [root </> "cabal.project.alternate.local", root </> "cabal.project.alternate.freeze", root </> "alternate-extra.config"])
  stackConfigurations <- configurationPaths (profile {profileTool = StackProject, profileConfiguration = Just (root </> "stack-alternate.yaml")}) [package]
  check "named Stack configurations watch their own lock file" (root </> "stack-alternate.yaml.lock" `elem` stackConfigurations)
  process <- async (runTool (const (pure ())) root "sh" ["-c", "sleep 60 & echo ready > ready; wait"])
  let awaitReady 0 = fail "test tool did not start"
      awaitReady attempts = doesFileExist (root </> "ready") >>= \ready ->
        if ready then pure () else threadDelay 10000 >> awaitReady (attempts - 1)
  awaitReady (100 :: Int)
  cancel process
  _ <- waitCatch process
  orphan <- async (runTool (const (pure ())) root "sh" ["-c", "sleep 60 & echo $! > orphan-pid; exit 0"])
  let awaitOrphan 0 = fail "test wrapper did not start"
      awaitOrphan attempts = doesFileExist (root </> "orphan-pid") >>= \ready ->
        if ready then pure () else threadDelay 10000 >> awaitOrphan (attempts - 1)
  awaitOrphan (100 :: Int)
  threadDelay 100000
  child <- read <$> readFile (root </> "orphan-pid")
  cancel orphan
  _ <- waitCatch orphan
  let awaitExit 0 = fail "cancelled tool left its orphaned child alive"
      awaitExit attempts = do
        alive <- try (signalProcess nullSignal child) :: IO (Either IOException ())
        case alive of Left _ -> pure (); Right () -> threadDelay 10000 >> awaitExit (attempts - 1)
  awaitExit (100 :: Int)
  logs <- newIORef []
  _ <- runTool (\message -> modifyIORef' logs (message :)) root "sh"
    ["-c", "printf 'pré' >&2; sleep 0.05; printf 'paration\\n' >&2"]
  messages <- readIORef logs
  check "fragmented tool stderr forms intact UTF-8 log lines" ("préparation" `elem` messages)
  let withVariable key value action = bracket (lookupEnv key <* setEnv key value)
        (maybe (unsetEnv key) (setEnv key)) (const action)
  withVariable "GHC_PACKAGE_PATH" "stack-package-dbs" $
    withVariable "GHC_ENVIRONMENT" "-" $
      withVariable "VH_PROJECT_TEST_ENV" "retained" $ do
        output <- runTool (const (pure ())) root "sh"
          ["-c", "test -z \"${GHC_PACKAGE_PATH+x}\" && test -z \"${GHC_ENVIRONMENT+x}\" && printf '%s' \"$VH_PROJECT_TEST_ENV\""]
        check "project tools discard inherited compiler overrides only" (output == "retained")
        check "tool sanitation does not mutate parent environment" . (== Just "stack-package-dbs") =<< lookupEnv "GHC_PACKAGE_PATH"
  missing <- try (runTool (const (pure ())) root "/definitely/missing/vh-tool" []) :: IO (Either IOException Text)
  check "missing tools fail without terminating the IDE" (case missing of Left _ -> True; _ -> False)
  putStrLn "Project discovery, trust, ownership and closure tests passed"
  runToolchainChecks

check :: String -> Bool -> IO ()
check message condition = unless condition (fail message)
