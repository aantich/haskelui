{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedRecordDot #-}

module VisualHaskell.TextMate.Types
  ( ContentHash (..)
  , GrammarDescriptor (..)
  , GrammarGeneration (..)
  , HighlightCompleteness (..)
  , HighlightFailure (..)
  , HighlightResult (..)
  , HighlightSnapshot (..)
  , LanguageDescriptor (..)
  , LanguageId (..)
  , ProviderDiagnostic (..)
  , ProviderRegistry (..)
  , ProviderSource (..)
  , RegistryGeneration (..)
  , RegistrySummary (..)
  , ScopeName (..)
  , ScopeSpan (..)
  , ScopeStack (..)
  , TextMateCommand (..)
  , TextMateConfiguration (..)
  , TextMateServiceEvent (..)
  , ThemeDescriptor (..)
  , ThemeGeneration (..)
  , ThemeId (..)
  , TokenizedSnapshot (..)
  , contentHash
  , emptyProviderRegistry
  , highlightSnapshot
  , registrySummary
  ) where

import qualified Data.ByteString as ByteString
import Data.Bits (xor)
import Data.List (sort)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text.Encoding as TextEncoding
import Data.Word (Word64)
import System.FilePath (normalise)
import HaskeLUI.Core
  ( DocumentKey
  , ServiceStatus
  , TextLayer
  , TextRange
  , TextRevision
  , TraceSink
  )

newtype LanguageId = LanguageId {unLanguageId :: Text}
  deriving stock (Eq, Ord, Show)

newtype ScopeName = ScopeName {unScopeName :: Text}
  deriving stock (Eq, Ord, Show)

newtype ThemeId = ThemeId {unThemeId :: Text}
  deriving stock (Eq, Ord, Show)

newtype ContentHash = ContentHash {unContentHash :: Word64}
  deriving stock (Eq, Ord, Show)

newtype RegistryGeneration = RegistryGeneration {unRegistryGeneration :: Word64}
  deriving stock (Eq, Ord, Show)

newtype GrammarGeneration = GrammarGeneration {unGrammarGeneration :: Word64}
  deriving stock (Eq, Ord, Show)

newtype ThemeGeneration = ThemeGeneration {unThemeGeneration :: Word64}
  deriving stock (Eq, Ord, Show)

data ProviderSource
  = BundledProvider !FilePath
  | UserExtensionProvider !FilePath
  | UserGrammarProvider !FilePath
  | UserThemeProvider !FilePath
  deriving stock (Eq, Ord, Show)

data ProviderDiagnostic = ProviderDiagnostic
  { providerDiagnosticSource :: !(Maybe FilePath)
  , providerDiagnosticMessage :: !Text
  }
  deriving stock (Eq, Show)

data LanguageDescriptor = LanguageDescriptor
  { languageIdentifier :: !LanguageId
  , languageAliases :: ![Text]
  , languageExtensions :: ![Text]
  , languageFilenames :: ![Text]
  , languageFirstLine :: !(Maybe Text)
  , languageSource :: !ProviderSource
  }
  deriving stock (Eq, Show)

data GrammarDescriptor = GrammarDescriptor
  { grammarLanguage :: !(Maybe LanguageId)
  , grammarScope :: !ScopeName
  , grammarPath :: !FilePath
  , grammarInjectionSelector :: !(Maybe Text)
  , grammarEmbeddedLanguages :: !(Map ScopeName LanguageId)
  , grammarSource :: !ProviderSource
  }
  deriving stock (Eq, Show)

data ThemeDescriptor = ThemeDescriptor
  { themeIdentifier :: !ThemeId
  , themeLabel :: !Text
  , themePath :: !FilePath
  , themeSource :: !ProviderSource
  }
  deriving stock (Eq, Show)

data ProviderRegistry = ProviderRegistry
  { registryLanguages :: !(Map LanguageId LanguageDescriptor)
  , registryGrammarsByLanguage :: !(Map LanguageId GrammarDescriptor)
  , registryGrammarsByScope :: !(Map ScopeName GrammarDescriptor)
  , registryThemes :: !(Map ThemeId ThemeDescriptor)
  , registryDiagnostics :: ![ProviderDiagnostic]
  }
  deriving stock (Eq, Show)

emptyProviderRegistry :: ProviderRegistry
emptyProviderRegistry =
  ProviderRegistry
    { registryLanguages = Map.empty
    , registryGrammarsByLanguage = Map.empty
    , registryGrammarsByScope = Map.empty
    , registryThemes = Map.empty
    , registryDiagnostics = []
    }

data RegistrySummary = RegistrySummary
  { registryLanguageIds :: ![LanguageId]
  , registryThemeIds :: ![ThemeId]
  , registryDiagnosticCount :: !Int
  }
  deriving stock (Eq, Show)

registrySummary :: ProviderRegistry -> RegistrySummary
registrySummary registry =
  RegistrySummary
    { registryLanguageIds = sort (Map.keys registry.registryLanguages)
    , registryThemeIds = sort (Map.keys registry.registryThemes)
    , registryDiagnosticCount = length registry.registryDiagnostics
    }

data TextMateConfiguration = TextMateConfiguration
  { bundledExtensionRoots :: ![FilePath]
  , userExtensionRoots :: ![FilePath]
  , userGrammarRoots :: ![FilePath]
  , userThemeRoots :: ![FilePath]
  , selectedTheme :: !(Maybe ThemeId)
  , maximumGrammarBytes :: !Int
  , maximumThemeBytes :: !Int
  , maximumRuleCount :: !Int
  , maximumMatchesPerLine :: !Int
  , textMateTraceSink :: !TraceSink
  }

instance Eq TextMateConfiguration where
  left == right =
    bundledExtensionRoots left == bundledExtensionRoots right
      && userExtensionRoots left == userExtensionRoots right
      && userGrammarRoots left == userGrammarRoots right
      && userThemeRoots left == userThemeRoots right
      && selectedTheme left == selectedTheme right
      && maximumGrammarBytes left == maximumGrammarBytes right
      && maximumThemeBytes left == maximumThemeBytes right
      && maximumRuleCount left == maximumRuleCount right
      && maximumMatchesPerLine left == maximumMatchesPerLine right

instance Show TextMateConfiguration where
  show configuration =
    "TextMateConfiguration {bundledExtensionRoots = "
      <> show (bundledExtensionRoots configuration)
      <> ", userExtensionRoots = "
      <> show (userExtensionRoots configuration)
      <> ", userGrammarRoots = "
      <> show (userGrammarRoots configuration)
      <> ", userThemeRoots = "
      <> show (userThemeRoots configuration)
      <> ", selectedTheme = "
      <> show (selectedTheme configuration)
      <> ", maximumGrammarBytes = "
      <> show (maximumGrammarBytes configuration)
      <> ", maximumThemeBytes = "
      <> show (maximumThemeBytes configuration)
      <> ", maximumRuleCount = "
      <> show (maximumRuleCount configuration)
      <> ", maximumMatchesPerLine = "
      <> show (maximumMatchesPerLine configuration)
      <> ", textMateTraceSink = <trace-sink>}"

data HighlightSnapshot = HighlightSnapshot
  { highlightDocument :: !DocumentKey
  , highlightRevision :: !TextRevision
  , highlightContentHash :: !ContentHash
  , highlightPath :: !FilePath
  , highlightLanguageOverride :: !(Maybe LanguageId)
  , highlightText :: !Text
  }
  deriving stock (Eq, Show)

highlightSnapshot
  :: DocumentKey
  -> TextRevision
  -> FilePath
  -> Text
  -> HighlightSnapshot
highlightSnapshot document revision path source =
  HighlightSnapshot
    { highlightDocument = document
    , highlightRevision = revision
    , highlightContentHash = contentHash source
    , highlightPath = normalise path
    , highlightLanguageOverride = Nothing
    , highlightText = source
    }

contentHash :: Text -> ContentHash
contentHash =
  ContentHash
    . ByteString.foldl'
      (\hash byte -> (hash `xor` fromIntegral byte) * 1099511628211)
      14695981039346656037
    . TextEncoding.encodeUtf8

newtype ScopeStack = ScopeStack {unScopeStack :: [ScopeName]}
  deriving stock (Eq, Ord, Show)

data ScopeSpan = ScopeSpan
  { scopeSpanRange :: !TextRange
  , scopeSpanStack :: !ScopeStack
  }
  deriving stock (Eq, Show)

data TokenizedSnapshot = TokenizedSnapshot
  { tokenizedRevision :: !TextRevision
  , tokenizedContentHash :: !ContentHash
  , tokenizedSpans :: ![ScopeSpan]
  }
  deriving stock (Eq, Show)

data HighlightCompleteness
  = CompleteHighlight
  | VisibleRangeHighlight
  deriving stock (Eq, Show)

data HighlightResult = HighlightResult
  { resultDocument :: !DocumentKey
  , resultRevision :: !TextRevision
  , resultContentHash :: !ContentHash
  , resultLanguage :: !LanguageId
  , resultRegistryGeneration :: !RegistryGeneration
  , resultGrammarGeneration :: !GrammarGeneration
  , resultThemeGeneration :: !ThemeGeneration
  , resultLayer :: !TextLayer
  , resultCompleteness :: !HighlightCompleteness
  }
  deriving stock (Eq, Show)

data HighlightFailure = HighlightFailure
  { highlightFailureDocument :: !(Maybe DocumentKey)
  , highlightFailurePath :: !(Maybe FilePath)
  , highlightFailureMessage :: !Text
  }
  deriving stock (Eq, Show)

data TextMateCommand
  = ReloadTextMateResources
  | SelectTextMateTheme !ThemeId
  | UpsertTextMateDocument !HighlightSnapshot
  | CloseTextMateDocument !DocumentKey
  | PrioritizeTextMateDocument !DocumentKey
  deriving stock (Eq, Show)

data TextMateServiceEvent
  = TextMateServiceStatus !ServiceStatus
  | TextMateResourcesChanged
  | TextMateRegistryChanged !RegistryGeneration !RegistrySummary
  | TextMateHighlightReady !HighlightResult
  | TextMateHighlightUnavailable !DocumentKey !TextRevision !ContentHash !Text
  | TextMateFailure !HighlightFailure
  deriving stock (Eq, Show)
