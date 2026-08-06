{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

module VisualHaskell.TextMate.Registry
  ( grammarForLanguage
  , languageForPath
  , loadProviderRegistry
  , themeForIdentifier
  ) where

import Control.Exception (IOException, try)
import Control.Monad (forM)
import Data.Aeson
  ( FromJSON (..)
  , withObject
  , (.:)
  , (.:?)
  , (.!=)
  )
import Data.Aeson.Types (parseEither)
import Data.List (find, sort)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (catMaybes, fromMaybe)
import Data.Text (Text)
import qualified Data.Text as Text
import System.Directory
  ( doesDirectoryExist
  , doesFileExist
  , listDirectory
  )
import System.FilePath
  ( (</>)
  , isAbsolute
  , makeRelative
  , normalise
  , splitDirectories
  , takeBaseName
  , takeExtension
  , takeFileName
  )
import VisualHaskell.TextMate.Format (readStructuredFile)
import VisualHaskell.TextMate.Grammar
  ( Grammar (..)
  , GrammarError (..)
  , loadGrammar
  )
import VisualHaskell.TextMate.Types

data ExtensionManifest = ExtensionManifest
  { manifestName :: !Text
  , manifestLanguages :: ![ManifestLanguage]
  , manifestGrammars :: ![ManifestGrammar]
  , manifestThemes :: ![ManifestTheme]
  }

data ManifestLanguage = ManifestLanguage
  { manifestLanguageId :: !LanguageId
  , manifestLanguageAliases :: ![Text]
  , manifestLanguageExtensions :: ![Text]
  , manifestLanguageFilenames :: ![Text]
  , manifestLanguageFirstLine :: !(Maybe Text)
  }

data ManifestGrammar = ManifestGrammar
  { manifestGrammarLanguage :: !(Maybe LanguageId)
  , manifestGrammarScope :: !ScopeName
  , manifestGrammarPath :: !FilePath
  , manifestGrammarInjectionSelector :: !(Maybe Text)
  , manifestGrammarEmbeddedLanguages :: !(Map ScopeName LanguageId)
  }

data ManifestTheme = ManifestTheme
  { manifestThemeId :: !(Maybe ThemeId)
  , manifestThemeLabel :: !Text
  , manifestThemePath :: !FilePath
  }

instance FromJSON ExtensionManifest where
  parseJSON = withObject "VS Code extension manifest" $ \object -> do
    name <- object .:? "name" .!= "extension"
    contributions <- object .:? "contributes"
    case contributions of
      Nothing -> pure (ExtensionManifest name [] [] [])
      Just value ->
        withObject
          "VS Code contributions"
          ( \contributes ->
              ExtensionManifest name
                <$> contributes .:? "languages" .!= []
                <*> contributes .:? "grammars" .!= []
                <*> contributes .:? "themes" .!= []
          )
          value

instance FromJSON ManifestLanguage where
  parseJSON = withObject "VS Code language contribution" $ \object ->
    ManifestLanguage
      <$> (LanguageId <$> object .: "id")
      <*> object .:? "aliases" .!= []
      <*> object .:? "extensions" .!= []
      <*> object .:? "filenames" .!= []
      <*> object .:? "firstLine"

instance FromJSON ManifestGrammar where
  parseJSON = withObject "VS Code grammar contribution" $ \object -> do
    language <- fmap LanguageId <$> object .:? "language"
    scope <- ScopeName <$> object .: "scopeName"
    path <- object .: "path"
    injectionTargets <- object .:? "injectTo" .!= []
    embedded <- object .:? "embeddedLanguages" .!= Map.empty
    pure
      ManifestGrammar
        { manifestGrammarLanguage = language
        , manifestGrammarScope = scope
        , manifestGrammarPath = path
        , manifestGrammarInjectionSelector =
            if null injectionTargets
              then Nothing
              else Just (Text.intercalate "," injectionTargets)
        , manifestGrammarEmbeddedLanguages =
            Map.mapKeys ScopeName (Map.map LanguageId embedded)
        }

instance FromJSON ManifestTheme where
  parseJSON = withObject "VS Code theme contribution" $ \object ->
    ManifestTheme
      <$> fmap (fmap ThemeId) (object .:? "id")
      <*> object .:? "label" .!= "Theme"
      <*> object .: "path"

loadProviderRegistry :: TextMateConfiguration -> IO ProviderRegistry
loadProviderRegistry configuration = do
  bundled <-
    concat
      <$> traverse
        (scanExtensionCollection BundledProvider configuration)
        configuration.bundledExtensionRoots
  userExtensions <-
    concat
      <$> traverse
        (scanExtensionCollection UserExtensionProvider configuration)
        configuration.userExtensionRoots
  userGrammars <-
    concat
      <$> traverse
        (scanStandaloneGrammars configuration)
        configuration.userGrammarRoots
  userThemes <-
    concat
      <$> traverse scanStandaloneThemes configuration.userThemeRoots
  pure (foldl insertContribution emptyProviderRegistry (bundled <> userExtensions <> userGrammars <> userThemes))

data RegistryContribution
  = ContributedLanguage !LanguageDescriptor
  | ContributedGrammar !GrammarDescriptor
  | ContributedTheme !ThemeDescriptor
  | ContributionDiagnostic !ProviderDiagnostic

scanExtensionCollection
  :: (FilePath -> ProviderSource)
  -> TextMateConfiguration
  -> FilePath
  -> IO [RegistryContribution]
scanExtensionCollection sourceFor configuration root = do
  rootManifest <- doesFileExist (root </> "package.json")
  children <- listDirectorySafe root
  let candidateRoots =
        [root | rootManifest]
          <> [root </> child | child <- sort children]
  concat
    <$> traverse
      (\extensionRoot -> scanExtension sourceFor configuration extensionRoot)
      candidateRoots

scanExtension
  :: (FilePath -> ProviderSource)
  -> TextMateConfiguration
  -> FilePath
  -> IO [RegistryContribution]
scanExtension sourceFor configuration extensionRoot = do
  let manifestPath = extensionRoot </> "package.json"
  exists <- doesFileExist manifestPath
  if not exists
    then pure []
    else do
      decoded <- readStructuredFile configuration.maximumGrammarBytes manifestPath
      pure $ case decoded >>= mapLeft Text.pack . parseEither parseJSON of
        Left message -> [diagnostic manifestPath message]
        Right manifest -> contributionsFromManifest sourceFor extensionRoot manifest

contributionsFromManifest
  :: (FilePath -> ProviderSource)
  -> FilePath
  -> ExtensionManifest
  -> [RegistryContribution]
contributionsFromManifest sourceFor extensionRoot manifest =
  languageContributions <> grammarContributions <> themeContributions
  where
    source = sourceFor extensionRoot
    languageContributions =
      [ ContributedLanguage
          LanguageDescriptor
            { languageIdentifier = language.manifestLanguageId
            , languageAliases = language.manifestLanguageAliases
            , languageExtensions = language.manifestLanguageExtensions
            , languageFilenames = language.manifestLanguageFilenames
            , languageFirstLine = language.manifestLanguageFirstLine
            , languageSource = source
            }
      | language <- manifest.manifestLanguages
      ]
    grammarContributions =
      concatMap
        ( \grammar ->
            case confinedPath extensionRoot grammar.manifestGrammarPath of
              Nothing ->
                [diagnostic extensionRoot "Grammar contribution escapes its extension directory"]
              Just path ->
                [ ContributedGrammar
                    GrammarDescriptor
                      { grammarLanguage = grammar.manifestGrammarLanguage
                      , grammarScope = grammar.manifestGrammarScope
                      , grammarPath = path
                      , grammarInjectionSelector = grammar.manifestGrammarInjectionSelector
                      , grammarEmbeddedLanguages = grammar.manifestGrammarEmbeddedLanguages
                      , grammarSource = source
                      }
                ]
        )
        manifest.manifestGrammars
    themeContributions =
      concatMap
        ( \theme ->
            case confinedPath extensionRoot theme.manifestThemePath of
              Nothing ->
                [diagnostic extensionRoot "Theme contribution escapes its extension directory"]
              Just path ->
                [ ContributedTheme
                    ThemeDescriptor
                      { themeIdentifier =
                          fromMaybe
                            (ThemeId (manifest.manifestName <> "." <> Text.pack (takeBaseName path)))
                            theme.manifestThemeId
                      , themeLabel = theme.manifestThemeLabel
                      , themePath = path
                      , themeSource = source
                      }
                ]
        )
        manifest.manifestThemes

scanStandaloneGrammars
  :: TextMateConfiguration
  -> FilePath
  -> IO [RegistryContribution]
scanStandaloneGrammars configuration root = do
  files <- immediateFiles root
  fmap concat . forM files $ \path -> do
    loaded <- loadGrammar configuration.maximumGrammarBytes configuration.maximumRuleCount path
    pure $ case loaded of
      Left failure -> [diagnostic path failure.grammarErrorMessage]
      Right grammar ->
        let identifier = languageIdFromGrammar path grammar
            source = UserGrammarProvider path
            extensions = fmap normalizeExtension grammar.grammarFileTypes
         in [ ContributedLanguage
                LanguageDescriptor
                  { languageIdentifier = identifier
                  , languageAliases = [displayLanguageId identifier]
                  , languageExtensions = extensions
                  , languageFilenames = []
                  , languageFirstLine = Nothing
                  , languageSource = source
                  }
            , ContributedGrammar
                GrammarDescriptor
                  { grammarLanguage = Just identifier
                  , grammarScope = grammar.grammarRootScope
                  , grammarPath = path
                  , grammarInjectionSelector = Nothing
                  , grammarEmbeddedLanguages = Map.empty
                  , grammarSource = source
                  }
            ]

scanStandaloneThemes :: FilePath -> IO [RegistryContribution]
scanStandaloneThemes root = do
  files <- immediateFiles root
  pure
    [ ContributedTheme
        ThemeDescriptor
          { themeIdentifier = ThemeId (Text.pack (takeBaseName path))
          , themeLabel = Text.pack (takeBaseName path)
          , themePath = path
          , themeSource = UserThemeProvider path
          }
    | path <- files
    ]

insertContribution :: ProviderRegistry -> RegistryContribution -> ProviderRegistry
insertContribution registry contribution =
  case contribution of
    ContributionDiagnostic message ->
      registry {registryDiagnostics = registry.registryDiagnostics <> [message]}
    ContributedLanguage language ->
      registry
        { registryLanguages =
            Map.insert language.languageIdentifier language registry.registryLanguages
        , registryDiagnostics =
            conflictDiagnostic
              "language"
              language.languageIdentifier.unLanguageId
              (Map.member language.languageIdentifier registry.registryLanguages)
              registry.registryDiagnostics
        }
    ContributedGrammar grammar ->
      registry
        { registryGrammarsByLanguage =
            maybe
              registry.registryGrammarsByLanguage
              (\language -> Map.insert language grammar registry.registryGrammarsByLanguage)
              grammar.grammarLanguage
        , registryGrammarsByScope =
            Map.insert grammar.grammarScope grammar registry.registryGrammarsByScope
        }
    ContributedTheme theme ->
      registry
        { registryThemes = Map.insert theme.themeIdentifier theme registry.registryThemes
        , registryDiagnostics =
            conflictDiagnostic
              "theme"
              theme.themeIdentifier.unThemeId
              (Map.member theme.themeIdentifier registry.registryThemes)
              registry.registryDiagnostics
        }

conflictDiagnostic :: Text -> Text -> Bool -> [ProviderDiagnostic] -> [ProviderDiagnostic]
conflictDiagnostic kind identifier hasConflict existing
  | hasConflict =
      existing
        <> [ ProviderDiagnostic
               Nothing
               ("A higher-priority user " <> kind <> " replaced " <> identifier)
           ]
  | otherwise = existing

languageForPath :: ProviderRegistry -> FilePath -> Maybe LanguageId
languageForPath registry path =
  languageIdentifier
    <$> find matches (Map.elems registry.registryLanguages)
  where
    filename = Text.toCaseFold (Text.pack (takeFileName path))
    extension = Text.toCaseFold (Text.pack (takeExtension path))
    matches :: LanguageDescriptor -> Bool
    matches language =
      filename `elem` fmap Text.toCaseFold language.languageFilenames
        || extension `elem` fmap (Text.toCaseFold . normalizeExtension) language.languageExtensions

grammarForLanguage :: ProviderRegistry -> LanguageId -> Maybe GrammarDescriptor
grammarForLanguage registry identifier =
  Map.lookup identifier registry.registryGrammarsByLanguage

themeForIdentifier :: ProviderRegistry -> ThemeId -> Maybe ThemeDescriptor
themeForIdentifier registry identifier = Map.lookup identifier registry.registryThemes

languageIdFromGrammar :: FilePath -> Grammar -> LanguageId
languageIdFromGrammar path grammar =
  case Text.splitOn "." grammar.grammarRootScope.unScopeName of
    _ : identifier : _ -> LanguageId identifier
    _ -> LanguageId (Text.pack (takeBaseName path))

displayLanguageId :: LanguageId -> Text
displayLanguageId = (.unLanguageId)

normalizeExtension :: Text -> Text
normalizeExtension extension
  | Text.isPrefixOf "." extension = extension
  | otherwise = "." <> extension

confinedPath :: FilePath -> FilePath -> Maybe FilePath
confinedPath root contribution
  | isAbsolute contribution = Nothing
  | any (== "..") (splitDirectories relative) = Nothing
  | otherwise = Just candidate
  where
    candidate = normalise (root </> contribution)
    relative = makeRelative (normalise root) candidate

immediateFiles :: FilePath -> IO [FilePath]
immediateFiles root = do
  names <- listDirectorySafe root
  catMaybes
    <$> traverse
      ( \name -> do
          let path = root </> name
          file <- doesFileExist path
          pure (if file && supportedResource path then Just path else Nothing)
      )
      (sort names)

supportedResource :: FilePath -> Bool
supportedResource path =
  let extension = Text.toCaseFold (Text.pack (takeExtension path))
   in extension `elem` [".json", ".tmlanguage", ".tmtheme", ".plist"]

listDirectorySafe :: FilePath -> IO [FilePath]
listDirectorySafe path = do
  exists <- doesDirectoryExist path
  if not exists
    then pure []
    else do
      result <- try (listDirectory path)
      pure (either (const []) id (result :: Either IOException [FilePath]))

diagnostic :: FilePath -> Text -> RegistryContribution
diagnostic path message =
  ContributionDiagnostic
    ProviderDiagnostic
      { providerDiagnosticSource = Just path
      , providerDiagnosticMessage = message
      }

mapLeft :: (left -> other) -> Either left right -> Either other right
mapLeft change = either (Left . change) Right
