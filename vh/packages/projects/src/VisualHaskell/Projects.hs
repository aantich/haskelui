{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}
module VisualHaskell.Projects
  ( discoverProfiles, discoverProjectProfiles, discoverProject, readPackageComponents
  , ownersForPath, componentDependencyClosure, profileArguments, configurationPaths
  , PlanUnit (..), readCabalPlan, componentPlanName
  , buildInfoHelperSource
  , module VisualHaskell.Projects.Process
  ) where

import Control.Monad (filterM, forM)
import Control.Exception (IOException, try)
import Data.Aeson hiding (object)
import qualified Data.Aeson.KeyMap as KeyMap
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as LBS
import Data.List (nub, sort, isPrefixOf, isSuffixOf)
import Data.Maybe (listToMaybe, maybeToList)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.IO as TextIO
import qualified Distribution.PackageDescription as Cabal
import Distribution.PackageDescription.Parsec (parseGenericPackageDescription)
import Distribution.Fields.ParseResult (runParseResult)
import qualified Distribution.Fields as Fields
import qualified Data.ByteString.Char8 as BSC
import Distribution.Pretty (prettyShow)
import Distribution.Types.CondTree
import Distribution.Types.Dependency (depPkgName, depLibraries)
import qualified Distribution.Compat.NonEmptySet as NonEmptySet
import Distribution.Utils.Path (getSymbolicPath)
import System.Directory
import System.FilePath
import Language.Haskell.TH (runIO, stringE)
import Language.Haskell.TH.Syntax (addDependentFile)
import System.FileLock (withFileLock, SharedExclusive (Exclusive))
import System.IO.Temp (withTempDirectory)
import VisualHaskell.Semantic
import VisualHaskell.Projects.Process

buildInfoHelperSource :: IO FilePath
buildInfoHelperSource = do
  -- Embed the single canonical helper, so a Cabal-built/copied worker doesn't
  -- depend on Cabal having installed this local package's data-files first.
  let source = Text.pack $(do
        addDependentFile "data/BuildInfoHelper.hs"
        runIO (readFile "data/BuildInfoHelper.hs") >>= stringE)
  base <- getXdgDirectory XdgCache "visual-haskell/metadata-sources"
  createDirectoryIfMissing True base
  let path = base </> show (unContentHash (contentHash source)) <.> "hs"
  withFileLock (path <.> "lock") Exclusive $ \_ -> do
    exists <- doesFileExist path
    if exists then pure () else withTempDirectory base "source-" $ \temporary -> do
      let staged = temporary </> "BuildInfoHelper.hs"
      TextIO.writeFile staged source
      renameFile staged path
  pure path

-- Nearest configurations win per tool; alternative named configurations at the
-- selected root are exposed, and parent discovery stops at the repository edge.
discoverProfiles :: FilePath -> IO [ProjectProfile]
discoverProfiles requested = do
  root <- canonicalizePath requested
  ancestors <- containingRoots root
  found <- fmap concat $ forM ancestors $ \directory -> do
    files <- sort <$> listDirectory directory
    let stackFiles = [directory </> file | file <- files, "stack" `isPrefixOf` file, takeExtension file == ".yaml"]
        cabalFiles = [directory </> file | file <- files, file == "cabal.project" ||
          ("cabal.project." `isPrefixOf` file && not (any (`isSuffixOf` file) [".local", ".freeze"]))]
    pure ([makeProfile root StackProject directory (Just file) | file <- stackFiles]
      <> [makeProfile root CabalProject directory (Just file) | file <- cabalFiles])
  localCradle <- doesFileExist (root </> "hie.yaml")
  if localCradle && not (any ((== root) . profileRoot) found)
    -- A nested, explicitly configured cradle must not accidentally inherit
    -- unrelated Stack/Cabal configurations from its enclosing repository.
    then pure [makeProfile root CradleProject root (Just (root </> "hie.yaml"))]
    else if null found
    then do
      cabals <- cabalFilesAt root
      hie <- doesFileExist (root </> "hie.yaml")
      pure $ if not (null cabals) then [makeProfile root CabalProject root Nothing]
        else [makeProfile root CradleProject root (if hie then Just (root </> "hie.yaml") else Nothing)]
    else pure (nearestPerTool found)
  where
    makeProfile _base tool directory config = ProjectProfile
      (toolName tool <> ":" <> maybe "." (Text.pack . takeFileName) config) tool directory config
    nearestPerTool profiles = concatMap (\tool -> case filter ((== tool) . profileTool) profiles of
      [] -> []; first : rest -> first : filter ((== first.profileRoot) . profileRoot) rest) [StackProject, CabalProject]

toolName :: BuildTool -> Text
toolName StackProject = "stack"
toolName CabalProject = "cabal"
toolName CradleProject = "cradle"

containingRoots :: FilePath -> IO [FilePath]
containingRoots directory = do
  boundary <- doesPathExist (directory </> ".git")
  let parent = takeDirectory directory
  if boundary || parent == directory then pure [directory]
    else (directory :) <$> containingRoots parent

profileArguments :: ProjectProfile -> [String]
profileArguments profile = case (profile.profileTool, profile.profileConfiguration) of
  (StackProject, Just path) -> ["--stack-yaml", path, "--no-install-ghc"]
  (StackProject, Nothing) -> ["--no-install-ghc"]
  (CabalProject, Just path) -> ["--project-file=" <> path]
  _ -> []

discoverProject :: Bool -> ToolRunner -> FilePath -> Maybe Text -> FilePath -> IO ProjectCatalog
discoverProject trusted runner root preferred cache = do
  initial <- discoverProjectProfiles root preferred
  let profiles = initial.catalogProfiles
      selected = findProfile initial
  case (trusted, selected) of
    (False, _) -> pure (ProjectCatalog profiles Nothing [] [] ["Trust the workspace before running project tools"])
    (_, Nothing) -> pure (ProjectCatalog profiles Nothing [] [] ["Select a Stack or Cabal configuration"])
    (True, Just profile) -> do
      (packageFiles, planUnits, warnings) <- case profile.profileTool of
        StackProject -> do
          output <- runner profile.profileRoot "stack" (profileArguments profile <> ["ide", "packages", "--stdout", "--cabal-files"])
          files <- traverse (absoluteAt profile.profileRoot . Text.unpack) (filter (not . Text.null) (Text.lines output))
          pure (files, Nothing, [])
        CabalProject -> do
          let buildDirectory = cache </> "inventory" </> show (unContentHash (contentHash profile.profileId))
          createDirectoryIfMissing True buildDirectory
          let arguments = profileArguments profile <> ["build", "all", "--dry-run", "--builddir=" <> buildDirectory]
          planned <- try (runner profile.profileRoot "cabal" arguments) :: IO (Either IOException Text)
          warnings <- case planned of
            Right _ -> pure []
            -- Cabal writes a valid resolved plan, then reports that `all`
            -- has no default targets for a test/benchmark-only package.
            Left exception | "[Cabal-7127]" `Text.isInfixOf` Text.pack (show exception) -> pure []
            Left _ -> do
              -- A project's explicitly enabled optional components can fail to
              -- solve even when its libraries/executables are usable. Keep the
              -- usable plan; optional contexts are resolved only when selected.
              _ <- runner profile.profileRoot "cabal" (arguments <> ["--disable-tests", "--disable-benchmarks"])
              pure ["Optional component planning failed; libraries/executables remain available. Tests and benchmarks are resolved when selected."]
          plan <- LBS.readFile (buildDirectory </> "cache/plan.json") >>= either fail pure . eitherDecode
          directories <- parsePlanDirectories profile.profileRoot plan
          files <- concat <$> traverse cabalFilesAt directories
          units <- readCabalPlan (buildDirectory </> "cache/plan.json")
          pure (files, Just units, warnings)
        CradleProject -> pure ([], Nothing, [])
      declaredComponents <- if profile.profileTool == CradleProject
        then pure [ProjectComponent (ComponentId (profile.profileId <> ":default")) "Workspace" "Configured cradle" ""
          CradleComponent profile.profileRoot [profile.profileRoot] [] []]
        else concat <$> traverse (readPackageComponents profile) (nub packageFiles)
      let components = maybe declaredComponents (`effectiveComponents` declaredComponents) planUnits
      configs <- configurationPaths profile packageFiles
      pure (ProjectCatalog profiles (Just profile.profileId) components configs warnings)

-- Read-only profile discovery is published before any selected build tool is
-- invoked, so a broken restored profile cannot hide healthy alternatives.
discoverProjectProfiles :: FilePath -> Maybe Text -> IO ProjectCatalog
discoverProjectProfiles root preferred = do
  profiles <- discoverProfiles root
  let selected = case preferred of
        Just wanted -> listToMaybe (filter ((== wanted) . profileId) profiles)
        Nothing -> case profiles of [one] -> Just one; _ -> Nothing
  pure (ProjectCatalog profiles (profileId <$> selected) [] []
    [if selected == Nothing then "Select a Stack or Cabal configuration" else "Discovering project components…"])

findProfile :: ProjectCatalog -> Maybe ProjectProfile
findProfile catalog = listToMaybe [profile | profile <- catalog.catalogProfiles, Just profile.profileId == catalog.catalogSelectedProfile]

parsePlanDirectories :: FilePath -> Value -> IO [FilePath]
parsePlanDirectories root = withPlan
  where
    withPlan (Object object) = case KeyMap.lookup "install-plan" object of
      Just (Array nodes) -> fmap nub . fmap concat $ traverse localDirectory (foldr (:) [] nodes)
      _ -> fail "Cabal plan.json has no install-plan; unsupported build metadata"
    withPlan _ = fail "Invalid Cabal build plan"
    localDirectory (Object object) = case KeyMap.lookup "pkg-src" object of
      Just (Object source) | Just (String "local") <- KeyMap.lookup "type" source,
        Just (String path) <- KeyMap.lookup "path" source -> pure . pure =<< absoluteAt root (Text.unpack path)
      _ -> pure []
    localDirectory _ = pure []

data PlanUnit = PlanUnit
  { planUnitId :: !Text, planPackage :: !Text, planComponent :: !(Maybe Text)
  , planSourceRoot :: !(Maybe FilePath), planDistDirectory :: !(Maybe FilePath)
  , planDependencies :: ![Text]
  } deriving (Eq, Show)
instance FromJSON PlanUnit where
  parseJSON = withObject "Cabal plan unit" $ \o -> do
    source <- o .:? "pkg-src"
    root <- case source of
      Just (Object src) | Just (String "local") <- KeyMap.lookup "type" src -> src .:? "path"
      _ -> pure Nothing
    PlanUnit <$> o .: "id" <*> o .: "pkg-name" <*> o .:? "component-name" <*> pure root <*> o .:? "dist-dir" <*> o .:? "depends" .!= []

readCabalPlan :: FilePath -> IO [PlanUnit]
readCabalPlan path = do
  value <- LBS.readFile path >>= either fail pure . eitherDecode
  case value of
    Object object | Just units <- KeyMap.lookup "install-plan" object ->
      case fromJSON units of Success result -> pure result; Error message -> fail message
    _ -> fail "Unsupported Cabal install plan"

componentPlanName :: ProjectComponent -> Text
componentPlanName component = case component.projectComponentKind of
  LibraryComponent | component.projectComponentName == "library" -> "lib"
  LibraryComponent -> "lib:" <> component.projectComponentName
  ExecutableComponent -> "exe:" <> component.projectComponentName
  TestComponent -> "test:" <> component.projectComponentName
  BenchmarkComponent -> "bench:" <> component.projectComponentName
  ForeignLibraryComponent -> "flib:" <> component.projectComponentName
  CradleComponent -> ""

effectiveComponents :: [PlanUnit] -> [ProjectComponent] -> [ProjectComponent]
effectiveComponents units declared = concatMap effective declared
  where
    effective :: ProjectComponent -> [ProjectComponent]
    effective component = case findUnit component of
      Just unit -> [component {projectComponentDependencies =
        [dependency.projectComponentTarget | dependency <- declared,
          Just dependencyUnit <- [findDependencyUnit dependency], dependencyUnit.planUnitId `elem` unit.planDependencies,
          dependencyUnit.planComponent /= Nothing || dependency.projectComponentTarget `elem` component.projectComponentDependencies]}]
      -- Custom Setup uses whole-package plan nodes, not per-component nodes.
      -- Keep its Cabal-parsed descriptors; hie-bios/Setup supply the actual
      -- selected-component environment during preparation.
      Nothing | findWholePackage component /= Nothing -> [component]
      -- Inventory does not force optional dependencies to solve. The selected
      -- test/benchmark's own cradle finalizes its flags, buildability and units.
      Nothing | component.projectComponentKind `elem` [TestComponent, BenchmarkComponent] -> [component]
      Nothing -> []
    findUnit :: ProjectComponent -> Maybe PlanUnit
    findUnit component = listToMaybe [unit | unit <- units,
      unit.planPackage == component.projectComponentPackage,
      unit.planSourceRoot /= Nothing,
      unit.planComponent == Just (componentPlanName component)]
    findWholePackage :: ProjectComponent -> Maybe PlanUnit
    findWholePackage component = listToMaybe [unit | unit <- units,
      unit.planPackage == component.projectComponentPackage,
      unit.planComponent == Nothing, unit.planSourceRoot /= Nothing]
    findDependencyUnit component = case findUnit component of
      Just unit -> Just unit
      Nothing -> findWholePackage component

configurationPaths :: ProjectProfile -> [FilePath] -> IO [FilePath]
configurationPaths profile packageFiles = do
  let selectedConfiguration = maybe (profile.profileRoot </> "cabal.project") id profile.profileConfiguration
      associated = case profile.profileTool of
        CabalProject -> [selectedConfiguration <> suffix | suffix <- [".local", ".freeze"]]
        StackProject -> [selectedConfiguration <> ".lock"]
        CradleProject -> []
  imports <- case profile.profileTool of
    CabalProject -> concat <$> traverse (projectImports Set.empty) (selectedConfiguration : associated)
    _ -> pure []
  pure . nub $ imports <> associated <> maybeToList profile.profileConfiguration <> packageFiles
    <> [takeDirectory path </> "package.yaml" | path <- packageFiles]
    <> [profile.profileRoot </> path | path <- ["hie.yaml", "cabal.project", "cabal.project.local", "cabal.project.freeze", "stack.yaml.lock"]]

-- Project imports use Cabal's field parser, including comments, indentation and
-- conditional sections. Keep absent local imports in the watch set as well.
projectImports :: Set.Set FilePath -> FilePath -> IO [FilePath]
projectImports visited path
  | Set.member path visited = pure []
  | otherwise = do
      exists <- doesFileExist path
      if not exists then pure [path] else do
        parsed <- Fields.readFields <$> BS.readFile path
        let imports fields = concatMap (\field -> case field of
              Fields.Field (Fields.Name _ "import") lines' ->
                [BSC.unpack (BSC.dropWhile (== ' ') value) | Fields.FieldLine _ value <- lines']
              Fields.Section _ _ nested -> imports nested
              _ -> []) fields
            paths = case parsed of
              Left _ -> [] -- Cabal itself reports invalid project syntax.
              Right fields -> [normalise (takeDirectory path </> stripQuotes value) | value <- imports fields,
                not ("://" `Text.isInfixOf` Text.pack value)]
        nested <- concat <$> traverse (projectImports (Set.insert path visited)) paths
        pure (path : nested)
  where stripQuotes value = case reads value of [(quoted, "")] -> quoted; _ -> value

readPackageComponents :: ProjectProfile -> FilePath -> IO [ProjectComponent]
readPackageComponents profile path = do
  bytes <- BS.readFile path
  description <- case snd (runParseResult (parseGenericPackageDescription bytes)) of
    Left problem -> fail (path <> ": " <> show problem)
    Right value -> pure value
  let package = Text.pack (prettyShow (Cabal.pkgName (Cabal.package (Cabal.packageDescription description))))
      root = takeDirectory path
      describe kind name infos mainFiles exposed = do
        let sourceRoots = nub [normalise (root </> getSymbolicPath source) | info <- infos, source <- Cabal.hsSourceDirs info]
            roots = if null sourceRoots then [root] else sourceRoots
            modules = nub (exposed <> concatMap (map prettyShow . Cabal.otherModules) infos)
            candidates = [directory </> joinPath (Text.unpack <$> Text.splitOn "." (Text.pack name')) <.> extension
              | directory <- roots, name' <- modules, extension <- ["hs", "lhs"]]
              <> [directory </> mainFile | directory <- roots, mainFile <- mainFiles]
            target = targetName profile.profileTool package kind name
        files <- filterM doesFileExist candidates
        pure $ ProjectComponent (ComponentId (profile.profileId <> ":" <> Text.pack (makeRelative profile.profileRoot root) <> ":" <> target))
          package name target kind root roots (nub files)
          (nub [targetName profile.profileTool (Text.pack (prettyShow (depPkgName dependency))) LibraryComponent
                  (case libraryName of Cabal.LMainLibName -> "library"; Cabal.LSubLibName name' -> Text.pack (prettyShow name'))
               | info <- infos, dependency <- Cabal.targetBuildDepends info, libraryName <- NonEmptySet.toList (depLibraries dependency)])
      library name tree = let libraries = treeValues tree in describe LibraryComponent name (map Cabal.libBuildInfo libraries) [] (concatMap (map prettyShow . Cabal.exposedModules) libraries)
  mainLibraries <- traverse (library "library") (maybeToList (Cabal.condLibrary description))
  subLibraries <- traverse (\(name, tree) -> library (Text.pack (prettyShow name)) tree) (Cabal.condSubLibraries description)
  executables <- traverse (\(name, tree) -> let values = treeValues tree in
    describe ExecutableComponent (Text.pack (prettyShow name)) (map Cabal.buildInfo values) (map Cabal.modulePath values) []) (Cabal.condExecutables description)
  tests <- traverse (\(name, tree) -> let values = treeValues tree in
    describe TestComponent (Text.pack (prettyShow name)) (map Cabal.testBuildInfo values)
      [main | test <- values, Cabal.TestSuiteExeV10 _ main <- [Cabal.testInterface test]] []) (Cabal.condTestSuites description)
  benchmarks <- traverse (\(name, tree) -> let values = treeValues tree in
    describe BenchmarkComponent (Text.pack (prettyShow name)) (map Cabal.benchmarkBuildInfo values)
      [main | benchmark <- values, Cabal.BenchmarkExeV10 _ main <- [Cabal.benchmarkInterface benchmark]] []) (Cabal.condBenchmarks description)
  foreignLibraries <- traverse (\(name, tree) -> describe ForeignLibraryComponent (Text.pack (prettyShow name))
    (map Cabal.foreignLibBuildInfo (treeValues tree)) [] []) (Cabal.condForeignLibs description)
  pure (mainLibraries <> subLibraries <> executables <> tests <> benchmarks <> foreignLibraries)

treeValues :: CondTree v c a -> [a]
treeValues tree = condTreeData tree : concatMap (\branch -> treeValues (condBranchIfTrue branch) <> maybe [] treeValues (condBranchIfFalse branch)) (condTreeComponents tree)

targetName :: BuildTool -> Text -> ComponentKind -> Text -> Text
targetName tool package kind name = package <> ":" <> case kind of
  LibraryComponent | name == "library" -> if tool == StackProject then "lib" else "lib:" <> package
  LibraryComponent -> "lib:" <> name
  ExecutableComponent -> "exe:" <> name
  TestComponent -> "test:" <> name
  BenchmarkComponent -> "bench:" <> name
  ForeignLibraryComponent -> "flib:" <> name
  CradleComponent -> ""

ownersForPath :: [ProjectComponent] -> FilePath -> [ProjectComponent]
ownersForPath components path = case filter (elem (normalise path) . map normalise . projectComponentFiles) components of
  [] -> filter (any (`containsPath` path) . projectComponentSourceRoots) components
  exact -> exact

containsPath :: FilePath -> FilePath -> Bool
containsPath directory path = let relative = makeRelative (normalise directory) (normalise path)
  in not (isAbsolute relative) && case splitDirectories relative of ".." : _ -> False; _ -> True

componentDependencyClosure :: [ProjectComponent] -> ProjectComponent -> [ProjectComponent]
componentDependencyClosure components selected = go Set.empty [selected]
  where
    go :: Set.Set ComponentId -> [ProjectComponent] -> [ProjectComponent]
    go _ [] = []
    go seen (component : remaining)
      | Set.member component.projectComponentId seen = go seen remaining
      | otherwise = component : go (Set.insert component.projectComponentId seen)
          (remaining <> [dependency | dependency <- components, dependency.projectComponentKind == LibraryComponent,
            dependency.projectComponentTarget `elem` component.projectComponentDependencies ||
              (dependency.projectComponentName == "library" && dependency.projectComponentPackage `elem` component.projectComponentDependencies)])

cabalFilesAt :: FilePath -> IO [FilePath]
cabalFilesAt directory = do
  entries <- listDirectory directory
  pure [directory </> path | path <- sort entries, takeExtension path == ".cabal"]

absoluteAt :: FilePath -> FilePath -> IO FilePath
absoluteAt root path = canonicalizePath (if isAbsolute path then path else root </> path)
