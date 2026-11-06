{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
module Main (main) where
import Control.Monad (unless)
import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (async, cancel, waitCatch)
import Control.Exception (try, IOException)
import Data.IORef
import Data.Text (Text)
import System.Directory
import System.FilePath
import System.IO.Temp
import VisualHaskell.Projects
import VisualHaskell.Semantic

main :: IO ()
main = withSystemTempDirectory "vh-project-contracts" $ \root -> do
  createDirectory (root </> ".git")
  writeFile (root </> "stack.yaml") "resolver: lts-24.50\npackages: [.]\n"
  writeFile (root </> "cabal.project") "packages: .\n"
  calls <- newIORef (0 :: Int)
  let runner _ _ _ = modifyIORef' calls (+1) >> fail "ambiguous/untrusted discovery invoked a tool"
  catalog <- discoverProject True runner root Nothing (root </> "cache")
  check "both build tools require an explicit choice" (length catalog.catalogProfiles == 2 && catalog.catalogSelectedProfile == Nothing)
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
  check "library and executable are distinct descriptors" (length components == 2 && projectComponentId (head components) /= projectComponentId (last components))
  check "shared source preserves both contexts" (length (ownersForPath components (root </> "src/Shared.hs")) == 2)
  check "source prefix does not claim sibling directory" (null (ownersForPath components (root </> "src-other/New.hs")))
  check "local dependency closure contains library" (length (componentDependencyClosure components (last components)) == 2)
  writeFile (root </> "cabal.project") "packages: .\nimport: \"local config.project\"\n"
  writeFile (root </> "local config.project") "import: not-created-yet.config\n"
  configurations <- configurationPaths profile [package]
  check "Cabal's parser finds recursive imported project files, including absent imports"
    (all (`elem` configurations) [root </> "local config.project", root </> "not-created-yet.config"])
  process <- async (runTool (const (pure ())) root "sh" ["-c", "sleep 60 & echo ready > ready; wait"])
  let awaitReady 0 = fail "test tool did not start"
      awaitReady attempts = doesFileExist (root </> "ready") >>= \ready ->
        if ready then pure () else threadDelay 10000 >> awaitReady (attempts - 1)
  awaitReady (100 :: Int)
  cancel process
  _ <- waitCatch process
  missing <- try (runTool (const (pure ())) root "/definitely/missing/vh-tool" []) :: IO (Either IOException Text)
  check "missing tools fail without terminating the IDE" (case missing of Left _ -> True; _ -> False)
  putStrLn "Project discovery, trust, ownership and closure tests passed"

check :: String -> Bool -> IO ()
check message condition = unless condition (fail message)
