{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
module ToolchainSpec (runToolchainChecks) where

import Control.Exception (IOException, bracket, try)
import Control.Monad (unless, forM_)
import Data.Aeson (Value, encode, object, (.=), toJSON)
import qualified Data.ByteString.Lazy as Bytes
import Data.IORef
import Data.List (isPrefixOf)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import qualified Codec.Archive.Tar as Tar
import qualified Codec.Archive.Tar.Entry as Tar
import qualified Codec.Compression.GZip as GZip
import System.Directory
import System.Environment (lookupEnv, setEnv, unsetEnv)
import System.FilePath
import System.IO.Temp
import VisualHaskell.Projects.Process
import VisualHaskell.Projects.Toolchains
import VisualHaskell.Semantic

runToolchainChecks :: IO ()
runToolchainChecks = withSystemTempDirectory "vh-toolchains" $ \root -> do
  let first = root </> "9.6.7/bin/ghc"
      second = root </> "9.10.3/bin/ghc"
      manager = root </> "tools with 'quotes'/ghcup"
      cabal = root </> "tools/custom-cabal-3.16"
      stack = root </> "tools with 'quotes'/custom-stack"
  forM_ [first, second, manager, cabal, stack] $ \path -> do
    createDirectoryIfMissing True (takeDirectory path)
    writeFile path "test executable"
    permissions <- getPermissions path
    setPermissions path permissions {executable = True}
  withVariables [("VH_GHCUP", manager), ("VH_GHC", second), ("VH_CABAL", cabal),
      ("VH_STACK", stack), ("XDG_CACHE_HOME", root </> "cache"), ("VH_WORKER_SOURCE_ROOT", root)] $ do
    calls <- newIORef []
    let respond _ _ path arguments
          | path == manager && "list" `elem` arguments = pure "ghc 9.6.7 installed\nghc 9.10.3 set\n"
          | path == manager && "whereis" `elem` arguments = pure (Text.pack (if last arguments == "9.6.7" then first else second))
          | arguments == ["--numeric-version"] = pure (if "9.6.7" `elem` splitDirectories path then "9.6.7" else "9.10.3")
          | arguments == ["--print-libdir"] = pure (Text.pack (takeDirectory path </> "../lib"))
          | arguments == ["--info"] = pure "[(\"Target platform\",\"test-target\")]"
          | arguments == ["field", "ghc", "id", "--simple-output"] = pure (if "9.6.7" `elem` splitDirectories path then "ghc-9.6.7-abi1" else "ghc-9.10.3-abi2")
          | arguments == ["field", "ghc", "abi", "--simple-output"] = pure "compiler-library-abi"
          | path == cabal && "--compiler-info" `elem` arguments = pure (json (object ["compiler" .= object ["path" .= second]]))
          | otherwise = fail ("Unexpected tool query: " <> show (path, arguments))
        runner environment directory path arguments = do
          modifyIORef' calls (<> [(environment, path, arguments)])
          respond environment directory path arguments
    inventory <- discoverToolchains runner root
    check "GHCup and PATH observations deduplicate installed compilers" (length inventory.installedCompilers == 2)
    observed <- readIORef calls
    check "discovery uses offline GHCup, never install/set" (all (\(_, path, args) -> path /= manager || "--offline" `elem` args) observed)
    compiler <- case inventory.installedCompilers of value : _ -> pure value; _ -> fail "missing test compiler"
    writeFile cabal "#!/bin/sh\nprintf '%s\\n' explicit-cabal\n"
    writeFile stack "#!/bin/sh\nfor argument in \"$@\"; do [ \"$argument\" != setup ] || exit 99; done\nprintf '%s\\n' \"$@\"\n"
    withVariables [("PATH", "/usr/bin:/bin")] $ do
      environment <- compilerEnvironment compiler
      output <- runToolWithEnvironment (const (pure ())) environment root "/bin/sh" ["-c", "exec cabal"]
      check "hie-bios's bare cabal resolves the explicit renamed tool with a minimal GUI PATH" (Text.strip output == "explicit-cabal")
      arguments <- runToolWithEnvironment (const (pure ())) environment root "/bin/sh" ["-c", "exec stack path"]
      check "cradle Stack commands reuse system GHC and cannot install another compiler"
        (Text.lines arguments == ["--no-install-ghc", "--system-ghc", "path"])
      forM_ ["exec stack setup --silent", "exec stack --stack-yaml project.yaml setup --silent"] $ \command -> do
        setupOutput <- runToolWithEnvironment (const (pure ())) environment root "/bin/sh" ["-c", command]
        check "hie-bios setup is replaced by an installed-compiler query, never an installer" (Text.null setupOutput)
      check "tool PATH aliases never change the parent environment" . (== Just "/usr/bin:/bin") =<< lookupEnv "PATH"
    let profile = ProjectProfile "cabal" CabalProject root (Just (root </> "cabal.project"))
    check "same version with a different GHC package ABI cannot match"
      (compiler.compilerFingerprint /= compilerFingerprintFor "9.6.7" "test-target" "ghc-9.6.7-other-abi")
    resolved <- resolveProjectCompiler runner profile Nothing inventory
    check "Cabal reports its own actual compiler" (resolved.compilerExecutable == second)
    incompatible <- try (resolveProjectCompiler runner profile (Just first) inventory) :: IO (Either IOException CompilerIdentity)
    check "explicit compiler cannot silently rewrite an incompatible Cabal profile" (case incompatible of Left _ -> True; _ -> False)
    let probe = root </> "probe"
        cradleRunner environment directory path arguments
          | path == probe && arguments == ["--worker-info"] = pure (json (object ["workerApi" .= workerApiVersion]))
          | path == probe && take 1 arguments == ["--probe-cradle"] = pure (json (toJSON compiler))
          | otherwise = runner environment directory path arguments
    writeFile probe "probe executable"
    withVariables [("VH_ANALYSIS_WORKER", probe)] $ do
      cradleCompiler <- resolveProjectCompiler cradleRunner (profile {profileTool = CradleProject}) Nothing inventory
      check "cradle compiler comes from the runtime probe, not the PATH compiler" (cradleCompiler.compilerExecutable == first)
      conflict <- try (resolveProjectCompiler cradleRunner (profile {profileTool = CradleProject}) (Just second) inventory) :: IO (Either IOException CompilerIdentity)
      check "an incompatible explicit override cannot bypass the cradle compiler" (case conflict of Left _ -> True; _ -> False)
    let stackRunner environment _ path arguments
          | path == stack = if "--system-ghc" `elem` arguments && lookup "VH_PROJECT_COMPILER" environment == Just first
              then pure (Text.pack first) else fail "Stack requires the installed 9.6.7 compiler"
          | otherwise = runner environment root path arguments
    stackCompiler <- resolveProjectCompiler stackRunner (profile {profileTool = StackProject}) Nothing inventory
    check "Stack can reuse another installed GHC without selecting it globally" (stackCompiler.compilerExecutable == first)
    check "compiler selection never changes the parent's PATH" . (== Nothing) =<< lookupEnv "VH_PROJECT_COMPILER"
    withVariables [("VH_GHCUP", root </> "absent")] $ do
      withoutManager <- discoverToolchains runner root
      check "explicit/PATH compilers work without GHCup" (length withoutManager.installedCompilers == 1 && withoutManager.ghcupExecutable == Nothing)
    -- A fake Cabal build exercises publication, ABI and source-staleness checks
    -- without a compiler, network, or a separate dependency store.
    createDirectoryIfMissing True (root </> "vh/workers")
    writeFile (root </> "vh/workers/cabal.project") "packages: ghc-9.10\n"
    forM_ ["semantic-model", "analysis-protocol", "analysis-client", "projects"] $ \package ->
      createDirectoryIfMissing True (root </> "vh/packages" </> package)
    createDirectoryIfMissing True (root </> "vh/workers/ghc-9.10/src")
    writeFile (root </> "vh/workers/ghc-9.10/src/Test.hs") "module Test where\n"
    let built = root </> "built-worker"
        info fingerprint = json (object ["compilerFingerprint" .= fingerprint, "workerApi" .= workerApiVersion])
        builder env directory path args
          | path == cabal && take 1 args == ["build"] = do
              check "worker build uses selected existing compiler" (("--with-compiler=" <> first) `elem` args)
              check "worker build reuses Cabal's normal store" (not (any ("--store-dir" `isPrefixOf`) args))
              check "worker build sets only process-local compiler environment" (lookup "VH_PROJECT_COMPILER" env == Just first)
              writeFile built "worker binary"
              pure ""
          | path == cabal && take 1 args == ["list-bin"] = pure (Text.pack built)
          | args == ["--worker-info"] = pure (info (if "cache" `elem` splitDirectories path then compiler.compilerFingerprint else "wrong-abi"))
          | otherwise = runner env directory path args
    worker <- buildAnalysisWorker builder (const (pure ())) compiler
    check "worker published into one shared cache, not the workspace" ("workers" `elem` splitDirectories worker && takeFileName worker == "worker")
    ready <- findAnalysisWorker builder root compiler
    check "matching published worker is reusable by another workspace" (ready == Just worker)
    writeFile (root </> "vh/workers/ghc-9.10/src/Test.hs") "module Test where\nx = True\n"
    stale <- findAnalysisWorker builder root compiler
    check "worker source changes invalidate cached adapters" (stale == Nothing)
    failed <- try (buildAnalysisWorker (\_ _ _ _ -> fail "cancelled build") (const (pure ())) compiler) :: IO (Either IOException FilePath)
    check "failed build does not advertise a new worker" (case failed of Left _ -> True; _ -> False)
    script <- pure (ghcupTerminalScript manager)
    check "GHCup TUI shell quoting preserves executable paths with quotes and spaces" ("'\\''" `Text.isInfixOf` Text.pack script)
    scriptPath <- pure (root </> "launch.command")
    writeFile scriptPath script
    syntax <- runTool (const (pure ())) root "sh" ["-n", scriptPath]
    check "generated terminal launcher is valid POSIX shell" (Text.null syntax)
    let bundle = root </> "worker-sources.tar.gz"
        archiveEntry path contents = case Tar.toTarPath False path of
          Left message -> error message
          Right name -> Tar.simpleEntry name (Tar.NormalFile contents (Bytes.length contents))
    Bytes.writeFile bundle (GZip.compress (Tar.write [archiveEntry "vh/workers/cabal.project" "packages: ghc-9.10\n"]))
    withVariables [("VH_WORKER_SOURCE_BUNDLE", bundle)] $ do
      extracted <- workerSourceRoot >>= maybe (fail "source bundle was ignored") pure
      check "installed applications can extract canonical worker sources without a checkout" =<< doesFileExist (extracted </> "vh/workers/cabal.project")
      again <- workerSourceRoot
      check "source bundles share one immutable extraction across workspaces" (again == Just extracted)
    Bytes.writeFile bundle (GZip.compress (Tar.write [archiveEntry "../escape" "not allowed"]))
    withVariables [("VH_WORKER_SOURCE_BUNDLE", bundle)] $ do
      unsafe <- try workerSourceRoot :: IO (Either IOException (Maybe FilePath))
      check "source bundles cannot escape the application cache" (case unsafe of Left _ -> True; _ -> False)
    putStrLn "Toolchain discovery, ABI selection, DRY worker cache and TUI contracts passed"

json :: Value -> Text
json = Text.decodeUtf8 . Bytes.toStrict . encode

check :: String -> Bool -> IO ()
check label valid = unless valid (fail label)

withVariables :: [(String, String)] -> IO a -> IO a
withVariables [] action = action
withVariables ((key, value):rest) action = bracket (lookupEnv key <* setEnv key value)
  (maybe (unsetEnv key) (setEnv key)) (const (withVariables rest action))
