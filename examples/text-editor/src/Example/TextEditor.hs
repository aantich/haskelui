{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

module Example.TextEditor
  ( application
  , applicationWithDocument
  , applicationWithDocuments
  , firstDocumentEditorKey
  , firstDocumentTabKey
  , firstDocumentWindowKey
  , openCommand
  , openFolderCommand
  , projectTreeKey
  , saveCommand
  , workspaceWindowKey
  ) where

import Data.List
  ( find
  , foldl'
  )
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe
  ( listToMaybe
  , mapMaybe
  )
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word64)
import Example.TextEditor.Highlighting
  ( codeEditorBaseStyle
  , haskellSyntaxLayer
  )
import GHC.Generics (Generic)
import System.FilePath
  ( normalise
  , takeExtension
  , takeFileName
  )
import UIH.Binding
import UIH.Core
import UIH.Property

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
  }
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

openCommand, saveCommand, openFolderCommand :: CommandId
openCommand = CommandId 10
saveCommand = CommandId 11
openFolderCommand = CommandId 12

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

application :: App EditorModel
application = editorApplication initialModel

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
    }

editorApplication :: EditorModel -> App EditorModel
editorApplication startingModel =
  App
    { appInitialModel = startingModel
    , appView = render
    , appHandleEvent = handleEvent
    }

render :: EditorModel -> AppView
render model =
  AppView
    { appWindows = [workspaceWindow model | model.workspaceOpen]
    , appCommands =
        [ CommandSpec openCommand "Open File…" (Just "o") True
        , CommandSpec openFolderCommand "Open Folder…" Nothing True
        , CommandSpec saveCommand "Save" (Just "s") (maybe False documentDirty activeDocument)
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
    Nothing -> "UIH Text Editor"
    Just document ->
      Text.pack (takeFileName document.documentPath)
        <> if documentDirty document then " — Edited" else " — UIH Text Editor"

navigatorPane :: EditorModel -> WorkspacePaneSpec
navigatorPane model =
  WorkspacePaneSpec
    { workspacePaneKey = navigatorPaneKey
    , workspacePaneRole = SidebarPane
    , workspacePaneSizing = PaneSizing (Just 160) (Just 230) (Just 420) 0
    , workspacePaneState = PaneState PaneVisible (Just 230)
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
    , workspacePaneState = PaneState PaneVisible (Just 270)
    , workspacePaneItem =
        WorkspaceItemSpec
          { workspaceItemKey = inspectorItemKey
          , workspaceItemContent = WorkspaceItemControls (inspectorControls model)
          }
    }

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
                , textEditorLayers = documentPresentation document
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

statusControls :: EditorModel -> [Control]
statusControls model =
  [ Label (ElementKey 300) (Rect 12 4 780 20) status
  , Label (ElementKey 301) (Rect 880 4 270 20) summary
  ]
  where
    status = maybe model.workspaceMessage (.documentStatus) (selectedDocument model)
    summary =
      Text.pack (show (Map.size model.documents))
        <> if Map.size model.documents == 1 then " document" else " documents"

languageDescription :: Document -> Text
languageDescription document
  | takeExtension document.documentPath `elem` [".hs", ".lhs"] = "Haskell source"
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
  case event of
    CommandInvoked command
      | command == openCommand ->
          requestEffect "Choose text files" RequestOpenTextFiles
      | command == openFolderCommand ->
          requestEffect "Choose project folder" RequestOpenProjectFolder
      | command == saveCommand ->
          saveActiveDocument model
    ProjectFolderChosen chosenPath -> openProjectFolder chosenPath
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
            EditCommitted _ committed -> committed
            DraftStaged _ -> noTransaction
            DraftInvalid _ _ -> noTransaction
    CollectionSelectionChanged key [selectedKey]
      | key == projectTreeKey -> selectProjectEntry selectedKey model
    CollectionExpansionChanged key itemKey expanded
      | key == projectTreeKey -> setProjectExpansion itemKey expanded model
    TabSelected tabKey
      | any ((== tabKey) . (.documentTabKey)) (Map.elems model.documents) ->
          transactionFromAction
            "Select document tab"
            NoUndo
            (editorProperties.selectedTab .= Just tabKey)
    TabCloseRequested tabKey -> closeTabRequested tabKey model
    WindowCloseRequested key
      | key == workspaceWindowKey -> closeWorkspaceRequested model
    TextFileWritten writtenKey writtenPath writtenContents result ->
      handleWriteResult writtenKey writtenPath writtenContents result model
    _ -> noTransaction

projectPropertyIds :: [PropertyId]
projectPropertyIds =
  [ propertyId editorProperties.projectRoot
  , propertyId editorProperties.projectEntries
  , propertyId editorProperties.projectPathsByKey
  , propertyId editorProperties.projectExpandedFolders
  , propertyId editorProperties.projectSelectedEntry
  , propertyId editorProperties.nextProjectEntryIdentity
  , propertyId editorProperties.workspaceMessage
  ]

projectAction :: Text -> [PropertyId] -> (EditorModel -> EditorModel) -> Action EditorModel
projectAction = actionWithProperties

openProjectFolder :: FilePath -> Transaction EditorModel
openProjectFolder chosenPath =
  transactionFromActionWithEffects
    "Open project folder"
    NoUndo
    [ReadDirectory rootPath]
    (projectAction "Set project root" projectPropertyIds (setProjectRoot rootPath))
  where
    rootPath = normalise chosenPath

setProjectRoot :: FilePath -> EditorModel -> EditorModel
setProjectRoot rootPath model =
  model
    { projectRoot = Just rootPath
    , projectEntries = Map.singleton rootPath rootEntry
    , projectPathsByKey = Map.singleton (CollectionItemKey 1) rootPath
    , projectExpandedFolders = Set.singleton rootPath
    , projectSelectedEntry = Nothing
    , nextProjectEntryIdentity = 2
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

storeDirectoryEntries :: FilePath -> [FileSystemEntry] -> EditorModel -> EditorModel
storeDirectoryEntries directoryPath entries model =
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
        }

documentPresentation :: Document -> [TextLayer]
documentPresentation document
  | takeExtension document.documentPath `elem` [".hs", ".lhs"] =
      [haskellSyntaxLayer document.documentRevision document.documentContents]
  | otherwise = []

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
