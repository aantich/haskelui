{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module VisualHaskell.Analysis.Ghc910.Project
  ( discoverCompilerInvocation
  , prepareProjectContext
  , probeCradleCompiler
  ) where

import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import qualified Data.Text.IO as TextIO
import Control.Exception (try, IOException)
import Control.Monad (forM, unless, filterM, forM_)
import Data.Aeson
import qualified Data.ByteString.Lazy as LBS
import Data.List (find, nub)
import Data.Maybe (fromMaybe, listToMaybe)
import Data.Void (Void, absurd)
import qualified Data.Set as Set
import Data.Time.Clock (getCurrentTime)
import GHC.ResponseFile (escapeArgs)
import qualified HIE.Bios.Config as Config
import HIE.Bios.Cradle (getCradleWithConfig)
import HIE.Bios.Cradle.Cabal (cabalBuildDir)
import System.Directory
import System.FilePath
import System.FileLock (withFileLock, SharedExclusive (Exclusive))
import System.IO.Temp (withTempDirectory)
import VisualHaskell.Projects
import VisualHaskell.Semantic
import HIE.Bios
  ( ComponentOptions (..)
  , CradleLoadResult (..)
  , findCradle
  , getCompilerOptions
  , loadCradle
  , loadImplicitCradle
  , Cradle, defaultCradleRunConfig
  )
import HIE.Bios.Environment
  ( getRuntimeGhcLibDir
  , getRuntimeGhcVersion
  )
import HIE.Bios.Types (LoadMode (..), TargetWithContext (..), CacheDir (..), CradleRunConfig (..), Cradle (..), CradleAction (..))
import VisualHaskell.Projects.Toolchains (inspectCompiler)
import VisualHaskell.Analysis.Ghc910.Types
import VisualHaskell.Analysis.Ghc910.Version (compilerVersionText, compilerFingerprintText)
import VisualHaskell.Analysis.Ghc910.Compat (inspectCompilerUnits)

-- Runtime cradle queries are independent of the GHC API linked into this
-- executable. In particular, a 9.10 adapter may discover a 9.6 project before
-- the coordinator starts its matching 9.6 analysis process.
probeCradleCompiler :: EnvironmentToolRunner -> FilePath -> Maybe FilePath -> [CompilerIdentity] -> IO CompilerIdentity
probeCradleCompiler runner root configuration installed = do
  cradle <- maybe (loadImplicitCradle mempty (root </> "Main.hs")) (loadCradle mempty) configuration
  version <- Text.strip . Text.pack <$> (getRuntimeGhcVersion (cradle :: Cradle Void) >>= require)
  libdir <- getRuntimeGhcLibDir cradle >>= require >>= canonicalizePath
  matching <- filterM (\compiler -> (&& compiler.compilerVersion == version) . (== libdir) <$>
    canonicalizePath compiler.compilerLibDir) installed
  path <- case matching of
    compiler : _ -> pure compiler.compilerExecutable
    [] -> do
      -- This is hie-bios's own fallback for finding the executable behind a
      -- cradle; do not guess GHCup/Stack installation-directory layouts.
      output <- runGhcCmd (cradleOptsProg cradle)
        ["-package-env=-", "-ignore-dot-ghci", "-e",
         "Control.Monad.join (Control.Monad.fmap System.IO.putStr System.Environment.getExecutablePath)"] >>= require
      pure (Text.unpack (Text.strip (Text.pack output)))
  compiler <- inspectCompiler runner root "hie.yaml cradle" path
  unless (compiler.compilerVersion == version && compiler.compilerLibDir == libdir)
    (fail "Cradle compiler identity changed during discovery; retry the project")
  pure compiler
  where require = either (fail . show) pure . fromCradleResult "cradle-compiler"

discoverCompilerInvocation
  :: FilePath
  -> [FilePath]
  -> IO (Either GhcAnalysisFailure CompilerInvocation)
discoverCompilerInvocation primary context = do
  configured <- findCradle primary
  cradle <- maybe (loadImplicitCradle mempty primary) (loadCradle mempty) configured
  optionsResult <- getCompilerOptions (TargetWithContext primary context) LoadFileWithContext cradle
  libDirResult <- getRuntimeGhcLibDir cradle
  versionResult <- getRuntimeGhcVersion cradle
  pure $ do
    options <- fromCradleResult "component-options" optionsResult
    libDir <- fromCradleResult "compiler-libdir" libDirResult
    version <- Text.pack <$> fromCradleResult "compiler-version" versionResult
    if version /= compilerVersionText
      then
        Left
          GhcAnalysisFailure
            { failureCode = "incompatible-compiler"
            , failureMessage =
                "This worker requires GHC " <> compilerVersionText <> ", but the project cradle selected " <> version
            , failureRecoverable = False
            }
      else
        Right
          CompilerInvocation
            { invocationComponentRoot = options.componentRoot
            , invocationCompilerOptions = options.componentOptions
            , invocationCradleDependencies = options.componentDependencies
            , invocationCompilerLibDir = libDir
            , invocationCompilerVersion = version
            , invocationPrimaryUnit = Nothing
            , invocationUnitRoots = []
            , invocationSessionIdentity = Nothing
            , invocationUnitDirectories = []
            }

fromCradleResult :: Text -> CradleLoadResult value -> Either GhcAnalysisFailure value
fromCradleResult operation result =
  case result of
    CradleSuccess value -> Right value
    CradleNone ->
      Left
        GhcAnalysisFailure
          { failureCode = "cradle-none"
          , failureMessage = "No cradle accepted the " <> operation <> " request"
          , failureRecoverable = True
          }
    CradleFail cradleFailure -> Left (GhcAnalysisFailure "cradle-failed"
      (operation <> " failed: " <> Text.pack (show cradleFailure)) True)

-- The coordinator calls this off the protocol loop. Stack's repl merges
-- components, so its configured Cabal metadata is used instead. Cabal's cradle
-- already exports unit-preserving response files; we never flatten those.
prepareProjectContext :: ToolRunner -> FilePath -> ProjectCatalog -> ProjectComponent -> IO ResolvedContext
prepareProjectContext runner cache catalog selected = do
  profile <- maybe (fail "Select a build configuration first") pure $
    find (\p -> Just p.profileId == catalog.catalogSelectedProfile) catalog.catalogProfiles
  createDirectoryIfMissing True cache
  let closure = componentDependencyClosure catalog.catalogComponents selected
      targets = map (Text.unpack . projectComponentTarget) closure
      -- hie-bios 0.21 passes explicit cradle units directly to Cabal's CLI,
      -- but exposes no separate repl-options field. Only after inventory's
      -- optional-plan fallback, carry the same solver override into a required
      -- component's repl. Never disable a test/benchmark the user selected.
      optionalOverrides = [flag | profile.profileTool == CabalProject,
        not (null catalog.catalogWarnings),
        (kind, flag) <- [(TestComponent, "--disable-tests"), (BenchmarkComponent, "--disable-benchmarks")],
        selected.projectComponentKind /= kind]
      config = defaultCradleRunConfig {cradleCacheDir = Just (CacheDir cache)}
      primary = fromMaybe (selected.projectComponentRoot </> "Main.hs") (listToMaybe selected.projectComponentFiles)
  (arguments, root, libdir, version, dependencies, primaryUnit, _unitRoots, unitDirectories) <- case profile.profileTool of
    StackProject -> prepareStack runner cache profile closure selected
    _ -> do
      cradle <- case profile.profileTool of
        CabalProject -> getCradleWithConfig mempty config absurd
          (Config.CradleConfig [] (Config.Cabal (Config.CabalType (listToMaybe targets) profile.profileConfiguration (Just (targets <> optionalOverrides)))), profile.profileRoot)
        _ -> do
          configured <- findCradle primary
          maybe (loadImplicitCradle mempty primary) (loadCradle mempty) configured
      version <- getRuntimeGhcVersion (cradle :: Cradle Void) >>= require
      unless (Text.pack version == compilerVersionText) (fail ("Project compiler GHC " <> version <> " does not match this analysis worker " <> Text.unpack compilerVersionText <> ". Editing remains available."))
      libdir <- getRuntimeGhcLibDir cradle >>= require
      initialOptions <- getCompilerOptions (TargetWithContext primary (concatMap projectComponentFiles closure))
        (if profile.profileTool == CabalProject then LoadUnitsFromCradle else LoadFileWithContext) cradle >>= require
      units <- if profile.profileTool == CabalProject
        then do
          directory <- cabalBuildDir (CacheDir cache) profile.profileRoot
          readCabalPlan (directory </> "cache/plan.json")
        else pure []
      let hasCustomNode = any (\unit -> unit.planComponent == Nothing && unit.planSourceRoot /= Nothing &&
            unit.planPackage `elem` map projectComponentPackage closure) units
      needsRecovery <- if profile.profileTool == CabalProject && hasCustomNode
        then (< length closure) . length <$> inspectCompilerUnits libdir initialOptions
        else pure False
      -- Older Custom Setup libraries cannot accept --keep-temp-files, so
      -- hie-bios may silently demote multi-repl to the primary component.
      -- Recover exact per-component flags and assemble home units ourselves;
      -- never accept installed interfaces in place of open local libraries.
      (options, recoveredPrimary) <-
        if needsRecovery
        then recoverCabalUnits cache config profile closure selected optionalOverrides libdir
        else pure (initialOptions, Nothing)
      let matching component = find (\unit -> unit.planPackage == component.projectComponentPackage && unit.planComponent == Just (componentPlanName component)) units
      pure (options.componentOptions, options.componentRoot, libdir, version, options.componentDependencies,
        case recoveredPrimary of Just identifier -> Just identifier; Nothing -> planUnitId <$> matching selected,
        [(unit.planUnitId, component.projectComponentSourceRoots) | component <- closure, Just unit <- [matching component]],
        [(unit.planUnitId, component.projectComponentRoot) | component <- closure, Just unit <- [matching component]])
  session <- SessionId . ("context:" <>) . Text.pack . show <$> getCurrentTime
  inspected <- inspectCompilerUnits libdir (ComponentOptions arguments root dependencies)
  actualUnits <- traverse (\(identifier, directory, roots) ->
    (,,) identifier <$> canonicalizePath directory <*> traverse canonicalizePath roots) inspected
  let actualRoots = [(identifier, roots) | (identifier, _, roots) <- actualUnits]
      actualDirectories = [(identifier, directory) | (identifier, directory, _) <- actualUnits]
      primaryCandidates = [identifier | (identifier, directory, roots) <- actualUnits,
        normalise directory == normalise selected.projectComponentRoot,
        any (\source -> normalise source `elem` map normalise roots) selected.projectComponentSourceRoots]
      selectedUnit = case primaryUnit of
        Just identifier | identifier `elem` map (\(unit, _, _) -> unit) actualUnits -> Just identifier
        _ | selected.projectComponentKind `elem` [ExecutableComponent, TestComponent, BenchmarkComponent],
          "main" `elem` map (\(unit, _, _) -> unit) actualUnits -> Just "main"
        _ -> case primaryCandidates of
          [identifier] -> Just identifier
          _ -> case actualUnits of [(identifier, _, _)] -> Just identifier; _ -> Nothing
  unless (selectedUnit /= Nothing) (fail "Could not associate the selected component with its actual GHC home unit")
  absoluteDependencies <- traverse (\path -> canonicalizePath (if isAbsolute path then path else root </> path)) dependencies
  pure $ ResolvedContext selected.projectComponentId root arguments libdir (CompilerVersion (Text.pack version))
    (nub (catalog.catalogConfigurationFiles <> absoluteDependencies)) (nub (concatMap snd actualRoots))
    (nub (concatMap projectComponentFiles closure)) session selectedUnit actualRoots
    (if null actualDirectories then unitDirectories else actualDirectories)
  where
    require value = either (fail . show) pure (fromCradleResult "prepare-project" value)

recoverCabalUnits :: FilePath -> CradleRunConfig -> ProjectProfile -> [ProjectComponent] -> ProjectComponent
  -> [String] -> FilePath -> IO (ComponentOptions, Maybe Text)
recoverCabalUnits cache config profile closure selected overrides libdir = do
  let ordered :: Set.Set ComponentId -> ProjectComponent -> (Set.Set ComponentId, [ProjectComponent])
      ordered seen component
        | Set.member component.projectComponentId seen = (seen, [])
        | otherwise =
            let visit (old, values) dependency =
                  let (new, added) = ordered old dependency in (new, values <> added)
                dependencies = [dependency | dependency <- closure,
                  dependency.projectComponentTarget `elem` component.projectComponentDependencies]
                (visited, before) = foldl visit (Set.insert component.projectComponentId seen, []) dependencies
            in (visited, before <> [component])
      components = snd (ordered Set.empty selected)
  resolved <- forM components $ \component -> do
    let target = Text.unpack component.projectComponentTarget
        primary = fromMaybe (component.projectComponentRoot </> "Main.hs") (listToMaybe component.projectComponentFiles)
    cradle <- getCradleWithConfig mempty config absurd
      (Config.CradleConfig [] (Config.Cabal (Config.CabalType (Just target) profile.profileConfiguration (Just ([target] <> overrides)))), profile.profileRoot)
    result <- getCompilerOptions (TargetWithContext primary []) LoadUnitsFromCradle (cradle :: Cradle Void)
    options <- either (fail . show) pure (fromCradleResult "custom-setup-unit" result)
    units <- inspectCompilerUnits libdir options
    identifier <- case units of [(unit, _, _)] -> pure unit; _ -> fail ("Could not isolate Custom Setup component " <> target)
    arguments <- if "-unit" `elem` options.componentOptions
      then pure options.componentOptions
      else do
        let output = cache </> "recovered-units" </> Text.unpack identifier
            response = output <.> "rsp"
        createDirectoryIfMissing True output
        writeFile response (escapeArgs (["-working-dir", options.componentRoot] <> options.componentOptions <>
          ["-fno-code", "-fwrite-interface", "-O0", "-hidir", output, "-odir", output, "-hiedir", output, "-stubdir", output]))
        pure ["-unit", "@" <> response]
    let dependencies = [if isAbsolute path then path else options.componentRoot </> path | path <- options.componentDependencies]
    pure (component.projectComponentId, identifier, arguments, dependencies)
  unless (length (nub [identifier | (_, identifier, _, _) <- resolved]) == length resolved) $
    fail "Custom Setup contexts reused a home-unit identity; refusing an unsafe merged environment"
  pure (ComponentOptions (concat [arguments | (_, _, arguments, _) <- resolved]) profile.profileRoot
    (nub (concat [dependencies | (_, _, _, dependencies) <- resolved])),
    listToMaybe [identifier | (component, identifier, _, _) <- resolved, component == selected.projectComponentId])

data BuildInfo = BuildInfo String String [UnitBuildInfo]
data UnitBuildInfo = UnitBuildInfo
  { metadataName :: String, metadataUnit :: Text
  , metadataArguments :: [String], metadataModules :: [String], metadataSources :: [String]
  , metadataDependencies :: [Text], metadataRoots :: [FilePath] }
instance FromJSON BuildInfo where
  parseJSON = withObject "configured Cabal build info" $ \o -> do
    compiler <- o .: "compiler"
    identifier <- withObject "compiler" (.: "compiler-id") compiler
    BuildInfo <$> o .: "cabal-lib-version" <*> pure identifier <*> o .: "components"
instance FromJSON UnitBuildInfo where
  parseJSON = withObject "configured unit" $ \o -> UnitBuildInfo <$> o .: "context-name" <*> o .: "unit-id"
    <*> o .: "compiler-args" <*> o .: "modules" <*> o .: "src-files" <*> o .: "context-dependencies" <*> o .: "context-source-roots"

prepareStack :: ToolRunner -> FilePath -> ProjectProfile -> [ProjectComponent] -> ProjectComponent
  -> IO ([String], FilePath, FilePath, String, [FilePath], Maybe Text, [(Text, [FilePath])], [(Text, FilePath)])
prepareStack runner cache profile closure selected = do
  let stack directory args = runner directory "stack" (profileArguments profile <> args)
  version <- Text.unpack . Text.strip <$> stack profile.profileRoot ["exec", "--", "ghc", "--numeric-version"]
  unless (Text.pack version == compilerVersionText) (fail ("Project compiler GHC " <> version <> " does not match this analysis worker " <> Text.unpack compilerVersionText <> ". Editing remains available."))
  libdir <- Text.unpack . Text.strip <$> stack profile.profileRoot ["exec", "--", "ghc", "--print-libdir"]
  let cabalUnits = Text.words <$> stack profile.profileRoot ["exec", "--", "ghc-pkg", "field", "Cabal", "id", "--simple-output"]
  installedCabalUnits <- cabalUnits
  bootstrapUnit <- maybe (fail "The existing compiler has no usable Cabal library for metadata extraction") pure (listToMaybe installedCabalUnits)
  helper <- metadataHelper stack profile.profileRoot bootstrapUnit
  -- Stack/Setup own preprocessing and custom hooks. Repl performs their real
  -- initial-build-steps; --with-ghc replaces only the final, flattened GHCi
  -- launch with our no-op helper. Stack's merged flags can otherwise fail for
  -- internal libraries even with --no-load. Actual analysis uses the separate
  -- configured units below, never that merged GHCi environment.
  let preparationTarget
        | selected.projectComponentKind == LibraryComponent && selected.projectComponentName /= "library" = selected.projectComponentPackage
        | otherwise = selected.projectComponentTarget
  _ <- stack profile.profileRoot (["repl", Text.unpack preparationTarget, "--no-load",
      "--with-ghc", helper, "--ghci-options=--prepare-only"]
    <> ["--test" | selected.projectComponentKind == TestComponent] <> ["--bench" | selected.projectComponentKind == BenchmarkComponent])
  packages <- fmap concat $ forM (nub (map projectComponentRoot closure)) $ \packageRoot -> do
    dist <- Text.unpack . Text.strip <$> stack packageRoot ["path", "--dist-dir"]
    configured <- doesFileExist (packageRoot </> dist </> "setup-config")
    if not configured then pure [] else do
      -- Custom Setup may use a non-boot Cabal instance. Let Cabal's own reader
      -- validate the binary metadata rather than hand-parsing setup-config.
      candidates <- cabalUnits
      let load [] errors = fail ("No installed Cabal metadata adapter accepted " <> packageRoot <> ": " <> show errors)
          load (unit : rest) errors = do
            result <- try $ do
              selectedHelper <- metadataHelper stack profile.profileRoot unit
              output <- runner packageRoot selectedHelper [packageRoot, packageRoot </> dist]
              BuildInfo _ compiler units <- either fail pure (eitherDecode (LBS.fromStrict (TextEncoding.encodeUtf8 output)))
              unless (compiler == "ghc-" <> Text.unpack compilerVersionText) (fail ("Configured metadata selected " <> compiler))
              pure units
            case result of Right units -> pure units; Left (exception :: IOException) -> load rest (show exception : errors)
      units <- load (nub (bootstrapUnit : candidates)) []
      pure [(packageRoot, units)]
  let findMetadata :: ProjectComponent -> Maybe UnitBuildInfo
      findMetadata component =
        let units = fromMaybe [] (lookup component.projectComponentRoot packages)
            wanted = Text.unpack (componentPlanName component)
        in find ((== wanted) . metadataName) units
      available = [(component, unit) | component <- closure, Just unit <- [findMetadata component]]
      selectedUnit = findMetadata selected
      needed :: Set.Set Text -> [UnitBuildInfo] -> Set.Set Text
      needed visited [] = visited
      needed visited (unit : rest) | Set.member unit.metadataUnit visited = needed visited rest
        | otherwise = needed (Set.insert unit.metadataUnit visited)
            (rest <> [dependency | (_, dependency) <- available, dependency.metadataUnit `elem` unit.metadataDependencies])
  initial <- maybe (fail ("Stack did not configure " <> Text.unpack selected.projectComponentTarget)) pure selectedUnit
  let required = needed Set.empty [initial]
      ordered :: Set.Set Text -> UnitBuildInfo -> (Set.Set Text, [Text])
      ordered visited unit | Set.member unit.metadataUnit visited = (visited, [])
        | otherwise =
            let visit (old, values) dependency =
                  let (new, added) = ordered old dependency in (new, values <> added)
                localDependencies = [dependency | (_, dependency) <- available, dependency.metadataUnit `elem` unit.metadataDependencies]
                (seen, dependencies) = foldl visit (Set.insert unit.metadataUnit visited, []) localDependencies
            in (seen, dependencies <> [unit.metadataUnit])
      order = snd (ordered Set.empty initial)
  resolved <- forM [(component, unit) | identifier <- order, (component, unit) <- available, unit.metadataUnit == identifier, Set.member identifier required] $ \(component, unit) -> do
    let response = cache </> Text.unpack unit.metadataUnit <.> "rsp"
        flags = filter (`notElem` ["--make", "-dynamic-too"]) unit.metadataArguments
        roots = [normalise (component.projectComponentRoot </> path) | path <- if null unit.metadataRoots then ["."] else unit.metadataRoots]
        output = cache </> "units" </> Text.unpack unit.metadataUnit
    sources <- forM unit.metadataSources $ \path -> if isAbsolute path then pure path else do
      candidates <- filterM doesFileExist (nub [directory </> path | directory <- component.projectComponentRoot : roots])
      maybe (fail ("Configured component entry point " <> path <> " was not found in " <> show roots)) pure (listToMaybe candidates)
    forM_ ["hi", "obj", "hie", "stub"] (createDirectoryIfMissing True . (output </>))
    writeFile response (escapeArgs (["-working-dir", component.projectComponentRoot] <> flags
      <> unit.metadataModules <> sources <> ["-fno-code", "-fwrite-interface", "-O0",
        "-hidir", output </> "hi", "-odir", output </> "obj", "-hiedir", output </> "hie", "-stubdir", output </> "stub"]))
    pure (component, unit.metadataUnit, response, roots)
  pure (concatMap (\(_, _, response, _) -> ["-unit", "@" <> response]) resolved, profile.profileRoot, libdir, version,
    [], listToMaybe [identifier | (component, identifier, _, _) <- resolved, component.projectComponentId == selected.projectComponentId],
    [(identifier, roots) | (_, identifier, _, roots) <- resolved],
    [(identifier, component.projectComponentRoot) | (component, identifier, _, _) <- resolved])

-- One helper per compiler/Cabal ABI/source identity, shared by all workspaces.
-- Standard Cabal/Stack package databases remain the source of installed units.
metadataHelper :: (FilePath -> [String] -> IO Text) -> FilePath -> Text -> IO FilePath
metadataHelper stack root cabalUnit = do
  source <- buildInfoHelperSource
  contents <- TextIO.readFile source
  base <- getXdgDirectory XdgCache "visual-haskell/metadata-helpers"
  let directory = base </> Text.unpack compilerFingerprintText </> Text.unpack cabalUnit
      helper = directory </> show (unContentHash (contentHash contents))
  createDirectoryIfMissing True directory
  withFileLock (helper <.> "lock") Exclusive $ \_ -> do
    exists <- doesFileExist helper
    unless exists $ withTempDirectory directory "build-" $ \temporary -> do
      let binary = temporary </> "helper"
      _ <- stack root ["exec", "--", "ghc", "-hide-package", "Cabal", "-package-id", Text.unpack cabalUnit,
        source, "-outputdir", temporary, "-o", binary]
      renameFile binary helper
  pure helper
