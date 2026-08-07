{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

module VisualHaskell
  ( application
  , applicationWithAnalysisEnvironment
  , applicationWithDocument
  , applicationWithDocuments
  , applicationWithEnvironment
  , applicationWithWorkspaceRegistry
  , firstDocumentEditorKey
  , firstDocumentTabKey
  , firstDocumentWindowKey
  , openCommand
  , openFolderCommand
  , projectTreeKey
  , saveCommand
  , workspaceWindowKey
  ) where

import Control.Concurrent (threadDelay)
import Data.Bits (setBit, xor)
import Data.List
  ( find
  , foldl'
  , sortOn
  )
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe
  ( listToMaybe
  , mapMaybe
  , maybeToList
  )
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word64)
import qualified VisualHaskell.Analysis.Acceptance as AnalysisAcceptance
import qualified VisualHaskell.Analysis.Client as AnalysisClient
import qualified VisualHaskell.Analysis.Protocol as AnalysisProtocol
import VisualHaskell.Analysis.Service
  ( AnalysisCommand (..)
  , AnalysisConfiguration
  , AnalysisServiceEvent (..)
  , analysisService
  , defaultAnalysisConfiguration
  )
import VisualHaskell.Highlighting
  ( codeEditorBaseStyle
  , haskellSyntaxLayer
  )
import qualified VisualHaskell.Diagnostics as Diagnostics
import VisualHaskell.TrustState
  ( TrustRegistry (..)
  , decodeTrustRegistry
  , emptyTrustRegistry
  , encodeTrustRegistry
  )
import VisualHaskell.WorkspaceState
  ( WorkspaceState (..)
  , decodeWorkspaceState
  , defaultInspectorPaneState
  , defaultNavigatorPaneState
  , encodeWorkspaceState
  , fromWorkspaceRelativePath
  , toWorkspaceRelativePath
  , workspaceFileName
  , workspaceFilePath
  )
import GHC.Generics (Generic)
import System.FilePath
  ( (</>)
  , normalise
  , splitDirectories
  , takeExtension
  , takeDirectory
  , takeFileName
  )
import HaskeLUI.Binding
import HaskeLUI.Core hiding (Path)
import HaskeLUI.Property
import qualified VisualHaskell.Semantic as Semantic
import VisualHaskell.TextMate

data Document = Document
  { documentKey :: !DocumentKey
  , documentTabKey :: !TabKey
  , documentEditorKey :: !ElementKey
  , documentEffectKey :: !EffectKey
  , documentPath :: !FilePath
  , documentContents :: !Text
  , documentRevision :: !TextRevision
  , documentSavedContents :: !Text
  , documentStatus :: !Text
  , documentCloseAfterSave :: !Bool
  , documentSyntaxLayer :: !(Maybe TextLayer)
  , documentLanguage :: !(Maybe LanguageId)
  , documentNavigation :: !(Maybe TextNavigationRequest)
  }
  deriving stock (Eq, Generic, Show)

data ProjectEntry = ProjectEntry
  { projectEntryKey :: !CollectionItemKey
  , projectEntryPath :: !FilePath
  , projectEntryName :: !Text
  , projectEntryKind :: !FileSystemEntryKind
  , projectEntryChildren :: ![FilePath]
  , projectEntryChildrenLoaded :: !Bool
  }
  deriving stock (Eq, Generic, Show)

data EditorModel = EditorModel
  { documents :: !(Map DocumentKey Document)
  , tabOrder :: ![TabKey]
  , selectedTab :: !(Maybe TabKey)
  , nextDocumentIdentity :: !Word64
  , workspaceOpen :: !Bool
  , workspaceMessage :: !Text
  , projectRoot :: !(Maybe FilePath)
  , projectEntries :: !(Map FilePath ProjectEntry)
  , projectPathsByKey :: !(Map CollectionItemKey FilePath)
  , projectExpandedFolders :: !(Set FilePath)
  , projectSelectedEntry :: !(Maybe FilePath)
  , nextProjectEntryIdentity :: !Word64
  , navigatorState :: !PaneState
  , inspectorState :: !PaneState
  , selectedInspectorTab :: !TabKey
  , selectedProblem :: !(Maybe CollectionItemKey)
  , nextNavigationIdentity :: !Word64
  , workspacePersistencePhase :: !WorkspacePersistencePhase
  , workspaceRestorePendingFiles :: !(Set FilePath)
  , workspaceRestoreActiveFile :: !(Maybe FilePath)
  , workspaceRestoreExplorerSelection :: !(Maybe FilePath)
  , workspaceRegistryPath :: !(Maybe FilePath)
  , workspaceTrustRegistryPath :: !(Maybe FilePath)
  , workspaceTrustRegistry :: !TrustRegistry
  , workspaceRequestedAnalysisTrust :: !Bool
  , textMateRegistryGeneration :: !(Maybe RegistryGeneration)
  , textMateStatus :: !Text
  , systemColorScheme :: !ColorScheme
  , analysisWorkspaceGeneration :: !Semantic.WorkspaceGeneration
  , analysisWorkspaceTrusted :: !Bool
  , analysisWorkerGeneration :: !(Maybe AnalysisClient.WorkerGeneration)
  , analysisComponent :: !(Maybe Semantic.ComponentInfo)
  , analysisSnapshots :: !(Map Semantic.DocumentId (Semantic.AnalysisSnapshot Semantic.RevisionedSourceRange))
  , analysisStatus :: !Text
  }
  deriving stock (Eq, Generic, Show)

data EditorProblem = EditorProblem
  { problemKey :: !CollectionItemKey
  , problemDocumentKey :: !DocumentKey
  , problemTabKey :: !TabKey
  , problemPath :: !FilePath
  , problemDiagnostic :: !Diagnostics.ProjectedDiagnostic
  }
  deriving stock (Eq, Show)

data WorkspacePersistencePhase
  = WorkspacePersistenceReady
  | WorkspacePersistenceLoading
  | WorkspacePersistenceBlocked
  deriving stock (Eq, Generic, Show)

editorProperties :: Path EditorModel EditorModel
editorProperties = rootPath

documentProperties :: Path Document Document
documentProperties = rootPath

workspaceWindowKey :: WindowKey
workspaceWindowKey = WindowKey 10

-- Kept as a compatibility name for the existing native fixture. Documents no
-- longer own windows; the first document is hosted by this workspace window.
firstDocumentWindowKey :: WindowKey
firstDocumentWindowKey = workspaceWindowKey

firstDocumentTabKey :: TabKey
firstDocumentTabKey = TabKey 1000

firstDocumentEditorKey :: ElementKey
firstDocumentEditorKey = ElementKey 1001000

openCommand, saveCommand, openFolderCommand, trustWorkspaceCommand :: CommandId
openCommand = CommandId 10
saveCommand = CommandId 11
openFolderCommand = CommandId 12
trustWorkspaceCommand = CommandId 13

projectTreeKey :: ElementKey
projectTreeKey = ElementKey 100

navigatorPaneKey, editorPaneKey, inspectorPaneKey :: PaneKey
navigatorPaneKey = PaneKey 10
editorPaneKey = PaneKey 11
inspectorPaneKey = PaneKey 12

navigatorItemKey, editorItemKey, inspectorItemKey :: WorkspaceItemKey
navigatorItemKey = WorkspaceItemKey 20
editorItemKey = WorkspaceItemKey 21
inspectorItemKey = WorkspaceItemKey 22

editorTabGroupKey :: TabGroupKey
editorTabGroupKey = TabGroupKey 30

inspectorTabGroupKey :: TabGroupKey
inspectorTabGroupKey = TabGroupKey 31

documentInspectorTabKey, problemsInspectorTabKey :: TabKey
documentInspectorTabKey = TabKey 9000001
problemsInspectorTabKey = TabKey 9000002

problemsListKey :: ElementKey
problemsListKey = ElementKey 210

application :: App EditorModel
application = editorApplication initialModel

applicationWithWorkspaceRegistry :: FilePath -> App EditorModel
applicationWithWorkspaceRegistry registryPath =
  ( editorApplication
      ( initialModel
          { workspaceRegistryPath = Just normalizedRegistryPath
          , workspaceTrustRegistryPath = Just trustRegistryPath
          }
      )
  )
    { appInitialEffects =
        [ ReadOptionalTextFile normalizedRegistryPath
        , ReadOptionalTextFile trustRegistryPath
        ]
    }
  where
    normalizedRegistryPath = normalise registryPath
    trustRegistryPath = trustRegistryPathFor normalizedRegistryPath

-- | Production Visual Haskell application with the standard direct-GHC worker
-- executable name. Embedders that resolve another worker path can use
-- 'applicationWithAnalysisEnvironment'.
applicationWithEnvironment
  :: FilePath
  -> TextMateConfiguration
  -> App EditorModel
applicationWithEnvironment registryPath configuration =
  applicationWithAnalysisEnvironment
    registryPath
    configuration
    (defaultAnalysisConfiguration "visual-haskell-analysis-ghc910")

-- | Production Visual Haskell application: workspace restoration, supervised
-- TextMate resources, and a supervised out-of-process compiler service.
applicationWithAnalysisEnvironment
  :: FilePath
  -> TextMateConfiguration
  -> AnalysisConfiguration
  -> App EditorModel
applicationWithAnalysisEnvironment registryPath textMateConfiguration analysisConfiguration =
  applicationValue
    { appInitialEffects =
        [ ReadOptionalTextFile normalizedRegistryPath
        , ReadOptionalTextFile trustRegistryPath
        ]
    , appInitialCommands = textMateCommandsForCurrentState textMateEndpoint startingModel
    , appServices = [textMateWorker, analysisWorker]
    , appSubscriptions =
        const
          [ textMateResourceSubscription
              textMateConfiguration
              (textMateExternalEvent textMateEndpoint)
          ]
    }
  where
    normalizedRegistryPath = normalise registryPath
    startingModel =
      initialModel
        { workspaceRegistryPath = Just normalizedRegistryPath
        , workspaceTrustRegistryPath = Just trustRegistryPath
        }
    trustRegistryPath = trustRegistryPathFor normalizedRegistryPath
    applicationValue =
      editorApplicationWithServices
        (Just textMateEndpoint)
        (Just analysisEndpoint)
        startingModel
    (textMateWorker, textMateEndpoint) =
      textMateService textMateConfiguration (textMateExternalEvent textMateEndpoint)
    (analysisWorker, analysisEndpoint) =
      analysisService analysisConfiguration (analysisExternalEvent analysisEndpoint)

applicationWithDocument :: FilePath -> Text -> App EditorModel
applicationWithDocument documentPath initialContents =
  applicationWithDocuments [(documentPath, initialContents)]

applicationWithDocuments :: [(FilePath, Text)] -> App EditorModel
applicationWithDocuments initialDocuments =
  editorApplication
    populatedModel
      { selectedTab = listToMaybe populatedModel.tabOrder
      }
  where
    populatedModel =
      foldl'
        (\model (documentPath, initialContents) ->
          insertDocument documentPath initialContents model
        )
        initialModel
        initialDocuments

initialModel :: EditorModel
initialModel =
  EditorModel
    { documents = Map.empty
    , tabOrder = []
    , selectedTab = Nothing
    , nextDocumentIdentity = 1000
    , workspaceOpen = True
    , workspaceMessage = "Open a folder or one or more UTF-8 text files."
    , projectRoot = Nothing
    , projectEntries = Map.empty
    , projectPathsByKey = Map.empty
    , projectExpandedFolders = Set.empty
    , projectSelectedEntry = Nothing
    , nextProjectEntryIdentity = 1
    , navigatorState = defaultNavigatorPaneState
    , inspectorState = defaultInspectorPaneState
    , selectedInspectorTab = documentInspectorTabKey
    , selectedProblem = Nothing
    , nextNavigationIdentity = 1
    , workspacePersistencePhase = WorkspacePersistenceReady
    , workspaceRestorePendingFiles = Set.empty
    , workspaceRestoreActiveFile = Nothing
    , workspaceRestoreExplorerSelection = Nothing
    , workspaceRegistryPath = Nothing
    , workspaceTrustRegistryPath = Nothing
    , workspaceTrustRegistry = emptyTrustRegistry
    , workspaceRequestedAnalysisTrust = False
    , textMateRegistryGeneration = Nothing
    , textMateStatus = "Syntax: built-in fallback"
    , systemColorScheme = LightColorScheme
    , analysisWorkspaceGeneration = Semantic.WorkspaceGeneration 0
    , analysisWorkspaceTrusted = False
    , analysisWorkerGeneration = Nothing
    , analysisComponent = Nothing
    , analysisSnapshots = Map.empty
    , analysisStatus = "GHC: starting"
    }

editorApplication :: EditorModel -> App EditorModel
editorApplication = editorApplicationWithServices Nothing Nothing

editorApplicationWithServices
  :: Maybe (ServiceEndpoint TextMateCommand)
  -> Maybe (ServiceEndpoint AnalysisCommand)
  -> EditorModel
  -> App EditorModel
editorApplicationWithServices textMateEndpoint analysisEndpoint startingModel =
  App
    { appInitialModel = startingModel
    , appInitialEffects = []
    , appInitialCommands = []
    , appServices = []
    , appSubscriptions = const []
    , appView = render
    , appHandleEvent = handleEventWithServices textMateEndpoint analysisEndpoint
    }

render :: EditorModel -> AppView
render model =
  AppView
    { appWindows = [workspaceWindow model | model.workspaceOpen]
    , appCommands =
        [ CommandSpec openCommand "Open File…" (Just "o") True
        , CommandSpec openFolderCommand "Open Folder…" Nothing True
        , CommandSpec saveCommand "Save" (Just "s") (maybe False documentDirty activeDocument)
        , CommandSpec
            trustWorkspaceCommand
            "Trust Workspace for Haskell Analysis"
            Nothing
            (model.projectRoot /= Nothing && not model.analysisWorkspaceTrusted)
        ]
    }
  where
    activeDocument = selectedDocument model

workspaceWindow :: EditorModel -> WindowSpec
workspaceWindow model =
  WorkspaceWindowSpec
    { windowKey = workspaceWindowKey
    , windowTitle = workspaceTitle model
    , windowFrame = Rect 90 100 1180 760
    , windowWorkspaceSpec =
        WorkspaceSpec
          { workspaceRoot =
              WorkspaceSplit
                (SplitKey 1)
                SideBySide
                (WorkspacePane (navigatorPane model))
                (WorkspacePane (editorPane model))
                [WorkspacePane (inspectorPane model)]
          , workspaceStatusControls = statusControls model
          }
    }

workspaceTitle :: EditorModel -> Text
workspaceTitle model =
  case selectedDocument model of
    Nothing -> "Visual Haskell"
    Just document ->
      Text.pack (takeFileName document.documentPath)
        <> if documentDirty document then " — Edited" else " — Visual Haskell"

navigatorPane :: EditorModel -> WorkspacePaneSpec
navigatorPane model =
  WorkspacePaneSpec
    { workspacePaneKey = navigatorPaneKey
    , workspacePaneRole = SidebarPane
    , workspacePaneSizing = PaneSizing (Just 160) (Just 230) (Just 420) 0
    , workspacePaneState = model.navigatorState
    , workspacePaneItem =
        WorkspaceItemSpec
          { workspaceItemKey = navigatorItemKey
          , workspaceItemContent = WorkspaceItemControls (navigatorControls model)
          }
    }

editorPane :: EditorModel -> WorkspacePaneSpec
editorPane model =
  WorkspacePaneSpec
    { workspacePaneKey = editorPaneKey
    , workspacePaneRole = ContentPane
    , workspacePaneSizing = PaneSizing (Just 320) Nothing Nothing 1
    , workspacePaneState = PaneState PaneVisible Nothing
    , workspacePaneItem =
        WorkspaceItemSpec
          { workspaceItemKey = editorItemKey
          , workspaceItemContent =
              WorkspaceItemTabGroup
                WorkspaceTabGroupSpec
                  { workspaceTabGroupKey = editorTabGroupKey
                  , workspaceSelectedTab = model.selectedTab
                  , workspaceTabs = mapMaybe (documentTab model) model.tabOrder
                  }
          }
    }

inspectorPane :: EditorModel -> WorkspacePaneSpec
inspectorPane model =
  WorkspacePaneSpec
    { workspacePaneKey = inspectorPaneKey
    , workspacePaneRole = InspectorPane
    , workspacePaneSizing = PaneSizing (Just 180) (Just 270) (Just 480) 0
    , workspacePaneState = model.inspectorState
    , workspacePaneItem =
        WorkspaceItemSpec
          { workspaceItemKey = inspectorItemKey
          , workspaceItemContent =
              WorkspaceItemTabGroup
                WorkspaceTabGroupSpec
                  { workspaceTabGroupKey = inspectorTabGroupKey
                  , workspaceSelectedTab = Just model.selectedInspectorTab
                  , workspaceTabs = inspectorTabs model
                  }
          }
    }

inspectorTabs :: EditorModel -> [WorkspaceTabSpec]
inspectorTabs model =
  [ WorkspaceTabSpec
      { workspaceTabKey = documentInspectorTabKey
      , workspaceTabDocument = Nothing
      , workspaceTabTitle = "Document"
      , workspaceTabModified = False
      , workspaceTabCloseable = False
      , workspaceTabControls = inspectorControls model
      }
  , WorkspaceTabSpec
      { workspaceTabKey = problemsInspectorTabKey
      , workspaceTabDocument = Nothing
      , workspaceTabTitle =
          "Problems (" <> Text.pack (show (length problems)) <> ")"
      , workspaceTabModified = False
      , workspaceTabCloseable = False
      , workspaceTabControls = problemsControls model problems
      }
  ]
  where
    problems = currentProblems model

documentTab :: EditorModel -> TabKey -> Maybe WorkspaceTabSpec
documentTab model tabKey = do
  document <- findDocumentByTab tabKey model
  let contentsBinding = documentContentsBinding document
  pure
    WorkspaceTabSpec
      { workspaceTabKey = tabKey
      , workspaceTabDocument = Just document.documentKey
      , workspaceTabTitle = Text.pack (takeFileName document.documentPath)
      , workspaceTabModified = documentDirty document
      , workspaceTabCloseable = True
      , workspaceTabControls =
          [ TextEditor
              TextEditorSpec
                { textEditorKey = document.documentEditorKey
                , textEditorFrame = Rect 0 0 640 640
                , textEditorText = readBinding contentsBinding model
                , textEditorRevision = document.documentRevision
                , textEditorBaseStyle = codeEditorBaseStyle
                , textEditorLayers = documentPresentation model document
                , textEditorNavigation = document.documentNavigation
                , textEditorFocused = model.selectedTab == Just tabKey
                }
          ]
      }

navigatorControls :: EditorModel -> [Control]
navigatorControls model =
  case model.projectRoot of
    Nothing ->
      [ Label projectTreeKey (Rect 16 684 200 44) "No folder open\nFile > Open Folder…"
      ]
    Just _ ->
      [ TreeView
          CollectionControlSpec
            { collectionControlKey = projectTreeKey
            , collectionControlFrame = Rect 0 0 230 718
            , collectionControlItems = projectCollectionItems model
            , collectionControlSelectionMode = SingleCollectionSelection
            , collectionControlSelection = projectSelection model
            , collectionControlRowSizing = PlatformDefaultRows
            , collectionControlEnabled = True
            }
      ]

projectCollectionItems :: EditorModel -> [CollectionItem]
projectCollectionItems model =
  case model.projectRoot >>= (`Map.lookup` model.projectEntries) of
    Nothing -> []
    Just root -> flatten 0 root
  where
    flatten depth entry =
      collectionItem
        : concatMap (maybe [] (flatten (depth + 1)) . (`Map.lookup` model.projectEntries))
            entry.projectEntryChildren
      where
        expanded = Set.member entry.projectEntryPath model.projectExpandedFolders
        collectionItem =
          CollectionItem
            { collectionItemKey = entry.projectEntryKey
            , collectionItemLabel = entry.projectEntryName
            , collectionItemDetail = ""
            , collectionItemIcon = Just (projectEntryIcon entry expanded)
            , collectionItemDepth = depth
            , collectionItemExpandable = projectEntryExpandable entry
            , collectionItemExpanded = expanded
            }

projectEntryIcon :: ProjectEntry -> Bool -> ImageSource
projectEntryIcon entry expanded =
  case entry.projectEntryKind of
    FileSystemDirectory -> SystemSymbol (if expanded then "folder.fill" else "folder")
    FileSystemFile -> SystemSymbol "doc.text"

projectEntryExpandable :: ProjectEntry -> Bool
projectEntryExpandable entry =
  entry.projectEntryKind == FileSystemDirectory
    && (not entry.projectEntryChildrenLoaded || not (null entry.projectEntryChildren))

projectSelection :: EditorModel -> [CollectionItemKey]
projectSelection model =
  case model.projectSelectedEntry >>= (`Map.lookup` model.projectEntries) of
    Nothing -> []
    Just entry -> [entry.projectEntryKey]

displayPathName :: FilePath -> Text
displayPathName path =
  let name = takeFileName path
   in Text.pack (if null name then path else name)

inspectorControls :: EditorModel -> [Control]
inspectorControls model =
  case selectedDocument model of
    Nothing ->
      [ Label (ElementKey 200) (Rect 16 690 230 22) "INSPECTOR"
      , Label (ElementKey 201) (Rect 16 650 230 44) "Select or open a document"
      ]
    Just document ->
      [ Label (ElementKey 200) (Rect 16 690 230 22) "DOCUMENT"
      , Label (ElementKey 201) (Rect 16 650 230 22) (Text.pack (takeFileName document.documentPath))
      , Label (ElementKey 202) (Rect 16 612 230 44) (Text.pack document.documentPath)
      , Label (ElementKey 203) (Rect 16 570 230 22) (languageDescription document)
      , Label
          (ElementKey 204)
          (Rect 16 536 230 22)
          (Text.pack (show (Text.length document.documentContents)) <> " characters")
      , Label
          (ElementKey 205)
          (Rect 16 502 230 22)
          (if documentDirty document then "Modified" else "Saved")
      ]

problemsControls :: EditorModel -> [EditorProblem] -> [Control]
problemsControls model problems =
  [ ListView
      CollectionControlSpec
        { collectionControlKey = problemsListKey
        , collectionControlFrame = Rect 0 0 270 718
        , collectionControlItems = fmap problemCollectionItem problems
        , collectionControlSelectionMode = SingleCollectionSelection
        , collectionControlSelection =
            [ selected
            | selected <- maybeToList model.selectedProblem
            , any ((== selected) . (.problemKey)) problems
            ]
        , collectionControlRowSizing = ContentSizedRows
        , collectionControlEnabled = True
        }
  ]

problemCollectionItem :: EditorProblem -> CollectionItem
problemCollectionItem problem =
  CollectionItem
    { collectionItemKey = problem.problemKey
    , collectionItemLabel = firstMessageLine problem.problemDiagnostic.projectedMessage
    , collectionItemDetail =
        Text.pack (takeFileName problem.problemPath)
          <> ":"
          <> Text.pack (show (problem.problemDiagnostic.projectedLine + 1))
          <> ":"
          <> Text.pack (show (problem.problemDiagnostic.projectedColumn + 1))
          <> " · "
          <> problem.problemDiagnostic.projectedSource
          <> maybe "" (" " <>) problem.problemDiagnostic.projectedCode
    , collectionItemIcon = Just (SystemSymbol (diagnosticSymbol problem.problemDiagnostic.projectedSeverity))
    , collectionItemDepth = 0
    , collectionItemExpandable = False
    , collectionItemExpanded = False
    }

firstMessageLine :: Text -> Text
firstMessageLine message =
  case Text.lines (Text.strip message) of
    line : _ -> line
    [] -> "Compiler diagnostic"

diagnosticSymbol :: Semantic.DiagnosticSeverity -> Text
diagnosticSymbol severity =
  case severity of
    Semantic.DiagnosticError -> "xmark.octagon.fill"
    Semantic.DiagnosticWarning -> "exclamationmark.triangle.fill"
    Semantic.DiagnosticInformation -> "info.circle.fill"
    Semantic.DiagnosticHint -> "lightbulb.fill"

statusControls :: EditorModel -> [Control]
statusControls model =
  [ Label (ElementKey 300) (Rect 12 4 530 20) status
  , Label (ElementKey 301) (Rect 550 4 600 20) summary
  ]
  where
    status = maybe model.workspaceMessage (.documentStatus) (selectedDocument model)
    summary =
      Text.pack (show (Map.size model.documents))
        <> (if Map.size model.documents == 1 then " document" else " documents")
        <> " · "
        <> model.textMateStatus
        <> " · "
        <> model.analysisStatus

languageDescription :: Document -> Text
languageDescription document
  | Just language <- document.documentLanguage = language.unLanguageId <> " · TextMate"
  | isHaskellPath document.documentPath = "Haskell source"
  | otherwise = "Plain text"

documentDirty :: Document -> Bool
documentDirty document = document.documentContents /= document.documentSavedContents

-- A document lives behind a dynamic Map key, so it is not a total lens from
-- EditorModel. The controlled binding is the honest escape hatch: the event
-- lookup establishes the current owner, while lifted child actions retain
-- qualified property metadata and safely no-op if that key has disappeared.
documentContentsBinding :: Document -> Binding EditorModel Text
documentContentsBinding document =
  controlledWith
    document.documentContents
    ( \newContents ->
        liftDocumentAction
          document.documentKey
          (documentProperties.documentContents .= newContents)
    )
    [ alsoWrite
        ( const
            ( liftDocumentAction
                document.documentKey
                (modify documentProperties.documentRevision nextTextRevision)
            )
        )
    , alsoWrite
        ( const
            ( liftDocumentAction
                document.documentKey
                (documentProperties.documentStatus .= "Unsaved changes")
            )
        )
    , alsoWrite
        ( const
            ( liftDocumentAction
                document.documentKey
                (documentProperties.documentCloseAfterSave .= False)
            )
        )
    , commitPolicy Live
    , undoPolicy
        ( Coalesce
            (UndoGroup ("edit-document-" <> Text.pack (show document.documentKey.unDocumentKey)))
        )
    , labelTransaction "Edit text"
    ]

liftDocumentAction :: DocumentKey -> Action Document -> Action EditorModel
liftDocumentAction key childAction =
  actionWithProperties
    ( "Document "
        <> Text.pack (show key.unDocumentKey)
        <> ": "
        <> actionDescription childAction
    )
    (fmap (scopeDocumentProperty key) (actionPropertyIds childAction))
    (updateDocument key (applyAction childAction))

scopeDocumentProperty :: DocumentKey -> PropertyId -> PropertyId
scopeDocumentProperty key (PropertyId childIdentifier) =
  PropertyId
    ( "documents."
        <> Text.pack (show key.unDocumentKey)
        <> if Text.null childIdentifier then "" else "." <> childIdentifier
    )

insertDocumentPropertyIds :: [PropertyId]
insertDocumentPropertyIds =
  [ propertyId editorProperties.documents
  , propertyId editorProperties.tabOrder
  , propertyId editorProperties.selectedTab
  , propertyId editorProperties.nextDocumentIdentity
  , propertyId editorProperties.workspaceOpen
  , propertyId editorProperties.workspaceMessage
  , propertyId editorProperties.projectSelectedEntry
  ]

insertDocumentAction :: FilePath -> Text -> Action EditorModel
insertDocumentAction documentPath initialContents =
  actionWithProperties
    "Insert document"
    insertDocumentPropertyIds
    (insertDocument documentPath initialContents)

removeDocumentAction :: DocumentKey -> Action EditorModel
removeDocumentAction key =
  actionWithProperties
    "Remove document"
    [ propertyId editorProperties.documents
    , propertyId editorProperties.tabOrder
    , propertyId editorProperties.selectedTab
    , propertyId editorProperties.workspaceMessage
    ]
    (removeDocument key)

handleEvent :: UIEvent -> EditorModel -> Transaction EditorModel
handleEvent event model =
  persistWorkspaceChanges model (handleEventWithoutPersistence event model)

handleEventWithServices
  :: Maybe (ServiceEndpoint TextMateCommand)
  -> Maybe (ServiceEndpoint AnalysisCommand)
  -> UIEvent
  -> EditorModel
  -> Transaction EditorModel
handleEventWithServices textMateEndpoint analysisEndpoint event model =
  appendRuntimeCommands runtimeCommands update
  where
    initialUpdate = handleEvent event model
    initiallyUpdated = applyTransaction initialUpdate model
    update = prepareAnalysisWorkspaceTransition model initiallyUpdated initialUpdate
    updatedModel = applyTransaction update model
    runtimeCommands =
      maybe
        []
        (\endpoint -> textMateCommandsForTransition endpoint event model updatedModel)
        textMateEndpoint
        <> maybe
          []
          (\endpoint -> analysisCommandsForTransition endpoint model updatedModel)
          analysisEndpoint

prepareAnalysisWorkspaceTransition
  :: EditorModel
  -> EditorModel
  -> Transaction EditorModel
  -> Transaction EditorModel
prepareAnalysisWorkspaceTransition oldModel newModel update
  | oldModel.projectRoot == newModel.projectRoot
  , oldModel.analysisWorkspaceTrusted == newModel.analysisWorkspaceTrusted = update
  | otherwise =
      update
        { transactionAction =
            batchActions
              "Change analysis workspace generation"
              [ update.transactionAction
              , actionWithProperties
                  "Reset compiler analysis for the new workspace"
                  [ propertyId editorProperties.analysisWorkspaceGeneration
                  , propertyId editorProperties.analysisComponent
                  , propertyId editorProperties.analysisSnapshots
                  , propertyId editorProperties.analysisStatus
                  ]
                  resetAnalysisWorkspace
              ]
        }
  where
    resetAnalysisWorkspace current =
      current
        { analysisWorkspaceGeneration = nextWorkspaceGeneration current.analysisWorkspaceGeneration
        , analysisComponent = Nothing
        , analysisSnapshots = Map.empty
        , analysisStatus =
            if current.analysisWorkspaceTrusted
              then "GHC: loading workspace"
              else "GHC: workspace untrusted"
        }

textMateCommandsForDocuments
  :: ServiceEndpoint TextMateCommand
  -> Map DocumentKey Document
  -> EditorModel
  -> [RuntimeCommand EditorModel]
textMateCommandsForDocuments endpoint oldDocuments newModel =
  fmap (sendService endpoint . CloseTextMateDocument) closedDocuments
    <> fmap (sendService endpoint . UpsertTextMateDocument . documentSnapshot) changedDocuments
    <> maybe [] (pure . sendService endpoint . PrioritizeTextMateDocument . (.documentKey))
      (selectedDocument newModel)
  where
    closedDocuments = Map.keys (oldDocuments `Map.difference` newModel.documents)
    changedDocuments =
      [ document
      | document <- Map.elems newModel.documents
      , case Map.lookup document.documentKey oldDocuments of
          Nothing -> True
          Just previous ->
            previous.documentRevision /= document.documentRevision
              || previous.documentPath /= document.documentPath
              || previous.documentContents /= document.documentContents
      ]

textMateCommandsForCurrentState
  :: ServiceEndpoint TextMateCommand
  -> EditorModel
  -> [RuntimeCommand EditorModel]
textMateCommandsForCurrentState endpoint model =
  sendService endpoint (SelectTextMateTheme (textMateThemeFor model.systemColorScheme))
    : textMateCommandsForDocuments endpoint Map.empty model

textMateCommandsForTransition
  :: ServiceEndpoint TextMateCommand
  -> UIEvent
  -> EditorModel
  -> EditorModel
  -> [RuntimeCommand EditorModel]
textMateCommandsForTransition endpoint event oldModel newModel =
  appearanceCommands <> textMateCommandsForDocuments endpoint oldModel.documents newModel
  where
    appearanceCommands =
      case event of
        SystemColorSchemeChanged scheme
          | scheme /= oldModel.systemColorScheme ->
              [sendService endpoint (SelectTextMateTheme (textMateThemeFor scheme))]
        _ -> []

textMateThemeFor :: ColorScheme -> ThemeId
textMateThemeFor scheme =
  ThemeId $
    case scheme of
      LightColorScheme -> "visual-haskell-light"
      DarkColorScheme -> "visual-haskell-dark"

documentSnapshot :: Document -> HighlightSnapshot
documentSnapshot document =
  highlightSnapshot
    document.documentKey
    document.documentRevision
    document.documentPath
    document.documentContents

analysisCommandsForTransition
  :: ServiceEndpoint AnalysisCommand
  -> EditorModel
  -> EditorModel
  -> [RuntimeCommand EditorModel]
analysisCommandsForTransition endpoint oldModel newModel
  | oldModel.projectRoot /= newModel.projectRoot
      || oldModel.analysisWorkspaceTrusted /= newModel.analysisWorkspaceTrusted =
      cancelTask analysisEditDebounceTaskKey
        : analysisCommandsForCurrentState endpoint newModel
  | not newModel.analysisWorkspaceTrusted = []
  | newModel.projectRoot == Nothing = []
  | otherwise =
      fmap (sendService endpoint . closeCommand) closedDocuments
        <> fmap (sendService endpoint . upsertCommand) changedDocuments
        <> analysisSchedulingCommands
  where
    oldAnalysisDocuments = Map.filter isHaskellDocument oldModel.documents
    newAnalysisDocuments = Map.filter isHaskellDocument newModel.documents
    closedDocuments = Map.elems (oldAnalysisDocuments `Map.difference` newAnalysisDocuments)
    changedDocuments =
      [ document
      | document <- Map.elems newAnalysisDocuments
      , case Map.lookup document.documentKey oldAnalysisDocuments of
          Nothing -> True
          Just previous -> analysisDocumentChanged previous document
      ]
    selectedChanged =
      case selectedDocument newModel of
        Nothing -> False
        Just selected ->
          any ((== selected.documentKey) . (.documentKey)) changedDocuments
    selectionChanged = oldModel.selectedTab /= newModel.selectedTab
    analysisSchedulingCommands
      | not selectedChanged && not selectionChanged = []
      | Just selected <- selectedDocument newModel
      , isHaskellDocument selected
      , selectedChanged || not (documentAnalysisIsCurrent newModel selected) =
          [scheduleDocumentAnalysis endpoint selected.documentKey]
      | otherwise = [cancelTask analysisEditDebounceTaskKey]
    closeCommand document =
      CloseAnalysisDocument
        newModel.analysisWorkspaceGeneration
        (analysisWorkspaceId newModel)
        (analysisSession newModel)
        (analysisDocumentId document)
    upsertCommand document =
      UpsertAnalysisDocument
        newModel.analysisWorkspaceGeneration
        (analysisWorkspaceId newModel)
        (analysisSession newModel)
        (analysisDocumentSnapshot document)

-- One task key intentionally serializes interactive checking. Replacing the
-- sleeping task makes rapid edits cheap; replacing an already-running GHC
-- invocation is a separate worker concern, so at most the current stale pass
-- plus the newest requested pass remain.
analysisEditDebounceTaskKey :: TaskKey
analysisEditDebounceTaskKey = TaskKey "visual-haskell.analysis.edit-debounce"

analysisEditDebounceMicroseconds :: Int
analysisEditDebounceMicroseconds = 350000

scheduleDocumentAnalysis
  :: ServiceEndpoint AnalysisCommand
  -> DocumentKey
  -> RuntimeCommand EditorModel
scheduleDocumentAnalysis endpoint targetDocument =
  startTask
    analysisEditDebounceTaskKey
    ApplicationScope
    ReplaceRunning
    "Debounce Visual Haskell compiler analysis"
    (const (threadDelay analysisEditDebounceMicroseconds))
    (\outcome ->
      externalEvent "Request current compiler analysis" $ \model ->
        case outcome of
          TaskSucceeded () ->
            transactionWithCommands
              "Request current compiler analysis"
              NoUndo
              (analysisCommandsForDocument endpoint targetDocument model)
              id
          TaskCancelled -> noTransaction
          TaskFailed _ -> noTransaction
    )

analysisCommandsForDocument
  :: ServiceEndpoint AnalysisCommand
  -> DocumentKey
  -> EditorModel
  -> [RuntimeCommand EditorModel]
analysisCommandsForDocument endpoint targetDocument model =
  case (model.analysisWorkspaceTrusted, model.projectRoot, Map.lookup targetDocument model.documents) of
    (True, Just _, Just document)
      | isHaskellDocument document ->
          [ sendService endpoint (upsertCommand document)
          , sendService endpoint (analyzeCommand document)
          ]
    _ -> []
  where
    workspace = analysisWorkspaceId model
    session = analysisSession model
    upsertCommand document =
      UpsertAnalysisDocument
        model.analysisWorkspaceGeneration
        workspace
        session
        (analysisDocumentSnapshot document)
    analyzeCommand document =
      RequestDocumentAnalysis
        model.analysisWorkspaceGeneration
        workspace
        session
        (analysisDocumentSnapshot document)

documentAnalysisIsCurrent :: EditorModel -> Document -> Bool
documentAnalysisIsCurrent model document =
  case Map.lookup (analysisDocumentId document) model.analysisSnapshots of
    Nothing -> False
    Just snapshot ->
      snapshot.analysisWorkspaceGeneration == model.analysisWorkspaceGeneration
        && snapshot.analysisRevision == semanticRevision document.documentRevision
        && snapshot.analysisContentHash == Semantic.contentHash document.documentContents

analysisCommandsForCurrentState
  :: ServiceEndpoint AnalysisCommand
  -> EditorModel
  -> [RuntimeCommand EditorModel]
analysisCommandsForCurrentState endpoint model =
  case (model.analysisWorkspaceTrusted, model.projectRoot) of
    (False, _) -> []
    (_, Nothing) -> []
    (True, Just root) ->
      sendService endpoint
        ( ConfigureAnalysisWorkspace
            model.analysisWorkspaceGeneration
            AnalysisProtocol.WorkspaceRequest
              { AnalysisProtocol.workspaceRequestId = workspace
              , AnalysisProtocol.workspaceRequestRoot = root
              , AnalysisProtocol.workspaceRequestTrust = AnalysisProtocol.TrustedWorkspace
              }
        )
        : fmap (sendService endpoint . upsertCommand) documentsToAnalyze
          <> maybe [] (pure . sendService endpoint . analyzeCommand) selectedToAnalyze
      where
        workspace = analysisWorkspaceId model
        session = analysisSession model
        documentsToAnalyze = filter isHaskellDocument (Map.elems model.documents)
        selectedToAnalyze = do
          document <- selectedDocument model
          if isHaskellDocument document then Just document else Nothing
        upsertCommand document =
          UpsertAnalysisDocument
            model.analysisWorkspaceGeneration
            workspace
            session
            (analysisDocumentSnapshot document)
        analyzeCommand document =
          RequestDocumentAnalysis
            model.analysisWorkspaceGeneration
            workspace
            session
            (analysisDocumentSnapshot document)

analysisDocumentChanged :: Document -> Document -> Bool
analysisDocumentChanged previous current =
  previous.documentPath /= current.documentPath
    || previous.documentRevision /= current.documentRevision
    || previous.documentContents /= current.documentContents

analysisDocumentSnapshot :: Document -> Semantic.DocumentSnapshot
analysisDocumentSnapshot document =
  Semantic.DocumentSnapshot
    { Semantic.snapshotDocumentId = analysisDocumentId document
    , Semantic.snapshotPath = document.documentPath
    , Semantic.snapshotRevision = semanticRevision document.documentRevision
    , Semantic.snapshotContentHash = Semantic.contentHash document.documentContents
    , Semantic.snapshotText = document.documentContents
    , Semantic.snapshotLineEnding = lineEndingPolicy document.documentContents
    }

analysisDocumentId :: Document -> Semantic.DocumentId
analysisDocumentId = Semantic.DocumentId . Text.pack . normalise . (.documentPath)

analysisWorkspaceId :: EditorModel -> Semantic.WorkspaceId
analysisWorkspaceId model =
  Semantic.WorkspaceId (maybe "visual-haskell:no-workspace" (Text.pack . normalise) model.projectRoot)

analysisSession :: EditorModel -> Maybe Semantic.SessionId
analysisSession model = (.componentSession) <$> model.analysisComponent

semanticRevision :: TextRevision -> Semantic.TextRevision
semanticRevision revision = Semantic.TextRevision revision.unTextRevision

lineEndingPolicy :: Text -> Semantic.LineEndingPolicy
lineEndingPolicy source
  | "\r\n" `Text.isInfixOf` source
  , hasBareLineFeed source = Semantic.MixedLineEndings
  | "\r\n" `Text.isInfixOf` source = Semantic.CRLF
  | "\n" `Text.isInfixOf` source = Semantic.LF
  | otherwise = Semantic.UnknownLineEndings
  where
    hasBareLineFeed = Text.isInfixOf "\n" . Text.replace "\r\n" ""

isHaskellDocument :: Document -> Bool
isHaskellDocument = isHaskellPath . (.documentPath)

isHaskellPath :: FilePath -> Bool
isHaskellPath path = takeExtension path `elem` [".hs", ".lhs", ".hs-boot"]

nextWorkspaceGeneration :: Semantic.WorkspaceGeneration -> Semantic.WorkspaceGeneration
nextWorkspaceGeneration generation =
  Semantic.WorkspaceGeneration (generation.unWorkspaceGeneration + 1)

textMateExternalEvent
  :: ServiceEndpoint TextMateCommand
  -> TextMateServiceEvent
  -> ExternalEvent EditorModel
textMateExternalEvent endpoint serviceEvent =
  externalEvent "Visual Haskell TextMate event" (applyTextMateServiceEvent endpoint serviceEvent)

applyTextMateServiceEvent
  :: ServiceEndpoint TextMateCommand
  -> TextMateServiceEvent
  -> EditorModel
  -> Transaction EditorModel
applyTextMateServiceEvent endpoint serviceEvent model =
  case serviceEvent of
    TextMateResourcesChanged ->
      requestRuntimeCommand
        "Reload copied TextMate resources"
        (sendService endpoint ReloadTextMateResources)
    TextMateServiceStatus status ->
      let statusUpdate =
            transactionFromAction
              "Update TextMate service status"
              NoUndo
              (editorProperties.textMateStatus .= serviceStatusText status)
       in case status of
            ServiceRunning ->
              appendRuntimeCommands
                (textMateCommandsForCurrentState endpoint model)
                statusUpdate
            _ -> statusUpdate
    TextMateRegistryChanged generation summary ->
      transactionFromAction
        "Update TextMate provider registry"
        NoUndo
        ( batchActions
            "Update TextMate provider registry"
            [ editorProperties.textMateRegistryGeneration .= Just generation
            , editorProperties.textMateStatus
                .= registryStatusText summary
            ]
        )
    TextMateHighlightReady result -> applyHighlightResult result model
    TextMateHighlightUnavailable documentKey revision sourceHash message ->
      applyHighlightUnavailable documentKey revision sourceHash message model
    TextMateFailure failure ->
      transactionFromAction
        "Report TextMate failure"
        NoUndo
        (editorProperties.textMateStatus .= "Syntax unavailable: " <> failure.highlightFailureMessage)

analysisExternalEvent
  :: ServiceEndpoint AnalysisCommand
  -> AnalysisServiceEvent
  -> ExternalEvent EditorModel
analysisExternalEvent endpoint serviceEvent =
  externalEvent
    "Visual Haskell compiler analysis event"
    (applyAnalysisServiceEvent endpoint serviceEvent)

applyAnalysisServiceEvent
  :: ServiceEndpoint AnalysisCommand
  -> AnalysisServiceEvent
  -> EditorModel
  -> Transaction EditorModel
applyAnalysisServiceEvent endpoint serviceEvent model =
  case serviceEvent of
    AnalysisServiceChanged status ->
      let statusUpdate =
            analysisStatusTransaction
              (visibleAnalysisLifecycleStatus model (analysisServiceStatusText status))
       in case status of
            ServiceRunning ->
              appendRuntimeCommands
                (analysisCommandsForCurrentState endpoint model)
                statusUpdate
            _ -> statusUpdate
    AnalysisClientChanged clientEvent -> applyAnalysisClientEvent clientEvent model

applyAnalysisClientEvent
  :: AnalysisClient.AnalysisClientEvent
  -> EditorModel
  -> Transaction EditorModel
applyAnalysisClientEvent clientEvent model =
  case clientEvent of
    AnalysisClient.AnalysisWorkerStarting generation ->
      analysisGenerationTransaction
        generation
        (visibleAnalysisLifecycleStatus model "GHC: starting analysis worker")
    AnalysisClient.AnalysisWorkerReady generation hello ->
      transactionFromAction
        "Accept compiler worker handshake"
        NoUndo
        ( batchActions
            "Accept compiler worker handshake"
            [ editorProperties.analysisWorkerGeneration .= Just generation
            , editorProperties.analysisStatus
                .= visibleAnalysisLifecycleStatus
                  model
                  ( "GHC: worker ready"
                      <> maybe
                        ""
                        (\version -> " (" <> version.unCompilerVersion <> ")")
                        (AnalysisProtocol.workerCompilerVersion hello)
                  )
            ]
        )
    AnalysisClient.AnalysisWorkerMessage generation envelope ->
      applyAnalysisWorkerMessage generation envelope model
    AnalysisClient.AnalysisWorkerLog _ _ -> noTransaction
    AnalysisClient.AnalysisWorkerProtocolFailure generation message
      | model.analysisWorkerGeneration == Just generation ->
          analysisStatusTransaction
            (visibleAnalysisLifecycleStatus model ("GHC protocol failure: " <> message))
      | otherwise -> noTransaction
    AnalysisClient.AnalysisWorkerExited generation _
      | model.analysisWorkerGeneration == Just generation ->
          analysisStatusTransaction
            (visibleAnalysisLifecycleStatus model "GHC: analysis worker exited")
      | otherwise -> noTransaction
    AnalysisClient.AnalysisWorkerRestarting generation attempt ->
      analysisGenerationTransaction
        generation
        ( visibleAnalysisLifecycleStatus
            model
            ("GHC: restarting analysis (attempt " <> Text.pack (show attempt) <> ")")
        )
    AnalysisClient.AnalysisWorkerStopped ->
      analysisStatusTransaction
        (visibleAnalysisLifecycleStatus model "GHC: analysis unavailable")

applyAnalysisWorkerMessage
  :: AnalysisClient.WorkerGeneration
  -> AnalysisProtocol.ProtocolEnvelope AnalysisProtocol.WorkerMessage
  -> EditorModel
  -> Transaction EditorModel
applyAnalysisWorkerMessage generation envelope model
  | model.analysisWorkerGeneration /= Just generation = noTransaction
  | AnalysisProtocol.envelopeWorkspaceGeneration envelope /= model.analysisWorkspaceGeneration = noTransaction
  | otherwise =
      case AnalysisProtocol.envelopePayload envelope of
        AnalysisProtocol.WorkerHelloMessage _ -> noTransaction
        AnalysisProtocol.WorkspaceLoading _ -> analysisStatusTransaction "GHC: loading workspace"
        AnalysisProtocol.WorkspaceReady _ _ -> analysisStatusTransaction "GHC: workspace ready"
        AnalysisProtocol.WorkspaceFailed _ failure -> analysisFailureTransaction failure
        AnalysisProtocol.ComponentDiscovered component ->
          analysisStatusTransaction
            ("GHC: discovered " <> component.componentId.unComponentId)
        AnalysisProtocol.ComponentSelected component ->
          transactionFromAction
            "Select compiler component"
            NoUndo
            ( batchActions
                "Select compiler component"
                [ editorProperties.analysisComponent .= Just component
                , editorProperties.analysisStatus
                    .= "GHC: " <> component.componentId.unComponentId
                ]
            )
        AnalysisProtocol.AnalysisCompleted snapshot ->
          acceptAnalysisResult generation snapshot model
        AnalysisProtocol.WorkerRequestFailed _ failure -> analysisFailureTransaction failure
        AnalysisProtocol.WorkerHealthChanged AnalysisProtocol.WorkerHealthy ->
          analysisStatusTransaction "GHC: healthy"
        AnalysisProtocol.WorkerHealthChanged (AnalysisProtocol.WorkerDegraded message) ->
          analysisStatusTransaction ("GHC degraded: " <> message)

acceptAnalysisResult
  :: AnalysisClient.WorkerGeneration
  -> Semantic.AnalysisSnapshot Semantic.RevisionedSourceRange
  -> EditorModel
  -> Transaction EditorModel
acceptAnalysisResult generation snapshot model =
  case (model.analysisComponent, findAnalysisDocument snapshot.analysisDocument model) of
    (Just component, Just document) ->
      case
          AnalysisAcceptance.acceptAnalysisSnapshot
            AnalysisAcceptance.AnalysisExpectation
              { AnalysisAcceptance.expectedWorkerGeneration = generation
              , AnalysisAcceptance.expectedWorkspaceGeneration = model.analysisWorkspaceGeneration
              , AnalysisAcceptance.expectedSession = component.componentSession
              , AnalysisAcceptance.expectedDocument = analysisDocumentId document
              , AnalysisAcceptance.expectedRevision = semanticRevision document.documentRevision
              , AnalysisAcceptance.expectedContentHash = Semantic.contentHash document.documentContents
              }
            generation
            snapshot of
        Left _ -> noTransaction
        Right accepted ->
          transactionFromAction
            "Accept current compiler analysis"
            NoUndo
            ( batchActions
                "Accept current compiler analysis"
                [ modify
                    editorProperties.analysisSnapshots
                    (Map.insert accepted.analysisDocument accepted)
                , editorProperties.analysisStatus .= analysisSummary accepted
                ]
            )
    _ -> noTransaction

findAnalysisDocument :: Semantic.DocumentId -> EditorModel -> Maybe Document
findAnalysisDocument identifier =
  find ((== identifier) . analysisDocumentId) . Map.elems . documents

analysisSummary :: Semantic.AnalysisSnapshot range -> Text
analysisSummary snapshot =
  "GHC: "
    <> diagnosticSummary
    <> " · "
    <> Text.pack (show declarationCount)
    <> if declarationCount == 1 then " declaration" else " declarations"
  where
    diagnostics = snapshot.analysisDiagnostics
    errorCount = length (filter ((== Semantic.DiagnosticError) . (.diagnosticSeverity)) diagnostics)
    warningCount = length (filter ((== Semantic.DiagnosticWarning) . (.diagnosticSeverity)) diagnostics)
    declarationCount = length snapshot.analysisDeclarations
    diagnosticSummary
      | errorCount == 0 && warningCount == 0 = "clean"
      | otherwise =
          Text.pack (show errorCount)
            <> if errorCount == 1 then " error" else " errors"
            <> ", "
            <> Text.pack (show warningCount)
            <> if warningCount == 1 then " warning" else " warnings"

analysisFailureTransaction :: AnalysisProtocol.RequestFailure -> Transaction EditorModel
analysisFailureTransaction failure =
  analysisStatusTransaction (prefix <> AnalysisProtocol.requestFailureMessage failure)
  where
    prefix
      | failure.requestFailureCode == "incompatible-compiler" =
          "GHC: unsupported compiler · "
      | otherwise = "GHC: "

analysisGenerationTransaction
  :: AnalysisClient.WorkerGeneration
  -> Text
  -> Transaction EditorModel
analysisGenerationTransaction generation message =
  transactionFromAction
    "Change compiler worker generation"
    NoUndo
    ( batchActions
        "Change compiler worker generation"
        [ editorProperties.analysisWorkerGeneration .= Just generation
        , editorProperties.analysisComponent .= Nothing
        , editorProperties.analysisSnapshots .= Map.empty
        , editorProperties.analysisStatus .= message
        ]
    )

analysisStatusTransaction :: Text -> Transaction EditorModel
analysisStatusTransaction message =
  transactionFromAction
    "Update compiler analysis status"
    NoUndo
    (editorProperties.analysisStatus .= message)

analysisServiceStatusText :: ServiceStatus -> Text
analysisServiceStatusText status =
  case status of
    ServiceStarting -> "GHC: starting service"
    ServiceRunning -> "GHC: analysis service running"
    ServiceHealthChanged ServiceHealthy -> "GHC: service healthy"
    ServiceHealthChanged (ServiceDegraded message) -> "GHC service degraded: " <> message
    ServiceRestartScheduled attempt _ ->
      "GHC: restarting service (attempt " <> Text.pack (show attempt) <> ")"
    ServiceExited _ -> "GHC: analysis service stopped"
    ServiceCircuitOpen _ _ -> "GHC: analysis service disabled after repeated failures"

visibleAnalysisLifecycleStatus :: EditorModel -> Text -> Text
visibleAnalysisLifecycleStatus model message
  | model.projectRoot /= Nothing
  , not model.analysisWorkspaceTrusted = "GHC: workspace untrusted"
  | otherwise = message

serviceStatusText :: ServiceStatus -> Text
serviceStatusText status =
  case status of
    ServiceStarting -> "Syntax: starting TextMate"
    ServiceRunning -> "Syntax: TextMate running"
    ServiceHealthChanged ServiceHealthy -> "Syntax: TextMate healthy"
    ServiceHealthChanged (ServiceDegraded message) -> "Syntax degraded: " <> message
    ServiceRestartScheduled attempt _ ->
      "Syntax: restarting TextMate (attempt " <> Text.pack (show attempt) <> ")"
    ServiceExited _ -> "Syntax: TextMate stopped"
    ServiceCircuitOpen _ _ -> "Syntax: TextMate disabled after repeated failures"

registryStatusText :: RegistrySummary -> Text
registryStatusText summary =
  "Syntax: "
    <> Text.pack (show (length summary.registryLanguageIds))
    <> " languages, "
    <> Text.pack (show (length summary.registryThemeIds))
    <> " themes"
    <> if summary.registryDiagnosticCount == 0
      then ""
      else " (" <> Text.pack (show summary.registryDiagnosticCount) <> " diagnostics)"

applyHighlightResult :: HighlightResult -> EditorModel -> Transaction EditorModel
applyHighlightResult result model =
  case Map.lookup result.resultDocument model.documents of
    Just document
      | result.resultRevision == document.documentRevision
      , result.resultContentHash == contentHash document.documentContents
      , maybe True (== result.resultRegistryGeneration) model.textMateRegistryGeneration ->
          transactionFromAction
            "Apply current TextMate highlight"
            NoUndo
            ( actionWithProperties
                "Apply current TextMate highlight"
                [ propertyId editorProperties.documents
                , propertyId editorProperties.textMateStatus
                ]
                ( \current ->
                    updateDocument
                      result.resultDocument
                      ( \currentDocument ->
                          currentDocument
                            { documentSyntaxLayer = Just result.resultLayer
                            , documentLanguage = Just result.resultLanguage
                            }
                      )
                      current
                        { textMateStatus = "Syntax: " <> result.resultLanguage.unLanguageId
                        }
                )
            )
    _ -> noTransaction

applyHighlightUnavailable
  :: DocumentKey
  -> TextRevision
  -> ContentHash
  -> Text
  -> EditorModel
  -> Transaction EditorModel
applyHighlightUnavailable documentKey revision sourceHash message model =
  case Map.lookup documentKey model.documents of
    Just document
      | revision == document.documentRevision
      , sourceHash == contentHash document.documentContents ->
          transactionFromAction
            "Apply TextMate fallback"
            NoUndo
            ( actionWithProperties
                "Apply TextMate fallback"
                [ propertyId editorProperties.documents
                , propertyId editorProperties.textMateStatus
                ]
                ( \current ->
                    updateDocument
                      documentKey
                      ( \currentDocument ->
                          currentDocument
                            { documentSyntaxLayer = Nothing
                            , documentLanguage = Nothing
                            }
                      )
                      current {textMateStatus = "Syntax fallback: " <> message}
                )
            )
    _ -> noTransaction

handleEventWithoutPersistence :: UIEvent -> EditorModel -> Transaction EditorModel
handleEventWithoutPersistence event model =
  case event of
    SystemColorSchemeChanged scheme
      | scheme == model.systemColorScheme -> noTransaction
      | otherwise ->
          transactionFromAction
            "Follow system color scheme"
            NoUndo
            (editorProperties.systemColorScheme .= scheme)
    CommandInvoked command
      | command == openCommand ->
          requestEffect "Choose text files" RequestOpenTextFiles
      | command == openFolderCommand ->
          requestEffect "Choose project folder" RequestOpenProjectFolder
      | command == trustWorkspaceCommand ->
          trustAnalysisWorkspace model
      | command == saveCommand ->
          saveActiveDocument model
    ProjectFolderChosen chosenPath -> openProjectFolder chosenPath model
    OptionalTextFileRead readPath result
      | Just readPath == model.workspaceTrustRegistryPath ->
          handleTrustRegistryRead result model
      | Just readPath == model.workspaceRegistryPath ->
          handleWorkspaceRegistryRead result model
      | Just root <- model.projectRoot
      , readPath == workspaceFilePath root ->
          handleWorkspaceFileRead root result model
    DirectoryRead directoryPath _
      | Map.notMember directoryPath model.projectEntries -> noTransaction
    DirectoryRead directoryPath result ->
      case result of
        Left message ->
          transactionFromAction
            "Report directory read failure"
            NoUndo
            ( editorProperties.workspaceMessage
                .= "Could not read " <> Text.pack directoryPath <> ": " <> message
            )
        Right entries ->
          transactionFromAction
            "Store project directory"
            NoUndo
            ( projectAction
                "Store directory entries"
                [ propertyId editorProperties.projectEntries
                , propertyId editorProperties.projectPathsByKey
                , propertyId editorProperties.nextProjectEntryIdentity
                , propertyId editorProperties.workspaceMessage
                ]
                (storeDirectoryEntries directoryPath entries)
            )
    TextFileChosen chosenPath ->
      openFilePath chosenPath model
    TextFileRead readPath result ->
      if Set.member (normalise readPath) model.workspaceRestorePendingFiles
        then handleRestoredDocumentRead (normalise readPath) result model
        else
          case result of
            Left message ->
              transactionFromAction
                "Report file read failure"
                NoUndo
                ( editorProperties.workspaceMessage
                    .= "Could not open " <> Text.pack readPath <> ": " <> message
                )
            Right readContents ->
              transactionFromAction
                "Open text document"
                NoUndo
                (insertDocumentAction readPath readContents)
    TextChanged changedKey changedContents ->
      case find ((== changedKey) . (.documentEditorKey)) (Map.elems model.documents) of
        Nothing -> noTransaction
        Just document ->
          case editBinding model InputChanged (documentContentsBinding document) changedContents of
            EditCommitted _ committed -> markAnalysisPending document model committed
            DraftStaged _ -> noTransaction
            DraftInvalid _ _ -> noTransaction
    CollectionSelectionChanged key [selectedKey]
      | key == projectTreeKey -> selectProjectEntry selectedKey model
      | key == problemsListKey -> selectProblem selectedKey model
    CollectionExpansionChanged key itemKey expanded
      | key == projectTreeKey -> setProjectExpansion itemKey expanded model
    TabSelected tabKey
      | tabKey `elem` [documentInspectorTabKey, problemsInspectorTabKey] ->
          transactionFromAction
            "Select inspector tab"
            NoUndo
            (editorProperties.selectedInspectorTab .= tabKey)
      | any ((== tabKey) . (.documentTabKey)) (Map.elems model.documents) ->
          transactionFromAction
            "Select document tab"
            NoUndo
            (editorProperties.selectedTab .= Just tabKey)
    TabCloseRequested tabKey -> closeTabRequested tabKey model
    PaneStateChanged paneKey paneState
      | paneKey == navigatorPaneKey ->
          transactionFromAction
            "Remember navigator pane state"
            NoUndo
            (editorProperties.navigatorState .= paneState)
      | paneKey == inspectorPaneKey ->
          transactionFromAction
            "Remember inspector pane state"
            NoUndo
            (editorProperties.inspectorState .= paneState)
    WindowCloseRequested key
      | key == workspaceWindowKey -> closeWorkspaceRequested model
    TextFileWritten writtenKey writtenPath writtenContents result ->
      handleWriteResult writtenKey writtenPath writtenContents result model
    _ -> noTransaction

markAnalysisPending :: Document -> EditorModel -> Transaction EditorModel -> Transaction EditorModel
markAnalysisPending document model update
  | model.analysisWorkspaceTrusted
  , model.projectRoot /= Nothing
  , isHaskellDocument document =
      update
        { transactionAction =
            batchActions
              "Edit text and await compiler analysis"
              [ update.transactionAction
              , editorProperties.analysisStatus .= "GHC: analyzing current revision"
              ]
        }
  | otherwise = update

projectPropertyIds :: [PropertyId]
projectPropertyIds =
  [ propertyId editorProperties.projectRoot
  , propertyId editorProperties.analysisWorkspaceTrusted
  , propertyId editorProperties.workspaceTrustRegistry
  , propertyId editorProperties.workspaceRequestedAnalysisTrust
  , propertyId editorProperties.projectEntries
  , propertyId editorProperties.projectPathsByKey
  , propertyId editorProperties.projectExpandedFolders
  , propertyId editorProperties.projectSelectedEntry
  , propertyId editorProperties.nextProjectEntryIdentity
  , propertyId editorProperties.workspaceMessage
  , propertyId editorProperties.documents
  , propertyId editorProperties.tabOrder
  , propertyId editorProperties.selectedTab
  , propertyId editorProperties.nextDocumentIdentity
  , propertyId editorProperties.navigatorState
  , propertyId editorProperties.inspectorState
  , propertyId editorProperties.workspacePersistencePhase
  , propertyId editorProperties.workspaceRestorePendingFiles
  , propertyId editorProperties.workspaceRestoreActiveFile
  , propertyId editorProperties.workspaceRestoreExplorerSelection
  ]

projectAction :: Text -> [PropertyId] -> (EditorModel -> EditorModel) -> Action EditorModel
projectAction = actionWithProperties

openProjectFolder :: FilePath -> EditorModel -> Transaction EditorModel
openProjectFolder chosenPath model
  | any documentDirty (Map.elems model.documents) =
      transactionFromAction
        "Veto workspace switch with unsaved documents"
        NoUndo
        ( editorProperties.workspaceMessage
            .= "Save modified documents before opening another workspace"
        )
  | otherwise = beginOpenProjectFolder rootPath True model
  where
    rootPath = normalise chosenPath

beginOpenProjectFolder :: FilePath -> Bool -> EditorModel -> Transaction EditorModel
beginOpenProjectFolder rootPath rememberWorkspace model =
  transactionFromActionWithEffects
    "Open project folder"
    NoUndo
    ( [ ReadDirectory rootPath
      , ReadOptionalTextFile (workspaceFilePath rootPath)
      ]
        <> [ workspaceRegistryWriteEffect registryPath rootPath
           | rememberWorkspace
           , Just registryPath <- [model.workspaceRegistryPath]
           ]
        <> [ trustRegistryWriteEffect trustRegistryPath trustedRegistry
           | rememberWorkspace
           , Just trustRegistryPath <- [model.workspaceTrustRegistryPath]
           ]
    )
    (projectAction "Set project root" projectPropertyIds (setProjectRoot rootPath rememberWorkspace))
  where
    trustedRegistry = trustRegistryInsert rootPath model.workspaceTrustRegistry

setProjectRoot :: FilePath -> Bool -> EditorModel -> EditorModel
setProjectRoot rootPath trusted model =
  model
    { documents = Map.empty
    , tabOrder = []
    , selectedTab = Nothing
    , nextDocumentIdentity = 1000
    , projectRoot = Just rootPath
    , analysisWorkspaceTrusted = trusted
    , workspaceTrustRegistry =
        if trusted
          then trustRegistryInsert rootPath model.workspaceTrustRegistry
          else model.workspaceTrustRegistry
    , workspaceRequestedAnalysisTrust = trusted
    , projectEntries = Map.singleton rootPath rootEntry
    , projectPathsByKey = Map.singleton (CollectionItemKey 1) rootPath
    , projectExpandedFolders = Set.singleton rootPath
    , projectSelectedEntry = Nothing
    , nextProjectEntryIdentity = 2
    , navigatorState = defaultNavigatorPaneState
    , inspectorState = defaultInspectorPaneState
    , workspacePersistencePhase = WorkspacePersistenceLoading
    , workspaceRestorePendingFiles = Set.empty
    , workspaceRestoreActiveFile = Nothing
    , workspaceRestoreExplorerSelection = Nothing
    , workspaceMessage = "Opened folder " <> Text.pack rootPath
    }
  where
    rootEntry =
      ProjectEntry
        { projectEntryKey = CollectionItemKey 1
        , projectEntryPath = rootPath
        , projectEntryName = displayPathName rootPath
        , projectEntryKind = FileSystemDirectory
        , projectEntryChildren = []
        , projectEntryChildrenLoaded = False
        }

trustAnalysisWorkspace :: EditorModel -> Transaction EditorModel
trustAnalysisWorkspace model =
  case model.projectRoot of
    Nothing -> noTransaction
    Just root ->
      transactionFromActionWithEffects
        "Trust workspace for compiler analysis"
        NoUndo
        [ trustRegistryWriteEffect path trustedRegistry
        | Just path <- [model.workspaceTrustRegistryPath]
        ]
        ( batchActions
            "Trust workspace for compiler analysis"
            [ editorProperties.analysisWorkspaceTrusted .= True
            , editorProperties.workspaceRequestedAnalysisTrust .= True
            , editorProperties.workspaceTrustRegistry .= trustedRegistry
            , editorProperties.analysisStatus .= "GHC: loading trusted workspace"
            ]
        )
      where
        trustedRegistry = trustRegistryInsert root model.workspaceTrustRegistry

storeDirectoryEntries :: FilePath -> [FileSystemEntry] -> EditorModel -> EditorModel
storeDirectoryEntries directoryPath unfilteredEntries model =
  case Map.lookup directoryPath model.projectEntries of
    Nothing -> model
    Just directory
      | directory.projectEntryKind /= FileSystemDirectory -> model
      | otherwise ->
          model
            { projectEntries = Map.insert directoryPath updatedDirectory updatedEntries
            , projectPathsByKey = updatedPathsByKey
            , nextProjectEntryIdentity = nextIdentity
            , workspaceMessage = "Loaded " <> Text.pack directoryPath
            }
      where
        (updatedEntries, updatedPathsByKey, nextIdentity, reversedChildPaths) =
          foldl'
            insertEntry
            ( model.projectEntries
            , model.projectPathsByKey
            , model.nextProjectEntryIdentity
            , []
            )
            entries
        updatedDirectory =
          directory
            { projectEntryChildren = reverse reversedChildPaths
            , projectEntryChildrenLoaded = True
            }

        insertEntry
          :: (Map FilePath ProjectEntry, Map CollectionItemKey FilePath, Word64, [FilePath])
          -> FileSystemEntry
          -> (Map FilePath ProjectEntry, Map CollectionItemKey FilePath, Word64, [FilePath])
        insertEntry (knownEntries, pathsByKey, identity, paths) fileSystemEntry =
          case Map.lookup path knownEntries of
            Just existing ->
              ( knownEntries
              , Map.insert existing.projectEntryKey path pathsByKey
              , identity
              , path : paths
              )
            Nothing ->
              ( Map.insert path projectEntry knownEntries
              , Map.insert projectEntry.projectEntryKey path pathsByKey
              , identity + 1
              , path : paths
              )
          where
            path = normalise fileSystemEntry.fileSystemEntryPath
            kind = fileSystemEntry.fileSystemEntryKind
            projectEntry =
              ProjectEntry
                { projectEntryKey = CollectionItemKey identity
                , projectEntryPath = path
                , projectEntryName = fileSystemEntry.fileSystemEntryName
                , projectEntryKind = kind
                , projectEntryChildren = []
                , projectEntryChildrenLoaded = kind == FileSystemFile
                }
  where
    entries =
      filter
        ((/= Text.pack workspaceFileName) . (.fileSystemEntryName))
        unfilteredEntries

workspaceFileEffectKey, workspaceRegistryEffectKey, trustRegistryEffectKey :: EffectKey
workspaceFileEffectKey = EffectKey maxBound
workspaceRegistryEffectKey = EffectKey (maxBound - 1)
trustRegistryEffectKey = EffectKey (maxBound - 2)

trustRegistryPathFor :: FilePath -> FilePath
trustRegistryPathFor lastWorkspacePath =
  takeDirectory lastWorkspacePath </> "trusted-workspaces.json"

workspaceRegistryWriteEffect :: FilePath -> FilePath -> Effect
workspaceRegistryWriteEffect registryPath rootPath =
  WriteTextFileAtomically
    workspaceRegistryEffectKey
    registryPath
    (Text.pack (normalise rootPath) <> "\n")

trustRegistryWriteEffect :: FilePath -> TrustRegistry -> Effect
trustRegistryWriteEffect path registry =
  WriteTextFileAtomically
    trustRegistryEffectKey
    path
    (encodeTrustRegistry registry <> "\n")

trustRegistryInsert :: FilePath -> TrustRegistry -> TrustRegistry
trustRegistryInsert root registry =
  registry
    { trustedWorkspaceRoots =
        Set.insert (normalise root) registry.trustedWorkspaceRoots
    }

handleTrustRegistryRead
  :: Either Text (Maybe Text)
  -> EditorModel
  -> Transaction EditorModel
handleTrustRegistryRead result model =
  case result of
    Left message ->
      transactionFromAction
        "Report trust-registry read failure"
        NoUndo
        ( editorProperties.workspaceMessage
            .= "Could not read the Visual Haskell trust registry: " <> message
        )
    Right Nothing -> noTransaction
    Right (Just contents) ->
      case decodeTrustRegistry contents of
        Left message ->
          transactionFromAction
            "Report invalid trust registry"
            NoUndo
            ( editorProperties.workspaceMessage
                .= "Could not decode the Visual Haskell trust registry: " <> message
            )
        Right registry ->
          transactionFromAction
            "Restore user workspace trust"
            NoUndo
            ( actionWithProperties
                "Restore user workspace trust"
                [ propertyId editorProperties.workspaceTrustRegistry
                , propertyId editorProperties.analysisWorkspaceTrusted
                ]
                (applyTrustRegistry registry)
            )
  where
    applyTrustRegistry registry current =
      current
        { workspaceTrustRegistry = registry
        , analysisWorkspaceTrusted =
            current.analysisWorkspaceTrusted
              || maybe
                False
                (\root ->
                  current.workspaceRequestedAnalysisTrust
                    && Set.member (normalise root) registry.trustedWorkspaceRoots
                )
                current.projectRoot
        }

handleWorkspaceRegistryRead
  :: Either Text (Maybe Text)
  -> EditorModel
  -> Transaction EditorModel
handleWorkspaceRegistryRead result model =
  case result of
    Left message ->
      transactionFromAction
        "Report last-workspace read failure"
        NoUndo
        ( editorProperties.workspaceMessage
            .= "Could not restore the last Visual Haskell workspace: " <> message
        )
    Right Nothing -> noTransaction
    Right (Just contents)
      | Text.null (Text.strip contents) -> noTransaction
      | otherwise ->
          beginOpenProjectFolder
            (normalise (Text.unpack (Text.strip contents)))
            False
            model

handleWorkspaceFileRead
  :: FilePath
  -> Either Text (Maybe Text)
  -> EditorModel
  -> Transaction EditorModel
handleWorkspaceFileRead root result model =
  case result of
    Left message -> workspaceReadBlocked root message
    Right Nothing ->
      let readyAction =
            actionWithProperties
              "Initialize fresh workspace state"
              [ propertyId editorProperties.workspacePersistencePhase
              , propertyId editorProperties.workspaceMessage
              ]
              ( \current ->
                  current
                    { workspacePersistencePhase = WorkspacePersistenceReady
                    , workspaceMessage = "Created Visual Haskell workspace state"
                    }
              )
          readyModel = applyAction readyAction model
       in transactionFromActionWithEffects
            "Initialize fresh workspace state"
            NoUndo
            (maybe [] pure (workspaceStateWriteEffect readyModel))
            readyAction
    Right (Just contents) ->
      case decodeWorkspaceState contents of
        Left message -> workspaceReadBlocked root message
        Right state -> restoreWorkspaceState root state

workspaceReadBlocked :: FilePath -> Text -> Transaction EditorModel
workspaceReadBlocked root message =
  transactionFromAction
    "Report workspace-state read failure"
    NoUndo
    ( actionWithProperties
        "Block unsafe workspace-state writes"
        [ propertyId editorProperties.workspacePersistencePhase
        , propertyId editorProperties.workspaceMessage
        ]
        ( \current ->
            current
              { workspacePersistencePhase = WorkspacePersistenceBlocked
              , workspaceMessage =
                  "Could not restore "
                    <> Text.pack (workspaceFilePath root)
                    <> "; preserving it unchanged: "
                    <> message
              }
        )
    )

restoreWorkspaceState :: FilePath -> WorkspaceState -> Transaction EditorModel
restoreWorkspaceState root state =
  transactionFromActionWithEffects
    "Restore Visual Haskell workspace"
    NoUndo
    effects
    ( actionWithProperties
        "Apply workspace metadata"
        [ propertyId editorProperties.projectExpandedFolders
        , propertyId editorProperties.projectSelectedEntry
        , propertyId editorProperties.navigatorState
        , propertyId editorProperties.inspectorState
        , propertyId editorProperties.workspacePersistencePhase
        , propertyId editorProperties.workspaceRestorePendingFiles
        , propertyId editorProperties.workspaceRestoreActiveFile
        , propertyId editorProperties.workspaceRestoreExplorerSelection
        , propertyId editorProperties.workspaceMessage
        , propertyId editorProperties.workspaceRequestedAnalysisTrust
        , propertyId editorProperties.analysisWorkspaceTrusted
        ]
        applyState
    )
  where
    openFiles = mapMaybe (fromWorkspaceRelativePath root) state.workspaceOpenFiles
    expandedFolders =
      Set.fromList
        (root : mapMaybe (fromWorkspaceRelativePath root) state.workspaceExpandedFolders)
    activeFile = state.workspaceActiveFile >>= fromWorkspaceRelativePath root
    explorerSelection =
      state.workspaceSelectedExplorerEntry >>= fromWorkspaceRelativePath root
    directoriesToRead =
      sortOn
        (\path -> (length (splitDirectories path), path))
        (filter (/= root) (Set.toList expandedFolders))
    effects = fmap ReadDirectory directoriesToRead <> fmap ReadTextFile openFiles
    pendingFiles = Set.fromList openFiles
    applyState current =
      let requestedTrust =
            current.workspaceRequestedAnalysisTrust || state.workspaceAnalysisTrusted
          approvedByUser =
            Set.member (normalise root) current.workspaceTrustRegistry.trustedWorkspaceRoots
       in
      current
        { projectExpandedFolders = expandedFolders
        , projectSelectedEntry = explorerSelection
        , navigatorState = state.workspaceNavigatorPane
        , inspectorState = state.workspaceInspectorPane
        , workspacePersistencePhase =
            if Set.null pendingFiles
              then WorkspacePersistenceReady
              else WorkspacePersistenceLoading
        , workspaceRestorePendingFiles = pendingFiles
        , workspaceRestoreActiveFile = activeFile
        , workspaceRestoreExplorerSelection = explorerSelection
        , workspaceRequestedAnalysisTrust = requestedTrust
        , analysisWorkspaceTrusted =
            current.analysisWorkspaceTrusted || (requestedTrust && approvedByUser)
        , workspaceMessage =
            if Set.null pendingFiles
              then "Restored Visual Haskell workspace"
              else "Restoring Visual Haskell workspace…"
        }

handleRestoredDocumentRead
  :: FilePath
  -> Either Text Text
  -> EditorModel
  -> Transaction EditorModel
handleRestoredDocumentRead readPath result _ =
  transactionFromAction
    "Restore workspace document"
    NoUndo
    ( actionWithProperties
        "Restore workspace document"
        ( insertDocumentPropertyIds
            <> [ propertyId editorProperties.workspacePersistencePhase
               , propertyId editorProperties.workspaceRestorePendingFiles
               , propertyId editorProperties.workspaceRestoreActiveFile
               , propertyId editorProperties.workspaceRestoreExplorerSelection
               ]
        )
        applyRead
    )
  where
    applyRead current =
      let readModel =
            case result of
              Left message ->
                current
                  { workspaceMessage =
                      "Could not restore " <> Text.pack readPath <> ": " <> message
                  }
              Right contents -> insertDocument readPath contents current
          pendingModel =
            readModel
              { workspaceRestorePendingFiles =
                  Set.delete readPath readModel.workspaceRestorePendingFiles
              , projectSelectedEntry = readModel.workspaceRestoreExplorerSelection
              }
       in finishIfComplete pendingModel

    finishIfComplete current
      | not (Set.null current.workspaceRestorePendingFiles) = current
      | otherwise =
          current
            { selectedTab = restoredSelection current
            , projectSelectedEntry = current.workspaceRestoreExplorerSelection
            , workspacePersistencePhase = WorkspacePersistenceReady
            , workspaceRestoreActiveFile = Nothing
            , workspaceRestoreExplorerSelection = Nothing
            , workspaceMessage = "Restored Visual Haskell workspace"
            }

    restoredSelection current =
      case current.workspaceRestoreActiveFile >>= (`findDocumentByPath` current) of
        Just document -> Just document.documentTabKey
        Nothing -> listToMaybe current.tabOrder

persistWorkspaceChanges
  :: EditorModel
  -> Transaction EditorModel
  -> Transaction EditorModel
persistWorkspaceChanges oldModel transactionValue =
  case workspaceStateWriteEffect updatedModel of
    Just writeEffect
      | workspaceStateFromModel oldModel /= workspaceStateFromModel updatedModel ->
          transactionValue
            { transactionEffects = transactionValue.transactionEffects <> [writeEffect]
            }
    _ -> transactionValue
  where
    updatedModel = applyTransaction transactionValue oldModel

workspaceStateWriteEffect :: EditorModel -> Maybe Effect
workspaceStateWriteEffect model
  | model.workspacePersistencePhase /= WorkspacePersistenceReady = Nothing
  | otherwise = do
      root <- model.projectRoot
      state <- workspaceStateFromModel model
      pure
        ( WriteTextFileAtomically
            workspaceFileEffectKey
            (workspaceFilePath root)
            (encodeWorkspaceState state <> "\n")
        )

workspaceStateFromModel :: EditorModel -> Maybe WorkspaceState
workspaceStateFromModel model = do
  root <- model.projectRoot
  let openFiles =
        mapMaybe
          ( \tabKey -> do
              document <- findDocumentByTab tabKey model
              toWorkspaceRelativePath root document.documentPath
          )
          model.tabOrder
      activeFile = do
        document <- selectedDocument model
        toWorkspaceRelativePath root document.documentPath
      expandedFolders =
        sortOn
          (\path -> (length (splitDirectories path), path))
          (mapMaybe (toWorkspaceRelativePath root) (Set.toList model.projectExpandedFolders))
      selectedEntry =
        model.projectSelectedEntry >>= toWorkspaceRelativePath root
  pure
    WorkspaceState
      { workspaceOpenFiles = openFiles
      , workspaceActiveFile = activeFile
      , workspaceExpandedFolders = expandedFolders
      , workspaceSelectedExplorerEntry = selectedEntry
      , workspaceNavigatorPane = model.navigatorState
      , workspaceInspectorPane = model.inspectorState
      , workspaceAnalysisTrusted = model.analysisWorkspaceTrusted
      }

selectProjectEntry :: CollectionItemKey -> EditorModel -> Transaction EditorModel
selectProjectEntry selectedKey model =
  case findProjectEntryByKey selectedKey model of
    Nothing -> noTransaction
    Just entry ->
      case entry.projectEntryKind of
        FileSystemFile -> openFilePath entry.projectEntryPath model
        FileSystemDirectory ->
          setFolderExpanded
            entry
            (not (Set.member entry.projectEntryPath model.projectExpandedFolders))
            model

selectProblem :: CollectionItemKey -> EditorModel -> Transaction EditorModel
selectProblem selectedKey model =
  case find ((== selectedKey) . (.problemKey)) (currentProblems model) of
    Nothing -> noTransaction
    Just problem ->
      transactionFromAction
        "Reveal compiler problem"
        NoUndo
        ( actionWithProperties
            "Reveal compiler problem"
            [ propertyId editorProperties.documents
            , propertyId editorProperties.selectedTab
            , propertyId editorProperties.selectedInspectorTab
            , propertyId editorProperties.selectedProblem
            , propertyId editorProperties.nextNavigationIdentity
            ]
            (reveal problem)
        )
  where
    reveal :: EditorProblem -> EditorModel -> EditorModel
    reveal problem current =
      current
        { documents =
            Map.adjust
              ( \document ->
                  document
                    { documentNavigation =
                        Just
                          TextNavigationRequest
                            { textNavigationKey = TextNavigationKey current.nextNavigationIdentity
                            , textNavigationRevision = document.documentRevision
                            , textNavigationRange = problem.problemDiagnostic.projectedRange
                            , textNavigationSelect = True
                            , textNavigationFocus = True
                            }
                    }
              )
              problem.problemDocumentKey
              current.documents
        , selectedTab = Just problem.problemTabKey
        , selectedInspectorTab = problemsInspectorTabKey
        , selectedProblem = Just problem.problemKey
        , nextNavigationIdentity = current.nextNavigationIdentity + 1
        }

setProjectExpansion :: CollectionItemKey -> Bool -> EditorModel -> Transaction EditorModel
setProjectExpansion itemKey expanded model =
  case findProjectEntryByKey itemKey model of
    Just entry
      | entry.projectEntryKind == FileSystemDirectory ->
          setFolderExpanded entry expanded model
    _ -> noTransaction

setFolderExpanded :: ProjectEntry -> Bool -> EditorModel -> Transaction EditorModel
setFolderExpanded entry expanded _ =
  transactionFromActionWithEffects
    "Change project folder expansion"
    NoUndo
    effects
    ( projectAction
        "Change folder expansion"
        [ propertyId editorProperties.projectExpandedFolders
        , propertyId editorProperties.projectSelectedEntry
        ]
        updateExpansion
    )
  where
    effects =
      [ ReadDirectory entry.projectEntryPath
      | expanded && not entry.projectEntryChildrenLoaded
      ]
    updateExpansion model =
      model
        { projectExpandedFolders =
            (if expanded then Set.insert else Set.delete)
              entry.projectEntryPath
              model.projectExpandedFolders
        -- Folder rows are deliberately deselected after activation so clicking
        -- the same row again reliably toggles it on native outline controls.
        , projectSelectedEntry = Nothing
        }

openFilePath :: FilePath -> EditorModel -> Transaction EditorModel
openFilePath requestedPath model =
  case findDocumentByPath path model of
    Just document ->
      transactionFromAction
        "Activate open project file"
        NoUndo
        ( actionWithProperties
            "Activate open project file"
            [ propertyId editorProperties.selectedTab
            , propertyId editorProperties.projectSelectedEntry
            , propertyId editorProperties.workspaceMessage
            ]
            ( \current ->
                current
                  { selectedTab = Just document.documentTabKey
                  , projectSelectedEntry = Just path
                  , workspaceMessage = "Selected " <> Text.pack path
                  }
            )
        )
    Nothing ->
      transactionFromActionWithEffects
        "Open project file"
        NoUndo
        [ReadTextFile path]
        ( actionWithProperties
            "Select project file"
            [ propertyId editorProperties.projectSelectedEntry
            , propertyId editorProperties.workspaceMessage
            ]
            ( \current ->
                current
                  { projectSelectedEntry = Just path
                  , workspaceMessage = "Opening " <> Text.pack path
                  }
            )
        )
  where
    path = normalise requestedPath

closeTabRequested :: TabKey -> EditorModel -> Transaction EditorModel
closeTabRequested tabKey model =
  case findDocumentByTab tabKey model of
    Nothing -> noTransaction
    Just document
      | documentDirty document ->
          transactionFromAction
            "Defer dirty tab close"
            NoUndo
            ( liftDocumentAction document.documentKey
                ( batchActions
                    "Defer dirty tab close"
                    [ documentProperties.documentStatus
                        .= "Close deferred: save this document to close its tab"
                    , documentProperties.documentCloseAfterSave .= True
                    ]
                )
            )
      | otherwise ->
          transactionFromAction
            "Close document tab"
            NoUndo
            (removeDocumentAction document.documentKey)

closeWorkspaceRequested :: EditorModel -> Transaction EditorModel
closeWorkspaceRequested model =
  case find documentDirty (Map.elems model.documents) of
    Nothing ->
      transactionFromAction
        "Close workspace"
        NoUndo
        (editorProperties.workspaceOpen .= False)
    Just dirtyDocument ->
      transactionFromAction
        "Veto dirty workspace close"
        NoUndo
        ( batchActions
            "Veto dirty workspace close"
            [ liftDocumentAction
                dirtyDocument.documentKey
                ( documentProperties.documentStatus
                    .= "Workspace close deferred: save modified documents first"
                )
            , editorProperties.selectedTab .= Just dirtyDocument.documentTabKey
            , editorProperties.workspaceMessage
                .= "Workspace close deferred: modified documents remain"
            ]
        )

saveActiveDocument :: EditorModel -> Transaction EditorModel
saveActiveDocument model =
  case selectedDocument model of
    Nothing -> noTransaction
    Just document
      | not (documentDirty document) -> noTransaction
      | otherwise ->
          transactionFromActionWithEffects
            "Save text document"
            NoUndo
            [WriteTextFile document.documentEffectKey document.documentPath document.documentContents]
            ( liftDocumentAction
                document.documentKey
                (documentProperties.documentStatus .= "Saving…")
            )

handleWriteResult
  :: EffectKey
  -> FilePath
  -> Text
  -> Either Text ()
  -> EditorModel
  -> Transaction EditorModel
handleWriteResult writtenKey writtenPath writtenContents result model =
  if writtenKey == workspaceFileEffectKey
    then
      case result of
        Right () -> noTransaction
        Left message ->
          transactionFromAction
            "Report workspace-state write failure"
            NoUndo
            ( actionWithProperties
                "Block failed workspace-state writes"
                [ propertyId editorProperties.workspacePersistencePhase
                , propertyId editorProperties.workspaceMessage
                ]
                ( \current ->
                    current
                      { workspacePersistencePhase = WorkspacePersistenceBlocked
                      , workspaceMessage =
                          "Could not save " <> Text.pack writtenPath <> ": " <> message
                      }
                )
            )
    else
      if writtenKey == workspaceRegistryEffectKey
        then
          case result of
            Right () -> noTransaction
            Left message ->
              transactionFromAction
                "Report last-workspace write failure"
                NoUndo
                ( editorProperties.workspaceMessage
                    .= "Could not remember the last workspace: " <> message
                )
        else handleDocumentWriteResult
  where
    handleDocumentWriteResult =
      case find ((== writtenKey) . (.documentEffectKey)) (Map.elems model.documents) of
        Nothing -> noTransaction
        Just document
          | document.documentPath /= writtenPath -> noTransaction
          | otherwise ->
              case result of
                Left message ->
                  transactionFromAction
                    "Report file write failure"
                    NoUndo
                    ( liftDocumentAction document.documentKey
                        ( batchActions
                            "Report file write failure"
                            [ documentProperties.documentStatus .= "Save failed: " <> message
                            , documentProperties.documentCloseAfterSave .= False
                            ]
                        )
                    )
                Right ()
                  | document.documentContents == writtenContents && document.documentCloseAfterSave ->
                      transactionFromAction
                        "Finish save and close tab"
                        NoUndo
                        (removeDocumentAction document.documentKey)
                  | otherwise ->
                      transactionFromAction
                        "Finish text save"
                        NoUndo
                        ( liftDocumentAction document.documentKey
                            ( batchActions
                                "Finish text save"
                                [ documentProperties.documentSavedContents .= writtenContents
                                , documentProperties.documentStatus
                                    .= if document.documentContents == writtenContents
                                      then "Saved"
                                      else "Saved an older revision; newer edits remain unsaved"
                                ]
                            )
                        )

insertDocument :: FilePath -> Text -> EditorModel -> EditorModel
insertDocument documentPath initialContents model =
  case findDocumentByPath normalizedPath model of
    Just existing ->
      model
        { selectedTab = Just existing.documentTabKey
        , projectSelectedEntry = Just normalizedPath
        , workspaceMessage = "Selected " <> Text.pack normalizedPath
        }
    Nothing ->
      model
        { documents = Map.insert key document model.documents
        , tabOrder = model.tabOrder <> [tabKey]
        , selectedTab = Just tabKey
        , nextDocumentIdentity = identity + 1
        , workspaceOpen = True
        , projectSelectedEntry = Just normalizedPath
        , workspaceMessage = "Opened " <> Text.pack normalizedPath
        }
  where
    normalizedPath = normalise documentPath
    identity = model.nextDocumentIdentity
    key = DocumentKey identity
    tabKey = TabKey identity
    document =
      Document
        { documentKey = key
        , documentTabKey = tabKey
        , documentEditorKey = ElementKey (1000000 + identity)
        , documentEffectKey = EffectKey identity
        , documentPath = normalizedPath
        , documentContents = initialContents
        , documentRevision = TextRevision 0
        , documentSavedContents = initialContents
        , documentStatus = Text.pack documentPath
        , documentCloseAfterSave = False
        , documentSyntaxLayer = Nothing
        , documentLanguage = Nothing
        , documentNavigation = Nothing
        }

documentPresentation :: EditorModel -> Document -> [TextLayer]
documentPresentation model document = syntaxLayers <> maybeToList diagnosticLayer
  where
    syntaxLayers
      | Just layer <- document.documentSyntaxLayer
      , layer.textLayerRevision == document.documentRevision = [layer]
      | isHaskellPath document.documentPath =
          [haskellSyntaxLayer model.systemColorScheme document.documentRevision document.documentContents]
      | otherwise = []
    diagnosticLayer =
      Diagnostics.diagnosticTextLayer
        model.systemColorScheme
        document.documentRevision
        (documentProblems model document)

currentProblems :: EditorModel -> [EditorProblem]
currentProblems model = sortOn problemSortKey (concatMap (problemsForDocument model) (Map.elems model.documents))

problemsForDocument :: EditorModel -> Document -> [EditorProblem]
problemsForDocument model document =
  case Map.lookup (analysisDocumentId document) model.analysisSnapshots of
    Nothing -> []
    Just snapshot ->
      [ EditorProblem
          { problemKey = diagnosticCollectionKey document diagnostic
          , problemDocumentKey = document.documentKey
          , problemTabKey = document.documentTabKey
          , problemPath = document.documentPath
          , problemDiagnostic = diagnostic
          }
      | diagnostic <-
          Diagnostics.projectCurrentDiagnostics
            (analysisDocumentId document)
            document.documentRevision
            document.documentContents
            snapshot
      ]

documentProblems :: EditorModel -> Document -> [Diagnostics.ProjectedDiagnostic]
documentProblems model document = fmap (.problemDiagnostic) (problemsForDocument model document)

problemSortKey :: EditorProblem -> (Int, FilePath, Int, Int, Text)
problemSortKey problem =
  ( severityRank problem.problemDiagnostic.projectedSeverity
  , problem.problemPath
  , problem.problemDiagnostic.projectedLine
  , problem.problemDiagnostic.projectedColumn
  , problem.problemDiagnostic.projectedMessage
  )

severityRank :: Semantic.DiagnosticSeverity -> Int
severityRank severity =
  case severity of
    Semantic.DiagnosticError -> 0
    Semantic.DiagnosticWarning -> 1
    Semantic.DiagnosticInformation -> 2
    Semantic.DiagnosticHint -> 3

diagnosticCollectionKey :: Document -> Diagnostics.ProjectedDiagnostic -> CollectionItemKey
diagnosticCollectionKey document diagnostic =
  CollectionItemKey
    ( setBit
        ( stableTextIdentity
            ( Text.pack document.documentPath
                <> "\NUL"
                <> diagnostic.projectedDiagnosticId.unDiagnosticId
            )
        )
        63
    )

stableTextIdentity :: Text -> Word64
stableTextIdentity = Text.foldl' step 14695981039346656037
  where
    step hash character = (hash `xorWord64` fromIntegral (fromEnum character)) * 1099511628211
    xorWord64 left right = left `xor` right

nextTextRevision :: TextRevision -> TextRevision
nextTextRevision (TextRevision revision) = TextRevision (revision + 1)

selectedDocument :: EditorModel -> Maybe Document
selectedDocument model = model.selectedTab >>= (`findDocumentByTab` model)

findDocumentByTab :: TabKey -> EditorModel -> Maybe Document
findDocumentByTab tabKey =
  find ((== tabKey) . (.documentTabKey)) . Map.elems . documents

findDocumentByPath :: FilePath -> EditorModel -> Maybe Document
findDocumentByPath requestedPath =
  find ((== normalise requestedPath) . normalise . (.documentPath))
    . Map.elems
    . documents

findProjectEntryByKey :: CollectionItemKey -> EditorModel -> Maybe ProjectEntry
findProjectEntryByKey itemKey model = do
  path <- Map.lookup itemKey model.projectPathsByKey
  Map.lookup path model.projectEntries

updateDocument :: DocumentKey -> (Document -> Document) -> EditorModel -> EditorModel
updateDocument key change model =
  model {documents = Map.adjust change key model.documents}

removeDocument :: DocumentKey -> EditorModel -> EditorModel
removeDocument key model =
  case Map.lookup key model.documents of
    Nothing -> model
    Just document ->
      let remainingOrder = filter (/= document.documentTabKey) model.tabOrder
          nextSelection
            | model.selectedTab == Just document.documentTabKey =
                nextTabAfterRemoval document.documentTabKey model.tabOrder
            | otherwise = model.selectedTab
       in model
            { documents = Map.delete key model.documents
            , tabOrder = remainingOrder
            , selectedTab = nextSelection
            , workspaceMessage =
                if null remainingOrder
                  then "No documents open"
                  else "Closed " <> Text.pack (takeFileName document.documentPath)
            }
