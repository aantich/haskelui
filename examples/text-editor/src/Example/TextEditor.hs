{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

module Example.TextEditor
  ( application
  , applicationWithDocument
  , firstDocumentEditorKey
  , firstDocumentWindowKey
  , openCommand
  , saveCommand
  ) where

import Data.List (find)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word64)
import System.FilePath (takeFileName)
import UIH.Core

data Document = Document
  { documentWindowKey :: !WindowKey
  , documentEditorKey :: !ElementKey
  , documentEffectKey :: !EffectKey
  , documentPath :: !FilePath
  , documentContents :: !Text
  , documentSavedContents :: !Text
  , documentStatus :: !Text
  , documentCloseAfterSave :: !Bool
  }
  deriving stock (Eq, Show)

data EditorModel = EditorModel
  { documents :: !(Map WindowKey Document)
  , activeWindow :: !(Maybe WindowKey)
  , nextDocumentIdentity :: !Word64
  , launcherOpen :: !Bool
  , launcherStatus :: !Text
  }
  deriving stock (Eq, Show)

launcherWindowKey :: WindowKey
launcherWindowKey = WindowKey 10

firstDocumentWindowKey :: WindowKey
firstDocumentWindowKey = WindowKey 1000

firstDocumentEditorKey :: ElementKey
firstDocumentEditorKey = ElementKey 1001000

openCommand, saveCommand :: CommandId
openCommand = CommandId 10
saveCommand = CommandId 11

application :: App EditorModel
application = editorApplication initialModel

applicationWithDocument :: FilePath -> Text -> App EditorModel
applicationWithDocument documentPath initialContents =
  editorApplication $
    (insertDocument documentPath initialContents initialModel)
      { launcherOpen = False
      }

initialModel :: EditorModel
initialModel =
  EditorModel
    { documents = Map.empty
    , activeWindow = Nothing
    , nextDocumentIdentity = 1000
    , launcherOpen = True
    , launcherStatus = "Open one or more UTF-8 text files. Each file gets its own native window."
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
    { appWindows =
        [launcherWindow model | model.launcherOpen]
          <> fmap (documentWindow model.activeWindow) (Map.elems model.documents)
    , appCommands =
        [ CommandSpec openCommand "Open…" (Just "o") True
        , CommandSpec saveCommand "Save" (Just "s") (maybe False documentDirty activeDocument)
        ]
    }
  where
    activeDocument = model.activeWindow >>= (`Map.lookup` model.documents)

launcherWindow :: EditorModel -> WindowSpec
launcherWindow model =
  WindowSpec
    { windowKey = launcherWindowKey
    , windowTitle = "UIH Text Editor"
    , windowFrame = Rect 120 220 520 210
    , windowControls =
        [ Label
            (ElementKey 10)
            (Rect 24 146 472 28)
            "A native multi-window text editor written in Haskell"
        , Button (ElementKey 11) (Rect 24 92 140 34) "Open Files…" openCommand True
        , Label (ElementKey 12) (Rect 24 30 472 44) model.launcherStatus
        ]
    }

documentWindow :: Maybe WindowKey -> Document -> WindowSpec
documentWindow active document =
  WindowSpec
    { windowKey = document.documentWindowKey
    , windowTitle = documentTitle document
    , windowFrame = Rect offset offset 800 640
    , windowControls =
        [ TextEditor
            document.documentEditorKey
            (Rect 12 54 776 574)
            document.documentContents
            (active == Just document.documentWindowKey)
        , Button (documentButtonKey document) (Rect 12 12 92 30) "Save" saveCommand (documentDirty document)
        , Label (documentStatusKey document) (Rect 116 16 672 24) document.documentStatus
        ]
    }
  where
    WindowKey identity = document.documentWindowKey
    offset = 80 + fromIntegral (identity `mod` 7) * 28

documentTitle :: Document -> Text
documentTitle document =
  Text.pack (takeFileName document.documentPath)
    <> if documentDirty document then " — Edited" else ""

documentDirty :: Document -> Bool
documentDirty document = document.documentContents /= document.documentSavedContents

documentButtonKey :: Document -> ElementKey
documentButtonKey document =
  let ElementKey identity = document.documentEditorKey
   in ElementKey (identity + 1)

documentStatusKey :: Document -> ElementKey
documentStatusKey document =
  let ElementKey identity = document.documentEditorKey
   in ElementKey (identity + 2)

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
            (\current -> current {launcherStatus = "Could not open " <> Text.pack readPath <> ": " <> message})
        Right readContents ->
          transaction
            "Open text document"
            NoUndo
            (insertDocument readPath readContents)
    TextChanged changedKey changedContents ->
      case find ((== changedKey) . (.documentEditorKey)) (Map.elems model.documents) of
        Nothing -> noTransaction
        Just document ->
          transaction
            "Edit text"
            (Coalesce (UndoGroup ("edit-document-" <> Text.pack (show document.documentWindowKey.unWindowKey))))
            ( updateDocument document.documentWindowKey $ \current ->
                current
                  { documentContents = changedContents
                  , documentStatus = "Unsaved changes"
                  , documentCloseAfterSave = False
                  }
            )
    WindowActivated key ->
      transaction
        "Activate window"
        NoUndo
        (\current -> current {activeWindow = if Map.member key current.documents then Just key else Nothing})
    WindowCloseRequested key
      | key == launcherWindowKey ->
          transaction
            "Close launcher"
            NoUndo
            (\current -> current {launcherOpen = False})
      | Just document <- Map.lookup key model.documents ->
          if documentDirty document
            then
              transaction
                "Veto dirty document close"
                NoUndo
                ( updateDocument key $ \current ->
                    current
                      { documentStatus = "Close deferred: save this document to close it"
                      , documentCloseAfterSave = True
                      }
                )
            else transaction "Close document" NoUndo (removeDocument key)
    TextFileWritten writtenKey writtenPath writtenContents result ->
      handleWriteResult writtenKey writtenPath writtenContents result model
    _ -> noTransaction

saveActiveDocument :: EditorModel -> Transaction EditorModel
saveActiveDocument model =
  case model.activeWindow >>= (`Map.lookup` model.documents) of
    Nothing -> noTransaction
    Just document
      | not (documentDirty document) -> noTransaction
      | otherwise ->
          transactionWithEffects
            "Save text document"
            NoUndo
            [WriteTextFile document.documentEffectKey document.documentPath document.documentContents]
            ( updateDocument document.documentWindowKey $ \current ->
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
                ( updateDocument document.documentWindowKey $ \current ->
                    current
                      { documentStatus = "Save failed: " <> message
                      , documentCloseAfterSave = False
                      }
                )
            Right ()
              | document.documentContents == writtenContents && document.documentCloseAfterSave ->
                  transaction "Finish save and close" NoUndo (removeDocument document.documentWindowKey)
              | otherwise ->
                  transaction
                    "Finish text save"
                    NoUndo
                    ( updateDocument document.documentWindowKey $ \current ->
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
    , activeWindow = Just key
    , nextDocumentIdentity = identity + 1
    , launcherStatus = "Opened " <> Text.pack documentPath
    }
  where
    identity = model.nextDocumentIdentity
    key = WindowKey identity
    document =
      Document
        { documentWindowKey = key
        , documentEditorKey = ElementKey (1000000 + identity)
        , documentEffectKey = EffectKey identity
        , documentPath = documentPath
        , documentContents = initialContents
        , documentSavedContents = initialContents
        , documentStatus = Text.pack documentPath
        , documentCloseAfterSave = False
        }

updateDocument :: WindowKey -> (Document -> Document) -> EditorModel -> EditorModel
updateDocument key change model =
  model {documents = Map.adjust change key model.documents}

removeDocument :: WindowKey -> EditorModel -> EditorModel
removeDocument key model =
  model
    { documents = Map.delete key model.documents
    , activeWindow = if model.activeWindow == Just key then Nothing else model.activeWindow
    }
