{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

module VisualHaskell.Analysis.Ghc910.Project
  ( discoverCompilerInvocation
  , prepareProjectContext
  ) where

import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import Control.Monad (forM, unless, filterM, forM_)
import Data.Aeson
import qualified Data.ByteString.Lazy as LBS
import Data.List (find, nub, isPrefixOf)
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
import HIE.Bios.Types (LoadMode (..), TargetWithContext (..), CacheDir (..), CradleRunConfig (..))
import VisualHaskell.Analysis.Ghc910.Types
import VisualHaskell.Analysis.Ghc910.Compat (inspectCompilerUnits)

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
    if version /= "9.10.3"
      then
        Left
          GhcAnalysisFailure
            { failureCode = "incompatible-compiler"
            , failureMessage =
                "This worker requires GHC 9.10.3, but the project cradle selected " <> version
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
      config = defaultCradleRunConfig {cradleCacheDir = Just (CacheDir cache)}
      primary = fromMaybe (selected.projectComponentRoot </> "Main.hs") (listToMaybe selected.projectComponentFiles)
  (arguments, root, libdir, version, dependencies, primaryUnit, _unitRoots, unitDirectories) <- case profile.profileTool of
    StackProject -> prepareStack runner cache profile closure selected
    _ -> do
      cradle <- case profile.profileTool of
        CabalProject -> getCradleWithConfig mempty config absurd
          (Config.CradleConfig [] (Config.Cabal (Config.CabalType (listToMaybe targets) profile.profileConfiguration (Just targets))), profile.profileRoot)
        _ -> do
          configured <- findCradle primary
          maybe (loadImplicitCradle mempty primary) (loadCradle mempty) configured
      version <- getRuntimeGhcVersion (cradle :: Cradle Void) >>= require
      unless (version == "9.10.3") (fail ("Unsupported project compiler GHC " <> version <> "; installed analysis worker supports 9.10.3. Editing remains available."))
      libdir <- getRuntimeGhcLibDir cradle >>= require
      options <- getCompilerOptions (TargetWithContext primary (concatMap projectComponentFiles closure))
        (if profile.profileTool == CabalProject then LoadUnitsFromCradle else LoadFileWithContext) cradle >>= require
      units <- if profile.profileTool == CabalProject
        then do
          directory <- cabalBuildDir (CacheDir cache) profile.profileRoot
          readCabalPlan (directory </> "cache/plan.json")
        else pure []
      let matching component = find (\unit -> unit.planPackage == component.projectComponentPackage && unit.planComponent == Just (componentPlanName component)) units
      pure (options.componentOptions, options.componentRoot, libdir, version, options.componentDependencies,
        planUnitId <$> matching selected,
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
  unless (version == "9.10.3") (fail ("Unsupported project compiler GHC " <> version <> "; this worker supports 9.10.3. Editing remains available."))
  libdir <- Text.unpack . Text.strip <$> stack profile.profileRoot ["exec", "--", "ghc", "--print-libdir"]
  helperSource <- buildInfoHelperSource
  helperContents <- readFile helperSource
  let helper = cache </> ("build-info-ghc-9.10.3-" <> show (unContentHash (contentHash (Text.pack helperContents))))
  helperExists <- doesFileExist helper
  unless helperExists $ do
    _ <- stack profile.profileRoot ["exec", "--", "ghc", "-package", "Cabal", helperSource, "-outputdir", cache, "-o", helper]
    pure ()
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
      output <- runner packageRoot helper [packageRoot, packageRoot </> dist]
      BuildInfo cabalVersion compiler units <- either fail pure (eitherDecode (LBS.fromStrict (TextEncoding.encodeUtf8 output)))
      unless ("3.12." `isPrefixOf` cabalVersion && compiler == "ghc-9.10.3") $
        fail ("Unsupported Stack metadata version: Cabal " <> cabalVersion <> ", " <> compiler)
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
