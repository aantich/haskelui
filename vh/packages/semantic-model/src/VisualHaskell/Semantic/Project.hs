{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Compiler/UI independent project contracts. Descriptors do not own live
-- sessions: a component survives configuration changes and worker restarts.
module VisualHaskell.Semantic.Project
  ( BuildTool (..), ComponentKind (..), ProjectProfile (..)
  , ProjectComponent (..), ProjectCatalog (..), ResolvedContext (..)
  , analysisInputsHash, emptyProjectCatalog
  ) where

import Data.Aeson
import Data.List (sortOn)
import Data.Text (Text)
import qualified Data.Text as Text
import GHC.Generics (Generic)
import VisualHaskell.Semantic.Types

data BuildTool = CabalProject | StackProject | CradleProject
  deriving (Eq, Ord, Show, Generic)
data ComponentKind = LibraryComponent | ExecutableComponent | TestComponent | BenchmarkComponent | ForeignLibraryComponent | CradleComponent
  deriving (Eq, Ord, Show, Generic)

data ProjectProfile = ProjectProfile
  { profileId :: !Text, profileTool :: !BuildTool, profileRoot :: !FilePath
  , profileConfiguration :: !(Maybe FilePath)
  } deriving (Eq, Show, Generic)

data ProjectComponent = ProjectComponent
  { projectComponentId :: !ComponentId
  , projectComponentPackage :: !Text
  , projectComponentName :: !Text
  , projectComponentTarget :: !Text
  , projectComponentKind :: !ComponentKind
  , projectComponentRoot :: !FilePath
  , projectComponentSourceRoots :: ![FilePath]
  , projectComponentFiles :: ![FilePath]
  , projectComponentDependencies :: ![Text]
  } deriving (Eq, Show, Generic)

data ProjectCatalog = ProjectCatalog
  { catalogProfiles :: ![ProjectProfile]
  , catalogSelectedProfile :: !(Maybe Text)
  , catalogComponents :: ![ProjectComponent]
  , catalogConfigurationFiles :: ![FilePath]
  , catalogWarnings :: ![Text]
  } deriving (Eq, Show, Generic)

data ResolvedContext = ResolvedContext
  { resolvedComponent :: !ComponentId
  , resolvedRoot :: !FilePath
  , resolvedArguments :: ![String]
  , resolvedCompilerLibDir :: !FilePath
  , resolvedCompilerVersion :: !CompilerVersion
  , resolvedConfigurationFiles :: ![FilePath]
  , resolvedSourceRoots :: ![FilePath]
  , resolvedSourceFiles :: ![FilePath]
  , resolvedSession :: !SessionId
  , resolvedPrimaryUnit :: !(Maybe Text)
  , resolvedUnitRoots :: ![(Text, [FilePath])]
  , resolvedUnitDirectories :: ![(Text, FilePath)]
  } deriving (Eq, Show, Generic)

emptyProjectCatalog :: ProjectCatalog
emptyProjectCatalog = ProjectCatalog [] Nothing [] [] []

-- Framing uses Show for tuples of strings/numbers (not concatenated paths).
-- This is a freshness guard, not a security/content-addressing primitive.
analysisInputsHash :: [DocumentSnapshot] -> ContentHash
analysisInputsHash = contentHash . Text.pack . show . fmap identity . sortOn snapshotDocumentId
  where
        identity :: DocumentSnapshot -> (DocumentId, FilePath, TextRevision, ContentHash)
        identity document = (document.snapshotDocumentId, document.snapshotPath,
          document.snapshotRevision, document.snapshotContentHash)

instance ToJSON BuildTool where
  toJSON value = toJSON $ case value of CabalProject -> ("cabal" :: Text); StackProject -> "stack"; CradleProject -> "cradle"
instance FromJSON BuildTool where
  parseJSON = withText "build tool" $ \value -> case value of
    "cabal" -> pure CabalProject; "stack" -> pure StackProject; "cradle" -> pure CradleProject; _ -> fail "unknown build tool"
instance ToJSON ComponentKind where
  toJSON value = toJSON $ case value of
    LibraryComponent -> ("library" :: Text); ExecutableComponent -> "executable"; TestComponent -> "test"
    BenchmarkComponent -> "benchmark"; ForeignLibraryComponent -> "foreign-library"; CradleComponent -> "cradle"
instance FromJSON ComponentKind where
  parseJSON = withText "component kind" $ \value -> case value of
    "library" -> pure LibraryComponent; "executable" -> pure ExecutableComponent; "test" -> pure TestComponent
    "benchmark" -> pure BenchmarkComponent; "foreign-library" -> pure ForeignLibraryComponent; "cradle" -> pure CradleComponent
    _ -> fail "unknown component kind"
instance ToJSON ProjectProfile where
  toJSON p = object ["id" .= p.profileId, "tool" .= p.profileTool, "root" .= p.profileRoot, "configuration" .= p.profileConfiguration]
instance FromJSON ProjectProfile where
  parseJSON = withObject "project profile" $ \o -> ProjectProfile <$> o .: "id" <*> o .: "tool" <*> o .: "root" <*> o .:? "configuration"
instance ToJSON ProjectComponent where
  toJSON c = object ["id" .= c.projectComponentId, "package" .= c.projectComponentPackage, "name" .= c.projectComponentName,
    "target" .= c.projectComponentTarget, "kind" .= c.projectComponentKind, "root" .= c.projectComponentRoot,
    "sourceRoots" .= c.projectComponentSourceRoots, "files" .= c.projectComponentFiles, "dependencies" .= c.projectComponentDependencies]
instance FromJSON ProjectComponent where
  parseJSON = withObject "project component" $ \o -> ProjectComponent <$> o .: "id" <*> o .: "package" <*> o .: "name"
    <*> o .: "target" <*> o .: "kind" <*> o .: "root" <*> o .: "sourceRoots" <*> o .: "files" <*> o .: "dependencies"
instance ToJSON ProjectCatalog where
  toJSON c = object ["profiles" .= c.catalogProfiles, "selectedProfile" .= c.catalogSelectedProfile,
    "components" .= c.catalogComponents, "configurationFiles" .= c.catalogConfigurationFiles, "warnings" .= c.catalogWarnings]
instance FromJSON ProjectCatalog where
  parseJSON = withObject "project catalog" $ \o -> ProjectCatalog <$> o .: "profiles" <*> o .:? "selectedProfile"
    <*> o .: "components" <*> o .: "configurationFiles" <*> o .: "warnings"
instance ToJSON ResolvedContext where
  toJSON c = object ["component" .= c.resolvedComponent, "root" .= c.resolvedRoot, "arguments" .= c.resolvedArguments,
    "libdir" .= c.resolvedCompilerLibDir, "compiler" .= c.resolvedCompilerVersion, "configurationFiles" .= c.resolvedConfigurationFiles,
    "sourceRoots" .= c.resolvedSourceRoots, "files" .= c.resolvedSourceFiles, "session" .= c.resolvedSession,
    "primaryUnit" .= c.resolvedPrimaryUnit, "unitRoots" .= c.resolvedUnitRoots, "unitDirectories" .= c.resolvedUnitDirectories]
instance FromJSON ResolvedContext where
  parseJSON = withObject "resolved context" $ \o -> ResolvedContext <$> o .: "component" <*> o .: "root" <*> o .: "arguments"
    <*> o .: "libdir" <*> o .: "compiler" <*> o .: "configurationFiles" <*> o .: "sourceRoots" <*> o .: "files" <*> o .: "session"
    <*> o .:? "primaryUnit" <*> o .:? "unitRoots" .!= []
    <*> o .:? "unitDirectories" .!= []
