{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
module VisualHaskell.Projects.Toolchains
  ( discoverToolchains, inspectCompiler, resolveProjectCompiler, compilerEnvironment
  , projectToolRunner, projectToolRunnerWith, findAnalysisWorker, buildAnalysisWorker, openGhcupTui
  , resolveCoordinator, resolveTool, workerSourceRoot, compilerFingerprintFor
  , supportedCompilerVersions, workerApiVersion
  , sourceFingerprint, ghcupTerminalScript
  , compilerIdentityAtBuild
  ) where

import Control.Exception (IOException, try, displayException, bracket)
import qualified Codec.Archive.Tar as Tar
import qualified Codec.Compression.GZip as GZip
import Control.Monad (forM, forM_, filterM, unless, void)
import Data.Aeson
import qualified Data.ByteString.Lazy as Bytes
import Data.List (nub, sort, intercalate)
import Data.Maybe (listToMaybe)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.IO as TextIO
import qualified Data.Text.Encoding
import qualified Data.Aeson.Types
import System.Directory hiding (findExecutable, executable)
import qualified System.Directory as Directory
import System.Environment (getExecutablePath, lookupEnv)
import System.FilePath
import System.Info (os)
import System.IO (hClose, openTempFile)
import System.IO.Temp (withTempDirectory, withSystemTempDirectory)
import System.FileLock (withFileLock, SharedExclusive (Exclusive))
import System.Timeout (timeout)
import Text.Read (readMaybe)
import Paths_visual_haskell_projects (getBinDir)
import VisualHaskell.Projects (profileArguments)
import VisualHaskell.Projects.Process
import VisualHaskell.Semantic

supportedCompilerVersions :: [Text]
supportedCompilerVersions = ["9.6.7", "9.10.3"]

workerApiVersion :: Int
workerApiVersion = 3

compilerFingerprintFor :: Text -> Text -> Text -> Text
compilerFingerprintFor version target unit = Text.pack (show (unContentHash (contentHash (Text.pack (show (version, target, unit))))))

-- Find the manager, never guess where it stores compilers. GUI applications do
-- not necessarily inherit the user's interactive shell PATH. No shell startup
-- scripts are sourced and no manager configuration is changed.
resolveTool :: String -> FilePath -> IO (Maybe FilePath)
resolveTool variable name = do
  configured <- lookupEnv variable
  found <- Directory.findExecutable name
  home <- getHomeDirectory
  extra <- lookupEnv "GHCUP_INSTALL_BASE_PREFIX"
  xdg <- lookupEnv "XDG_DATA_HOME"
  let defaults = maybe [] pure found <>
        [home </> ".ghcup/bin" </> name, "/opt/homebrew/bin" </> name, "/usr/local/bin" </> name] <>
        [base </> ".ghcup/bin" </> name | Just base <- [extra]] <>
        [base </> "ghcup/bin" </> name | Just base <- [xdg]]
      candidates = nub (maybe defaults pure configured)
  available <- filterM isExecutable candidates
  traverse canonicalizePath (listToMaybe available)
  where isExecutable path = doesFileExist path >>= \exists -> if exists then executable <$> getPermissions path else pure False
        executable permissions = Directory.executable permissions

inspectCompiler :: EnvironmentToolRunner -> FilePath -> Text -> FilePath -> IO CompilerIdentity
inspectCompiler runner directory origin requested = do
  found <- if isAbsolute requested then pure (Just requested) else Directory.findExecutable requested
  path <- maybe (fail ("Compiler executable not found: " <> requested)) canonicalizePath found
  version <- Text.strip <$> quick runner [] directory path ["--numeric-version"]
  libdir <- Text.unpack . Text.strip <$> quick runner [] directory path ["--print-libdir"]
  info <- quick runner [] directory path ["--info"]
  values <- maybe (fail "GHC returned an invalid --info response") pure (readMaybe (Text.unpack info) :: Maybe [(String, String)])
  target <- maybe (fail "GHC did not report its target platform") (pure . Text.pack) (lookup "Target platform" values)
  let packageTool = takeDirectory path </> "ghc-pkg"
  unit <- Text.strip <$> quick runner [] directory packageTool ["field", "ghc", "id", "--simple-output"]
  abi <- Text.strip <$> quick runner [] directory packageTool ["field", "ghc", "abi", "--simple-output"]
  unless (not (Text.null unit) && Text.length version < 64) (fail "Could not identify the installed GHC API package")
  absoluteLibdir <- canonicalizePath libdir
  unless (not (Text.null abi)) (fail "GHC did not report its compiler-library ABI hash")
  pure (CompilerIdentity path version absoluteLibdir target (compilerFingerprintFor version target (unit <> ":" <> abi)) origin)

-- Invoked by the adapter's Template Haskell splice. The standard worker build
-- supplies this path per process; Stack also places its compiler first on PATH.
-- The splice validates the version before embedding this observed ABI identity.
compilerIdentityAtBuild :: IO CompilerIdentity
compilerIdentityAtBuild = do
  path <- lookupEnv "VH_PROJECT_COMPILER" >>= maybe
    (resolveTool "VH_GHC" "ghc" >>= maybe (fail "Cannot identify the compiler used for this adapter build; set VH_PROJECT_COMPILER") pure) pure
  directory <- getCurrentDirectory
  inspectCompiler (runToolWithEnvironment (const (pure ()))) directory "Build compiler" path

discoverToolchains :: EnvironmentToolRunner -> FilePath -> IO ToolchainInventory
discoverToolchains runner directory = do
  ghcup <- resolveTool "VH_GHCUP" "ghcup"
  managed <- case ghcup of
    Nothing -> pure ([], ["GHCup is not installed or not discoverable; explicit and project-managed compilers remain supported."])
    Just manager -> do
      listed <- attempt (quick runner [("GHCUP_SKIP_UPDATE_CHECK", "1")] directory manager
        ["--offline", "list", "-t", "ghc", "-c", "installed", "--raw-format"])
      case listed of
        Left message -> pure ([], [message])
        Right output -> do
          results <- forM (nub [version | line <- Text.lines output, "ghc" : version : _ <- [Text.words line]]) $ \version ->
            attempt $ do
              path <- Text.unpack . Text.strip <$> quick runner [("GHCUP_SKIP_UPDATE_CHECK", "1")] directory manager
                ["--offline", "whereis", "ghc", Text.unpack version]
              inspectCompiler runner directory "GHCup" path
          pure ([compiler | Right compiler <- results], [message | Left message <- results])
  system <- resolveTool "VH_GHC" "ghc"
  other <- forM system $ \path -> attempt (inspectCompiler runner directory "PATH / configured" path)
  let compilers = fst managed <> [compiler | Right compiler <- maybe [] pure other]
      unique = foldl (\values compiler -> if any ((== compiler.compilerExecutable) . compilerExecutable) values then values else values <> [compiler]) [] compilers
  pure (ToolchainInventory unique Nothing Nothing ghcup (snd managed <> [message | Left message <- maybe [] pure other]))

compilerEnvironment :: CompilerIdentity -> IO [(String, String)]
compilerEnvironment = projectEnvironment . Just

-- hie-bios invokes Cabal/Stack by name and has no executable override API.
-- Supply private aliases to the exact tools we resolved, including versioned
-- executables whose directory contains no unversioned `cabal`/`stack` alias.
-- Only child environments change; never mutate PATH in the UI/coordinator.
projectEnvironment :: Maybe CompilerIdentity -> IO [(String, String)]
projectEnvironment compiler = do
  tools <- forM [("VH_CABAL", "cabal"), ("VH_STACK", "stack")] $ \(variable, name) -> do
    tool <- resolveTool variable name
    configured <- lookupEnv variable
    unless (configured == Nothing || tool /= Nothing) (fail (variable <> " does not name an executable"))
    pure (name, tool)
  base <- getXdgDirectory XdgCache "visual-haskell/tool-paths"
  let identifier = show (unContentHash (contentHash (Text.pack (show (tools, compiler /= Nothing, (2 :: Int))))))
      directory = base </> identifier
  createDirectoryIfMissing True base
  withFileLock (base </> identifier <.> "lock") Exclusive $ \_ -> do
    exists <- doesDirectoryExist directory
    unless exists $ withTempDirectory base "tools-" $ \temporary -> do
      forM_ tools $ \(name, tool) -> case tool of
        Nothing -> pure ()
        Just target | name == "cabal" -> createFileLink target (temporary </> name)
        Just target -> do
          let wrapper = temporary </> name
              command = shellQuote target <> " --no-install-ghc" <> (if compiler /= Nothing then " --system-ghc" else "")
          -- hie-bios 0.21 explicitly invokes `stack [--stack-yaml X]
          -- setup --silent` before runtime queries. Replace that installation
          -- command with a check of the installed compiler, not merely flags
          -- on a setup command. Reject unfamiliar setup forms conservatively.
          writeFile wrapper (unlines ["#!/bin/sh",
            "if [ \"$1\" = setup ]; then exec " <> command <> " path --compiler-exe >/dev/null; fi",
            "if [ \"$1\" = --stack-yaml ] && [ \"$3\" = setup ]; then",
            "  exec " <> command <> " --stack-yaml \"$2\" path --compiler-exe >/dev/null", "fi",
            "for argument in \"$@\"; do",
            "  if [ \"$argument\" = setup ]; then echo 'Manage compilers externally with GHCup or Stack' >&2; exit 1; fi", "done",
            "exec " <> command <> " \"$@\""])
          getPermissions wrapper >>= setPermissions wrapper . (\p -> p {Directory.executable = True})
      renameDirectory temporary directory
  path <- lookupEnv "PATH"
  defaultGhc <- maybe (resolveTool "VH_GHC" "ghc") (pure . Just . compilerExecutable) compiler
  pure $ [("PATH", intercalate [searchPathSeparator] (directory : maybe [] (pure . takeDirectory) defaultGhc <> maybe [] splitSearchPath path)),
    ("GHCUP_SKIP_UPDATE_CHECK", "1")] <>
    [("VH_PROJECT_COMPILER", chosen.compilerExecutable) | Just chosen <- [compiler]]

projectToolRunner :: (Text -> IO ()) -> CompilerIdentity -> IO ToolRunner
projectToolRunner progress = projectToolRunnerWith (runToolWithEnvironment progress)

-- Preparation helpers use this same tool selection but inherit their parent's
-- cancellation group instead of creating detached descendant groups.
projectToolRunnerWith :: EnvironmentToolRunner -> CompilerIdentity -> IO ToolRunner
projectToolRunnerWith run compiler = do
  environment <- compilerEnvironment compiler
  pure $ \directory executable arguments -> do
    tool <- if executable == "cabal" then resolveTool "VH_CABAL" "cabal"
      else if executable == "stack" then resolveTool "VH_STACK" "stack" else pure (Just executable)
    actual <- maybe (fail (executable <> " is not installed; manage it with GHCup or configure its executable path")) pure tool
    -- Use the existing compiler per process. Stack's own snapshot/compiler
    -- checks remain authoritative; no project/global files are rewritten.
    let options = ["--system-ghc" | executable == "stack"] <>
          ["--with-compiler=" <> compiler.compilerExecutable | executable == "cabal"]
    run environment directory actual
      (if executable == "stack" then options <> arguments else arguments <> options)

resolveProjectCompiler :: EnvironmentToolRunner -> ProjectProfile -> Maybe FilePath -> ToolchainInventory -> IO CompilerIdentity
resolveProjectCompiler runner profile override inventory = do
  explicit <- traverse (inspectCompiler runner profile.profileRoot "Explicit workspace override") override
  case profile.profileTool of
    CradleProject -> do
      -- Probe through hie-bios in any compatible adapter, without starting a
      -- GHC API session. The adapter performing discovery need not be compiled
      -- with the project's compiler. The coordinator remains GHC-independent.
      candidates <- analysisWorkerCandidates inventory.installedCompilers
      existing <- filterM doesFileExist candidates
      compatible <- filterM (\path -> do
        result <- attempt $ do
          output <- quick runner [] profile.profileRoot path ["--worker-info"]
          value <- either fail pure (eitherDecodeStrict' (encodeUtf8 output))
          either fail pure $ Data.Aeson.Types.parseEither (withObject "cradle probe" (.: "workerApi")) value
        pure (result == Right workerApiVersion)) existing
      probe <- maybe (fail "No compatible cradle probe is installed; install the application analysis adapter or configure VH_ANALYSIS_WORKER") pure (listToMaybe compatible)
      withSystemTempDirectory "vh-cradle-probe" $ \temporary -> do
        let request = temporary </> "request.json"
        Bytes.writeFile request (encode (profile.profileRoot, profile.profileConfiguration, inventory.installedCompilers))
        let query :: Maybe CompilerIdentity -> IO CompilerIdentity
            query candidate = do
              environment <- projectEnvironment candidate
              output <- runner environment profile.profileRoot probe ["--probe-cradle", request]
              either fail pure (eitherDecodeStrict' (encodeUtf8 output))
            choices = case explicit of Just compiler -> [Just compiler]; Nothing -> Nothing : map Just inventory.installedCompilers
            select [] errors = fail ("Could not resolve the cradle's installed compiler:\n" <> Text.unpack (Text.intercalate "\n" errors))
            select (candidate : rest) errors = attempt (query candidate) >>= \result -> case result of
              Right compiler -> case explicit of
                Just chosen | chosen.compilerFingerprint /= compiler.compilerFingerprint ->
                  fail "The explicit compiler does not match the compiler selected by hie.yaml; choose a compatible installed compiler."
                _ -> pure compiler
              Left message -> select rest (errors <> [message])
        select choices []
    CabalProject -> do
      cabal <- resolveTool "VH_CABAL" "cabal" >>= maybe (fail "cabal-install is missing; manage it with GHCup") pure
      let flags = profileArguments profile <> ["path", "--compiler-info", "--output-format=json"]
      environment <- projectEnvironment explicit
      output <- quick runner environment profile.profileRoot cabal flags
      value <- either fail pure (eitherDecodeStrict' (encodeUtf8 output))
      path <- case parseEitherCompiler value of Left message -> fail message; Right result -> pure result
      compiler <- inspectCompiler runner profile.profileRoot "Cabal project" path
      case explicit of
        Just chosen | chosen.compilerFingerprint /= compiler.compilerFingerprint ->
          fail "The explicit compiler does not satisfy this Cabal profile's with-compiler setting. Select a matching project profile; the IDE never silently rewrites project configuration."
        _ -> pure compiler
    StackProject -> do
      stack <- resolveTool "VH_STACK" "stack" >>= maybe (fail "Stack is missing; manage it with GHCup") pure
      let query candidate = do
            environment <- projectEnvironment candidate
            output <- quick runner environment profile.profileRoot stack
              (profileArguments profile <> ["path", "--compiler-exe"] <> ["--system-ghc" | candidate /= Nothing])
            inspectCompiler runner profile.profileRoot "Stack project" (Text.unpack (Text.strip output))
          candidates = case explicit of Just compiler -> [Just compiler]; Nothing -> Nothing : map Just inventory.installedCompilers
          select [] errors = fail ("No installed compiler satisfies this Stack configuration. Open GHCup TUI or choose a compatible executable.\n" <> Text.unpack (Text.intercalate "\n" errors))
          select (candidate : rest) errors = attempt (query candidate) >>= \result -> case result of
            Right compiler -> pure compiler
            Left message -> select rest (errors <> [message])
      select candidates []
  where
    encodeUtf8 = Data.Text.Encoding.encodeUtf8
    parseEitherCompiler = Data.Aeson.Types.parseEither (withObject "cabal path" $ \o -> o .: "compiler" >>= withObject "compiler" (.: "path"))

-- The worker advertises its compiled-in GHC unit ID, not whichever GHC happens
-- to be on PATH. Thus same-version but ABI-incompatible builds cannot match.
findAnalysisWorker :: EnvironmentToolRunner -> FilePath -> CompilerIdentity -> IO (Maybe FilePath)
findAnalysisWorker runner directory compiler = do
  candidates <- analysisWorkerCandidates [compiler]
  cache <- workerCache compiler
  existing <- filterM doesFileExist candidates
  sourceRoot <- workerSourceRoot
  expectedSource <- traverse sourceFingerprint sourceRoot
  valid <- filterM (\path -> do
    checked <- attempt $ do
      -- Only our cache is source-versioned here. Release workers are paired
      -- with the application by the release packager and still undergo ABI
      -- and wire-API validation below.
      fresh <- if path /= cache </> "worker" then pure True else do
        manifest <- attempt (Bytes.readFile (cache </> "manifest.json"))
        pure $ case manifest of
          Right bytes -> case (eitherDecode bytes :: Either String WorkerManifest) of
            Right value -> value.manifestCompilerFingerprint == compiler.compilerFingerprint &&
              value.manifestProtocolMajor == workerApiVersion &&
              maybe True (== value.manifestSourceFingerprint) expectedSource
            Left _ -> False
          Left _ -> False
      output <- quick runner [] directory path ["--worker-info"]
      value <- either fail pure (eitherDecodeStrict' (Data.Text.Encoding.encodeUtf8 output))
      either fail pure $ Data.Aeson.Types.parseEither (withObject "worker identity" $ \o -> do
        fingerprint <- o .: "compilerFingerprint"
        api <- o .: "workerApi"
        pure (fresh && fingerprint == compiler.compilerFingerprint && (api :: Int) == workerApiVersion)) value
    pure (checked == Right True)) existing
  traverse canonicalizePath (listToMaybe valid)

analysisWorkerCandidates :: [CompilerIdentity] -> IO [FilePath]
analysisWorkerCandidates compilers = do
  own <- getExecutablePath
  bin <- getBinDir
  caches <- traverse workerCache compilers
  configured <- lookupEnv "VH_ANALYSIS_WORKER"
  onPath <- Directory.findExecutable "visual-haskell-analysis-ghc910"
  let names = ["visual-haskell-analysis-ghc-" <> Text.unpack compiler.compilerVersion | compiler <- compilers] <>
        ["visual-haskell-analysis-ghc910"]
  pure (nub (maybe [] pure configured <> map (</> "worker") caches <>
    [directory </> name | directory <- [takeDirectory own, bin], name <- names] <> maybe [] pure onPath))

workerCache :: CompilerIdentity -> IO FilePath
workerCache compiler = do
  base <- getXdgDirectory XdgCache "visual-haskell/workers"
  pure (base </> Text.unpack compiler.compilerVersion </> Text.unpack compiler.compilerFingerprint)

workerSourceRoot :: IO (Maybe FilePath)
workerSourceRoot = do
  configured <- lookupEnv "VH_WORKER_SOURCE_ROOT"
  bundled <- lookupEnv "VH_WORKER_SOURCE_BUNDLE"
  own <- getExecutablePath
  current <- getCurrentDirectory
  let parents path = path : if takeDirectory path == path then [] else parents (takeDirectory path)
  candidates <- filterM (\path -> doesFileExist (path </> "vh/workers/cabal.project"))
    (nub (maybe [] pure configured <> parents (takeDirectory own) <> parents current))
  case bundled of
    Just archive -> Just <$> unpackSources archive
    Nothing -> case listToMaybe candidates of
      Just root -> Just <$> canonicalizePath root
      Nothing -> do
        archives <- filterM doesFileExist [takeDirectory own </> "visual-haskell-worker-sources.tar.gz"]
        traverse unpackSources (listToMaybe archives)

-- The release bundle is generated from the canonical sources, not a maintained
-- second copy. Extract only plain files/directories beneath vh/, never links
-- or escaping paths; stage atomically under an application-owned cache.
unpackSources :: FilePath -> IO FilePath
unpackSources archive = do
  bytes <- Bytes.readFile archive
  unless (Bytes.length bytes <= 16 * 1024 * 1024) (fail "Worker source bundle is too large")
  let expanded = Bytes.take (64 * 1024 * 1024 + 1) (GZip.decompress bytes)
  unless (Bytes.length expanded <= 64 * 1024 * 1024) (fail "Expanded worker source bundle is too large")
  entries <- validate (Tar.read expanded)
  base <- getXdgDirectory XdgCache "visual-haskell/worker-sources"
  let identifier = show (unContentHash (contentHash (Data.Text.Encoding.decodeLatin1 (Bytes.toStrict bytes))))
      destination = base </> identifier
  createDirectoryIfMissing True base
  withFileLock (base </> identifier <.> "lock") Exclusive $ \_ -> do
    ready <- doesFileExist (destination </> "vh/workers/cabal.project")
    unless ready $ withTempDirectory base "extract-" $ \staging -> do
      Tar.unpack staging (foldr Tar.Next Tar.Done entries :: Tar.Entries Tar.FormatError)
      complete <- doesFileExist (staging </> "vh/workers/cabal.project")
      unless complete (fail "Worker source bundle has no build project")
      renameDirectory staging destination
  pure destination
  where
    validate Tar.Done = pure []
    validate (Tar.Fail reason) = fail ("Invalid worker source archive: " <> show reason)
    validate (Tar.Next entry rest) = do
      let path = Tar.entryPath entry
          parts = splitDirectories path
          plain = case Tar.entryContent entry of Tar.NormalFile _ _ -> True; Tar.Directory -> True; _ -> False
      unless (plain && not (isAbsolute path) && not (".." `elem` parts) && take 1 parts == ["vh"])
        (fail "Unsafe path or link in worker source bundle")
      (entry :) <$> validate rest

buildAnalysisWorker :: EnvironmentToolRunner -> (Text -> IO ()) -> CompilerIdentity -> IO FilePath
buildAnalysisWorker runner progress compiler = do
  unless (compiler.compilerVersion `elem` supportedCompilerVersions) $
    fail ("Analysis adapters currently support " <> show supportedCompilerVersions <> "; compiler installation is managed externally")
  root <- workerSourceRoot >>= maybe (fail "Worker sources are unavailable. Install the Visual Haskell worker-source bundle or configure VH_WORKER_SOURCE_ROOT; no compiler will be downloaded.") pure
  cabal <- resolveTool "VH_CABAL" "cabal" >>= maybe (fail "cabal-install is missing; open GHCup TUI") pure
  cache <- workerCache compiler
  createDirectoryIfMissing True cache
  environment <- compilerEnvironment compiler
  let directory = root </> "vh/workers"
      flags = ["--project-file=cabal.project", "--with-compiler=" <> compiler.compilerExecutable, "--builddir=" <> cache </> "build"]
  progress "Building the analysis adapter with the existing compiler and normal Cabal store. No GHC installation or global selection will be changed."
  withFileLock (cache </> "build.lock") Exclusive $ \_ -> do
    _ <- runner environment directory cabal (["build", "exe:visual-haskell-analysis-ghc910", "-j2"] <> flags)
    built <- Text.unpack . Text.strip <$> runner environment directory cabal (["list-bin", "exe:visual-haskell-analysis-ghc910"] <> flags)
    -- No partially copied executable is ever visible to another workspace.
    bracket (do (path, handle) <- openTempFile cache "worker.new"; hClose handle; pure path) removeIfExists $ \temporary -> do
      copyFile built temporary
      permissions <- getPermissions built
      setPermissions temporary permissions
      renameFile temporary (cache </> "worker")
    source <- sourceFingerprint root
    bracket (do (path, handle) <- openTempFile cache "manifest.new"; hClose handle; pure path) removeIfExists $ \temporary -> do
      Bytes.writeFile temporary (encode (WorkerManifest compiler.compilerFingerprint compiler.compilerVersion source workerApiVersion))
      renameFile temporary (cache </> "manifest.json")
  findAnalysisWorker runner directory compiler >>= maybe (fail "Built worker did not match the selected compiler ABI") pure
  where removeIfExists path = doesFileExist path >>= \exists -> if exists then removeFile path else pure ()

sourceFingerprint :: FilePath -> IO Text
sourceFingerprint root = do
  values <- forM ["vh/workers/ghc-9.10", "vh/packages/semantic-model", "vh/packages/analysis-protocol", "vh/packages/projects", "vh/packages/analysis-client"] $ \relative -> do
    files <- concat <$> mapM (\part -> sources (root </> relative </> part)) ["src", "app", "data"]
    entries <- sort <$> listDirectory (root </> relative)
    manifests <- filterM doesFileExist
      [root </> relative </> entry | entry <- entries, entry == "package.yaml" || takeExtension entry == ".cabal"]
    forM (manifests <> files) $ \path -> (\value -> (makeRelative root path, contentHash value)) <$> TextIO.readFile path
  project <- TextIO.readFile (root </> "vh/workers/cabal.project")
  pure (Text.pack (show (unContentHash (contentHash (Text.pack (show (values, project)))))))
  where sources directory = do
          exists <- doesDirectoryExist directory
          entries <- if exists then sort <$> listDirectory directory else pure []
          concat <$> forM entries (\entry -> do
            let path = directory </> entry
            isDirectory <- doesDirectoryExist path
            if isDirectory then sources path else pure [path | takeExtension path == ".hs"])

resolveCoordinator :: IO FilePath
resolveCoordinator = do
  own <- getExecutablePath
  bin <- getBinDir
  configured <- lookupEnv "VH_PROJECT_COORDINATOR"
  found <- Directory.findExecutable "visual-haskell-project-coordinator"
  let candidates = maybe [] pure configured <> [takeDirectory own </> "visual-haskell-project-coordinator", bin </> "visual-haskell-project-coordinator"] <> maybe [] pure found
  existing <- filterM doesFileExist candidates
  maybe (fail "visual-haskell-project-coordinator is not installed") canonicalizePath (listToMaybe existing)

-- Launch the existing human UI in an external terminal. We neither implement a
-- terminal emulator nor automate/scrape a curses screen. Arguments are passed
-- structurally; compiler/version strings are never interpolated into a shell.
openGhcupTui :: EnvironmentToolRunner -> FilePath -> IO ()
openGhcupTui runner directory = do
  manager <- resolveTool "VH_GHCUP" "ghcup" >>= maybe (fail "GHCup is not installed; install it using the official GHCup instructions, or configure VH_GHCUP") pure
  if os == "darwin" then do
    -- A .command file lets LaunchServices use the user's terminal association.
    cache <- getXdgDirectory XdgCache "visual-haskell"
    createDirectoryIfMissing True cache
    let script = cache </> "Open GHCup.command"
    writeFile script (ghcupTerminalScript manager)
    getPermissions script >>= setPermissions script . (\p -> p {Directory.executable = True})
    void (runner [] directory "/usr/bin/open" [script])
  else do
    terminal <- Directory.findExecutable "x-terminal-emulator" >>= maybe (Directory.findExecutable "xterm") (pure . Just)
    command <- maybe (fail "No external terminal found; run ghcup tui in your terminal") pure terminal
    void (runner [] directory command ["-e", manager, "tui"])

ghcupTerminalScript :: FilePath -> String
ghcupTerminalScript manager = "#!/bin/sh\nexec " <> shellQuote manager <> " tui\n"

shellQuote :: String -> String
shellQuote value = "'" <> concatMap (\c -> if c == '\'' then "'\\''" else [c]) value <> "'"

quick :: EnvironmentToolRunner -> [(String, String)] -> ToolRunner
quick runner environment directory executable arguments = do
  result <- timeout 15000000 (runner environment directory executable arguments)
  maybe (fail (executable <> " toolchain query timed out")) pure result

attempt :: IO value -> IO (Either Text value)
attempt action = do
  result <- try action
  pure $ case result of Left (exception :: IOException) -> Left (Text.pack (displayException exception)); Right value -> Right value
