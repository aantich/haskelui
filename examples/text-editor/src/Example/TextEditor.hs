{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

module Example.TextEditor
  ( application
  , applicationWithDocument
  , firstDocumentEditorKey
  , firstDocumentTabKey
  , firstDocumentWindowKey
  , openCommand
  , saveCommand
  , workspaceWindowKey
  ) where

import Data.List (find)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word64)
import Example.TextEditor.Highlighting
  ( codeEditorBaseStyle
  , haskellSyntaxLayer
  )
import System.FilePath
  ( takeExtension
  , takeFileName
  )
import UIH.Core

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
  deriving stock (Eq, Show)

data EditorModel = EditorModel
  { documents :: !(Map DocumentKey Document)
  , tabOrder :: ![TabKey]
  , selectedTab :: !(Maybe TabKey)
  , nextDocumentIdentity :: !Word64
  , workspaceOpen :: !Bool
  , workspaceMessage :: !Text
  }
  deriving stock (Eq, Show)

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

openCommand, saveCommand :: CommandId
openCommand = CommandId 10
saveCommand = CommandId 11

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
  editorApplication (insertDocument documentPath initialContents initialModel)

initialModel :: EditorModel
initialModel =
  EditorModel
    { documents = Map.empty
    , tabOrder = []
    , selectedTab = Nothing
    , nextDocumentIdentity = 1000
    , workspaceOpen = True
    , workspaceMessage = "Open one or more UTF-8 text files. Documents share this native workspace."
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
        [ CommandSpec openCommand "Open…" (Just "o") True
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
                , textEditorText = document.documentContents
                , textEditorRevision = document.documentRevision
                , textEditorBaseStyle = codeEditorBaseStyle
                , textEditorLayers = documentPresentation document
                , textEditorFocused = model.selectedTab == Just tabKey
                }
          ]
      }

navigatorControls :: EditorModel -> [Control]
navigatorControls model =
  Label (ElementKey 100) (Rect 14 690 200 22) "OPEN DOCUMENTS"
    : if null model.tabOrder
        then [Label (ElementKey 101) (Rect 14 654 200 22) "No documents open"]
        else zipWith renderEntry [0 ..] (mapMaybe (`findDocumentByTab` model) model.tabOrder)
  where
    renderEntry index document =
      Label
        (documentNavigatorKey document)
        (Rect 14 (654 - fromIntegral index * 28) 200 22)
        ( (if model.selectedTab == Just document.documentTabKey then "› " else "  ")
            <> Text.pack (takeFileName document.documentPath)
            <> if documentDirty document then " ●" else ""
        )

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

documentNavigatorKey :: Document -> ElementKey
documentNavigatorKey document =
  ElementKey (2000000 + document.documentKey.unDocumentKey)

handleEvent :: UIEvent -> EditorModel -> Transaction EditorModel
handleEvent event model =
  case event of
    CommandInvoked command
      | command == openCommand ->
          requestEffect "Choose text files" RequestOpenTextFiles
      | command == saveCommand ->
          saveActiveDocument model
    TextFileChosen chosenPath ->
      requestEffect "Read chosen text file" (ReadTextFile chosenPath)
    TextFileRead readPath result ->
      case result of
        Left message ->
          transaction
            "Report file read failure"
            NoUndo
            (\current -> current {workspaceMessage = "Could not open " <> Text.pack readPath <> ": " <> message})
        Right readContents ->
          transaction "Open text document" NoUndo (insertDocument readPath readContents)
    TextChanged changedKey changedContents ->
      case find ((== changedKey) . (.documentEditorKey)) (Map.elems model.documents) of
        Nothing -> noTransaction
        Just document ->
          transaction
            "Edit text"
            (Coalesce (UndoGroup ("edit-document-" <> Text.pack (show document.documentKey.unDocumentKey))))
            ( updateDocument document.documentKey $ \current ->
                current
                  { documentContents = changedContents
                  , documentRevision = nextTextRevision current.documentRevision
                  , documentStatus = "Unsaved changes"
                  , documentCloseAfterSave = False
                  }
            )
    TabSelected tabKey
      | any ((== tabKey) . (.documentTabKey)) (Map.elems model.documents) ->
          transaction "Select document tab" NoUndo (\current -> current {selectedTab = Just tabKey})
    TabCloseRequested tabKey -> closeTabRequested tabKey model
    WindowCloseRequested key
      | key == workspaceWindowKey -> closeWorkspaceRequested model
    TextFileWritten writtenKey writtenPath writtenContents result ->
      handleWriteResult writtenKey writtenPath writtenContents result model
    _ -> noTransaction

closeTabRequested :: TabKey -> EditorModel -> Transaction EditorModel
closeTabRequested tabKey model =
  case findDocumentByTab tabKey model of
    Nothing -> noTransaction
    Just document
      | documentDirty document ->
          transaction
            "Defer dirty tab close"
            NoUndo
            ( updateDocument document.documentKey $ \current ->
                current
                  { documentStatus = "Close deferred: save this document to close its tab"
                  , documentCloseAfterSave = True
                  }
            )
      | otherwise -> transaction "Close document tab" NoUndo (removeDocument document.documentKey)

closeWorkspaceRequested :: EditorModel -> Transaction EditorModel
closeWorkspaceRequested model =
  case find documentDirty (Map.elems model.documents) of
    Nothing ->
      transaction "Close workspace" NoUndo (\current -> current {workspaceOpen = False})
    Just dirtyDocument ->
      transaction
        "Veto dirty workspace close"
        NoUndo
        ( \current ->
            (updateDocument dirtyDocument.documentKey
              (\document -> document {documentStatus = "Workspace close deferred: save modified documents first"})
              current)
              { selectedTab = Just dirtyDocument.documentTabKey
              , workspaceMessage = "Workspace close deferred: modified documents remain"
              }
        )

saveActiveDocument :: EditorModel -> Transaction EditorModel
saveActiveDocument model =
  case selectedDocument model of
    Nothing -> noTransaction
    Just document
      | not (documentDirty document) -> noTransaction
      | otherwise ->
          transactionWithEffects
            "Save text document"
            NoUndo
            [WriteTextFile document.documentEffectKey document.documentPath document.documentContents]
            ( updateDocument document.documentKey $ \current ->
                current {documentStatus = "Saving…"}
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
              transaction
                "Report file write failure"
                NoUndo
                ( updateDocument document.documentKey $ \current ->
                    current
                      { documentStatus = "Save failed: " <> message
                      , documentCloseAfterSave = False
                      }
                )
            Right ()
              | document.documentContents == writtenContents && document.documentCloseAfterSave ->
                  transaction "Finish save and close tab" NoUndo (removeDocument document.documentKey)
              | otherwise ->
                  transaction
                    "Finish text save"
                    NoUndo
                    ( updateDocument document.documentKey $ \current ->
                        current
                          { documentSavedContents = writtenContents
                          , documentStatus =
                              if current.documentContents == writtenContents
                                then "Saved"
                                else "Saved an older revision; newer edits remain unsaved"
                          }
                    )

insertDocument :: FilePath -> Text -> EditorModel -> EditorModel
insertDocument documentPath initialContents model =
  model
    { documents = Map.insert key document model.documents
    , tabOrder = model.tabOrder <> [tabKey]
    , selectedTab = Just tabKey
    , nextDocumentIdentity = identity + 1
    , workspaceOpen = True
    , workspaceMessage = "Opened " <> Text.pack documentPath
    }
  where
    identity = model.nextDocumentIdentity
    key = DocumentKey identity
    tabKey = TabKey identity
    document =
      Document
        { documentKey = key
        , documentTabKey = tabKey
        , documentEditorKey = ElementKey (1000000 + identity)
        , documentEffectKey = EffectKey identity
        , documentPath = documentPath
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
