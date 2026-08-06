{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module VisualHaskell.TextMate.Service
  ( textMateCommandKey
  , textMateResourceSubscription
  , textMateService
  , textMateServiceKey
  , textMateSyntaxLayerKey
  ) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (async, cancel)
import Control.Exception (IOException, SomeException, displayException, try)
import Control.Applicative ((<|>))
import Control.Monad (forM_, when)
import Data.List (sort)
import Data.IORef
  ( IORef
  , newIORef
  , readIORef
  , writeIORef
  )
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Time.Clock (UTCTime)
import System.Directory
  ( doesDirectoryExist
  , doesFileExist
  , getFileSize
  , getModificationTime
  , listDirectory
  )
import System.FilePath ((</>))
import HaskeLUI.Core
  ( EventCoalescingKey (..)
  , DocumentKey (..)
  , ExternalEvent
  , ExternalSink (..)
  , OverflowPolicy (..)
  , Service
  , ServiceContext (..)
  , ServiceEndpoint
  , ServiceHealth (..)
  , ServiceKey (..)
  , ServiceOptions (..)
  , Subscription
  , SubscriptionFingerprint (..)
  , SubscriptionKey (..)
  , TextLayerKey (..)
  , TextRevision (..)
  , TraceSeverity (..)
  , defaultServiceOptions
  , emitExternalEvent
  , trace
  , serviceWithStatus
  , subscription
  )
import VisualHaskell.TextMate.Grammar
import VisualHaskell.TextMate.Registry
import VisualHaskell.TextMate.Theme
import VisualHaskell.TextMate.Tokenizer
import VisualHaskell.TextMate.Types

textMateServiceKey :: ServiceKey
textMateServiceKey = ServiceKey "visual-haskell.textmate"

textMateSyntaxLayerKey :: TextLayerKey
textMateSyntaxLayerKey = TextLayerKey 1

-- | Poll the user-owned provider folders and emit one coalescible reload
-- notification after a copy, edit, rename, or removal. Bundled resources are
-- immutable for the lifetime of an installed executable and are not watched.
textMateResourceSubscription
  :: TextMateConfiguration
  -> (TextMateServiceEvent -> ExternalEvent model)
  -> Subscription model
textMateResourceSubscription configuration toExternal =
  subscription
    (SubscriptionKey "visual-haskell.textmate.resources")
    (SubscriptionFingerprint (Text.pack (show roots)))
    (\sink -> do
      baseline <- resourceTreeStamp roots
      worker <- async (watch sink baseline)
      pure (cancel worker)
    )
  where
    roots =
      configuration.userExtensionRoots
        <> configuration.userGrammarRoots
        <> configuration.userThemeRoots

    watch sink previous = do
      threadDelay 1000000
      current <- resourceTreeStamp roots
      when (current /= previous) $ emitExternalEvent sink (toExternal TextMateResourcesChanged)
      watch sink current

data ResourceStamp = ResourceStamp
  { resourceStampPath :: !FilePath
  , resourceStampModified :: !(Maybe UTCTime)
  , resourceStampSize :: !(Maybe Integer)
  }
  deriving stock (Eq, Ord, Show)

resourceTreeStamp :: [FilePath] -> IO [ResourceStamp]
resourceTreeStamp roots = fmap sort (concat <$> traverse stampPath roots)

stampPath :: FilePath -> IO [ResourceStamp]
stampPath path = do
  isDirectory <- doesDirectoryExist path
  if isDirectory
    then do
      entriesResult <- try (listDirectory path)
      case entriesResult of
        Left (_ :: IOException) -> pure [ResourceStamp path Nothing Nothing]
        Right entries -> do
          own <- fileStamp path
          nested <- concat <$> traverse (stampPath . (path </>)) (sort entries)
          pure (own : nested)
    else do
      isFile <- doesFileExist path
      if isFile then pure . pure =<< fileStamp path else pure []

fileStamp :: FilePath -> IO ResourceStamp
fileStamp path = do
  modified <- try (getModificationTime path)
  size <- try (getFileSize path)
  pure
    ResourceStamp
      { resourceStampPath = path
      , resourceStampModified = either (const Nothing) Just (modified :: Either IOException UTCTime)
      , resourceStampSize = either (const Nothing) Just (size :: Either IOException Integer)
      }

data CachedHighlight = CachedHighlight
  { cachedSnapshot :: !HighlightSnapshot
  , cachedLanguage :: !LanguageId
  , cachedGrammarPath :: !FilePath
  , cachedTokenized :: !TokenizedDocument
  }

data EngineState = EngineState
  { engineRegistry :: !ProviderRegistry
  , engineRegistryGeneration :: !RegistryGeneration
  , engineGrammarGeneration :: !GrammarGeneration
  , engineThemeGeneration :: !ThemeGeneration
  , engineSelectedTheme :: !(Maybe ThemeId)
  , engineTheme :: !TextMateTheme
  , engineGrammars :: !(Map FilePath Grammar)
  , engineDocuments :: !(Map DocumentKey CachedHighlight)
  }

textMateService
  :: TextMateConfiguration
  -> (TextMateServiceEvent -> ExternalEvent model)
  -> (Service model, ServiceEndpoint TextMateCommand)
textMateService configuration toExternal =
  serviceWithStatus
    textMateServiceKey
    "Visual Haskell TextMate grammar and theme service"
    serviceOptions
    (toExternal . TextMateServiceStatus)
    (runTextMateService configuration toExternal)
  where
    serviceOptions =
      defaultServiceOptions
        { serviceCommandCapacity = 256
        , serviceOverflowPolicy = ReplacePendingCommand textMateCommandKey
        }

textMateCommandKey :: TextMateCommand -> Text
textMateCommandKey command =
  case command of
    ReloadTextMateResources -> "registry"
    SelectTextMateTheme _ -> "theme"
    UpsertTextMateDocument snapshot -> documentKey snapshot.highlightDocument
    CloseTextMateDocument document -> documentKey document
    PrioritizeTextMateDocument _ -> "priority"
  where
    documentKey :: DocumentKey -> Text
    documentKey document = "document:" <> Text.pack (show document.unDocumentKey)

runTextMateService
  :: TextMateConfiguration
  -> (TextMateServiceEvent -> ExternalEvent model)
  -> ServiceContext model TextMateCommand
  -> IO ()
runTextMateService configuration toExternal context = do
  textMateTrace configuration TraceInfo "service.start"
    [ ("bundledRoots", Text.pack (show configuration.bundledExtensionRoots))
    , ("userExtensionRoots", Text.pack (show configuration.userExtensionRoots))
    , ("userGrammarRoots", Text.pack (show configuration.userGrammarRoots))
    , ("userThemeRoots", Text.pack (show configuration.userThemeRoots))
    ]
  tokenizer <- newTokenizer configuration.maximumMatchesPerLine
  initial <- reloadEngine configuration Nothing emptyEngineState
  traceRegistry configuration initial
  stateReference <- newIORef initial
  emitRegistry context toExternal initial
  reportRegistryHealth context initial.engineRegistry
  loop tokenizer stateReference
  where
    loop tokenizer stateReference = do
      next <- context.receiveCommand
      case next of
        Nothing -> textMateTrace configuration TraceInfo "service.stop" []
        Just command -> do
          textMateTrace configuration TraceDebug "command.start" (textMateCommandFields command)
          outcome <- try (handleCommand configuration tokenizer context toExternal stateReference command)
          case outcome of
            Right () ->
              textMateTrace configuration TraceDebug "command.complete" (textMateCommandFields command)
            Left (exception :: SomeException) -> do
              let message = Text.pack (displayException exception)
              textMateTrace configuration TraceError "command.failed"
                (textMateCommandFields command <> [("exception", message)])
              context.reportServiceHealth (ServiceDegraded message)
              emitEveryEvent
                context
                toExternal
                (TextMateFailure (HighlightFailure Nothing Nothing message))
          loop tokenizer stateReference

textMateTrace
  :: TextMateConfiguration
  -> TraceSeverity
  -> Text
  -> [(Text, Text)]
  -> IO ()
textMateTrace configuration severity =
  trace configuration.textMateTraceSink severity "visual-haskell.textmate"

textMateCommandFields :: TextMateCommand -> [(Text, Text)]
textMateCommandFields command =
  ("kind", textMateCommandKey command) :
    case command of
      ReloadTextMateResources -> []
      SelectTextMateTheme identifier -> [("theme", identifier.unThemeId)]
      UpsertTextMateDocument snapshot ->
        [ ("document", Text.pack (show snapshot.highlightDocument.unDocumentKey))
        , ("path", Text.pack snapshot.highlightPath)
        , ("revision", Text.pack (show snapshot.highlightRevision.unTextRevision))
        , ("contentHash", Text.pack (show snapshot.highlightContentHash.unContentHash))
        , ("characters", Text.pack (show (Text.length snapshot.highlightText)))
        ]
      CloseTextMateDocument document ->
        [("document", Text.pack (show document.unDocumentKey))]
      PrioritizeTextMateDocument document ->
        [("document", Text.pack (show document.unDocumentKey))]

traceRegistry :: TextMateConfiguration -> EngineState -> IO ()
traceRegistry configuration state =
  textMateTrace configuration TraceInfo "registry.loaded"
    [ ("generation", Text.pack (show state.engineRegistryGeneration.unRegistryGeneration))
    , ("languages", Text.pack (show (length summary.registryLanguageIds)))
    , ("themes", Text.pack (show (length summary.registryThemeIds)))
    , ("diagnostics", Text.pack (show summary.registryDiagnosticCount))
    , ("selectedTheme", maybe "<fallback>" (.unThemeId) state.engineSelectedTheme)
    ]
  where
    summary = registrySummary state.engineRegistry

emptyEngineState :: EngineState
emptyEngineState =
  EngineState
    { engineRegistry = emptyProviderRegistry
    , engineRegistryGeneration = RegistryGeneration 0
    , engineGrammarGeneration = GrammarGeneration 0
    , engineThemeGeneration = ThemeGeneration 0
    , engineSelectedTheme = Nothing
    , engineTheme = fallbackTextMateTheme
    , engineGrammars = Map.empty
    , engineDocuments = Map.empty
    }

handleCommand
  :: TextMateConfiguration
  -> Tokenizer
  -> ServiceContext model TextMateCommand
  -> (TextMateServiceEvent -> ExternalEvent model)
  -> IORef EngineState
  -> TextMateCommand
  -> IO ()
handleCommand configuration tokenizer context toExternal stateReference command = do
  current <- readIORef stateReference
  case command of
    ReloadTextMateResources -> do
      reloaded <- reloadEngine configuration current.engineSelectedTheme current
      traceRegistry configuration reloaded
      writeIORef stateReference reloaded
      emitRegistry context toExternal reloaded
      reportRegistryHealth context reloaded.engineRegistry
      replayDocuments configuration tokenizer context toExternal stateReference (Map.elems current.engineDocuments)
    SelectTextMateTheme identifier ->
      selectTheme configuration context toExternal stateReference identifier current
    UpsertTextMateDocument snapshot ->
      processHighlight configuration tokenizer context toExternal stateReference snapshot current
    CloseTextMateDocument document ->
      writeIORef stateReference current {engineDocuments = Map.delete document current.engineDocuments}
    PrioritizeTextMateDocument _ -> pure ()

reloadEngine
  :: TextMateConfiguration
  -> Maybe ThemeId
  -> EngineState
  -> IO EngineState
reloadEngine configuration requestedTheme current = do
  registry <- loadProviderRegistry configuration
  let selected =
        ( requestedTheme
            >>= (\identifier -> identifier <$ themeForIdentifier registry identifier)
        )
          <|> ( configuration.selectedTheme
                  >>= (\identifier -> identifier <$ themeForIdentifier registry identifier)
              )
          <|> (fst <$> Map.lookupMin registry.registryThemes)
  loadedTheme <- loadSelectedTheme configuration registry selected
  pure
    current
      { engineRegistry = registry
      , engineRegistryGeneration = nextRegistryGeneration current.engineRegistryGeneration
      , engineGrammarGeneration = nextGrammarGeneration current.engineGrammarGeneration
      , engineThemeGeneration = nextThemeGeneration current.engineThemeGeneration
      , engineSelectedTheme = selected
      , engineTheme = either (const fallbackTextMateTheme) id loadedTheme
      , engineGrammars = Map.empty
      , engineDocuments = Map.empty
      }

loadSelectedTheme
  :: TextMateConfiguration
  -> ProviderRegistry
  -> Maybe ThemeId
  -> IO (Either ThemeError TextMateTheme)
loadSelectedTheme _ _ Nothing = pure (Right fallbackTextMateTheme)
loadSelectedTheme configuration registry (Just identifier) =
  case themeForIdentifier registry identifier of
    Nothing -> pure (Right fallbackTextMateTheme)
    Just descriptor -> loadTheme configuration.maximumThemeBytes descriptor.themePath

selectTheme
  :: TextMateConfiguration
  -> ServiceContext model TextMateCommand
  -> (TextMateServiceEvent -> ExternalEvent model)
  -> IORef EngineState
  -> ThemeId
  -> EngineState
  -> IO ()
selectTheme configuration context toExternal stateReference identifier current =
  case themeForIdentifier current.engineRegistry identifier of
    Nothing ->
      emitEveryEvent
        context
        toExternal
        ( TextMateFailure
            (HighlightFailure Nothing Nothing ("Unknown TextMate theme " <> identifier.unThemeId))
        )
    Just descriptor -> do
      loaded <- loadTheme configuration.maximumThemeBytes descriptor.themePath
      case loaded of
        Left failure ->
          emitEveryEvent
            context
            toExternal
            ( TextMateFailure
                (HighlightFailure Nothing (Just descriptor.themePath) failure.themeErrorMessage)
            )
        Right theme -> do
          let updated =
                current
                  { engineSelectedTheme = Just identifier
                  , engineTheme = theme
                  , engineThemeGeneration = nextThemeGeneration current.engineThemeGeneration
                  }
          writeIORef stateReference updated
          forM_ (Map.elems updated.engineDocuments) $ \cached ->
            emitHighlightResult context toExternal updated cached

replayDocuments
  :: TextMateConfiguration
  -> Tokenizer
  -> ServiceContext model TextMateCommand
  -> (TextMateServiceEvent -> ExternalEvent model)
  -> IORef EngineState
  -> [CachedHighlight]
  -> IO ()
replayDocuments configuration tokenizer context toExternal stateReference =
  mapM_ $ \cached -> do
    current <- readIORef stateReference
    processHighlight
      configuration
      tokenizer
      context
      toExternal
      stateReference
      cached.cachedSnapshot
      current

processHighlight
  :: TextMateConfiguration
  -> Tokenizer
  -> ServiceContext model TextMateCommand
  -> (TextMateServiceEvent -> ExternalEvent model)
  -> IORef EngineState
  -> HighlightSnapshot
  -> EngineState
  -> IO ()
processHighlight configuration tokenizer context toExternal stateReference snapshot current =
  case snapshot.highlightLanguageOverride <|> languageForPath current.engineRegistry snapshot.highlightPath of
    Nothing -> unavailable "No TextMate language provider matches this file"
    Just language ->
      case grammarForLanguage current.engineRegistry language of
        Nothing -> unavailable ("No TextMate grammar is registered for " <> language.unLanguageId)
        Just descriptor -> do
          grammarResult <- grammarForDescriptor configuration descriptor current
          case grammarResult of
            Left failure -> unavailable failure
            Right (grammar, withGrammar) -> do
              let previous = do
                    cached <- Map.lookup snapshot.highlightDocument withGrammar.engineDocuments
                    if cached.cachedGrammarPath == descriptor.grammarPath
                      then Just cached.cachedTokenized
                      else Nothing
              tokenized <- tokenizeIncremental tokenizer grammar snapshot previous
              case tokenized of
                Left failure -> unavailable failure.unTokenizerError
                Right document -> do
                  let cached =
                        CachedHighlight
                          { cachedSnapshot = snapshot
                          , cachedLanguage = language
                          , cachedGrammarPath = descriptor.grammarPath
                          , cachedTokenized = document
                          }
                      updated =
                        withGrammar
                          { engineDocuments =
                              Map.insert snapshot.highlightDocument cached withGrammar.engineDocuments
                          }
                  writeIORef stateReference updated
                  context.reportServiceHealth ServiceHealthy
                  emitHighlightResult context toExternal updated cached
  where
    unavailable message = do
      writeIORef
        stateReference
        current {engineDocuments = Map.delete snapshot.highlightDocument current.engineDocuments}
      emitLatestEvent
        context
        toExternal
        (documentEventKey snapshot.highlightDocument)
        ( TextMateHighlightUnavailable
            snapshot.highlightDocument
            snapshot.highlightRevision
            snapshot.highlightContentHash
            message
        )

grammarForDescriptor
  :: TextMateConfiguration
  -> GrammarDescriptor
  -> EngineState
  -> IO (Either Text (Grammar, EngineState))
grammarForDescriptor configuration descriptor current =
  case Map.lookup descriptor.grammarPath current.engineGrammars of
    Just grammar -> pure (Right (grammar, current))
    Nothing -> do
      loaded <-
        loadGrammar
          configuration.maximumGrammarBytes
          configuration.maximumRuleCount
          descriptor.grammarPath
      pure $ case loaded of
        Left failure -> Left failure.grammarErrorMessage
        Right grammar ->
          Right
            ( grammar
            , current
                { engineGrammars = Map.insert descriptor.grammarPath grammar current.engineGrammars
                }
            )

emitHighlightResult
  :: ServiceContext model TextMateCommand
  -> (TextMateServiceEvent -> ExternalEvent model)
  -> EngineState
  -> CachedHighlight
  -> IO ()
emitHighlightResult context toExternal state cached =
  emitLatestEvent context toExternal (documentEventKey snapshot.highlightDocument) event
  where
    snapshot = cached.cachedSnapshot
    syntaxLayer =
      themeTextLayer
        textMateSyntaxLayerKey
        snapshot.highlightRevision
        state.engineTheme
        (tokenizedSnapshot cached.cachedTokenized)
    event =
      TextMateHighlightReady
        HighlightResult
          { resultDocument = snapshot.highlightDocument
          , resultRevision = snapshot.highlightRevision
          , resultContentHash = snapshot.highlightContentHash
          , resultLanguage = cached.cachedLanguage
          , resultRegistryGeneration = state.engineRegistryGeneration
          , resultGrammarGeneration = state.engineGrammarGeneration
          , resultThemeGeneration = state.engineThemeGeneration
          , resultLayer = syntaxLayer
          , resultCompleteness = CompleteHighlight
          }

emitRegistry
  :: ServiceContext model TextMateCommand
  -> (TextMateServiceEvent -> ExternalEvent model)
  -> EngineState
  -> IO ()
emitRegistry context toExternal state =
  emitLatestEvent
    context
    toExternal
    (EventCoalescingKey "textmate.registry")
    (TextMateRegistryChanged state.engineRegistryGeneration (registrySummary state.engineRegistry))

reportRegistryHealth
  :: ServiceContext model TextMateCommand
  -> ProviderRegistry
  -> IO ()
reportRegistryHealth context registry
  | null registry.registryDiagnostics = context.reportServiceHealth ServiceHealthy
  | otherwise =
      context.reportServiceHealth
        ( ServiceDegraded
            ( Text.pack (show (length registry.registryDiagnostics))
                <> " TextMate provider diagnostics"
            )
        )

emitLatestEvent
  :: ServiceContext model TextMateCommand
  -> (TextMateServiceEvent -> ExternalEvent model)
  -> EventCoalescingKey
  -> TextMateServiceEvent
  -> IO ()
emitLatestEvent context toExternal key event =
  context.serviceEvents.emitLatest key (toExternal event)

emitEveryEvent
  :: ServiceContext model TextMateCommand
  -> (TextMateServiceEvent -> ExternalEvent model)
  -> TextMateServiceEvent
  -> IO ()
emitEveryEvent context toExternal = emitExternalEvent context.serviceEvents . toExternal

documentEventKey :: DocumentKey -> EventCoalescingKey
documentEventKey document =
  EventCoalescingKey ("textmate.document." <> Text.pack (show document.unDocumentKey))

nextRegistryGeneration :: RegistryGeneration -> RegistryGeneration
nextRegistryGeneration (RegistryGeneration generation) = RegistryGeneration (generation + 1)

nextGrammarGeneration :: GrammarGeneration -> GrammarGeneration
nextGrammarGeneration (GrammarGeneration generation) = GrammarGeneration (generation + 1)

nextThemeGeneration :: ThemeGeneration -> ThemeGeneration
nextThemeGeneration (ThemeGeneration generation) = ThemeGeneration (generation + 1)
