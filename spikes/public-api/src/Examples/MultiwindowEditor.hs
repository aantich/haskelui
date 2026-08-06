{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

module Examples.MultiwindowEditor
  ( Document (..)
  , DocumentId (..)
  , EditorModel (..)
  , currentFontSize
  , documentTitleAvailability
  , documentTitleBinding
  , editorApp
  , fontSizeBinding
  , initialEditorModel
  , saveCommandId
  ) where

import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Text
import GHC.Generics (Generic)
import HaskeLUI.Sketch

newtype DocumentId = DocumentId Int
  deriving stock (Eq, Ord, Show)

data Document = Document
  { title :: !Text
  , body :: !Text
  , dirty :: !Bool
  }
  deriving stock (Eq, Generic, Show)

data Settings = Settings
  { confirmBeforeClose :: !Bool
  , showSettings :: !Bool
  , fontSize :: !Int
  }
  deriving stock (Eq, Generic, Show)

data EditorModel = EditorModel
  { documents :: !(Map DocumentId Document)
  , pendingClose :: !(Maybe DocumentId)
  , settings :: !Settings
  , lastSaved :: !(Maybe DocumentId)
  }
  deriving stock (Eq, Generic, Show)

properties :: Path EditorModel EditorModel
properties = rootPath

documentProperties :: Path Document Document
documentProperties = rootPath

documentTitleBinding :: Binding Document Text
documentTitleBinding =
  bindWith
    documentProperties.title
    [ alsoWrite (const (documentProperties.dirty .= True))
    , validateWith nonEmptyTitle
    , commitPolicy Live
    , undoPolicy (Coalesce (UndoGroup "rename-document"))
    , syncPolicy DetectConcurrentChange
    , labelTransaction "Rename document"
    ]

documentBodyBinding :: Binding Document Text
documentBodyBinding =
  bindWith
    documentProperties.body
    [ alsoWrite (const (documentProperties.dirty .= True))
    , commitPolicy Live
    , undoPolicy (Coalesce (UndoGroup "edit-document-body"))
    , labelTransaction "Edit document body"
    ]

nonEmptyTitle :: Text -> Either BindingIssue ()
nonEmptyTitle candidate
  | Text.null (Text.strip candidate) =
      Left (BindingIssue "document-title.empty" "A document title cannot be empty")
  | otherwise = Right ()

documentTitleAvailability :: AsyncValidation Text
documentTitleAvailability =
  asyncValidation
    (ValidationId "document-title.available")
    Right
    checkDocumentTitleAvailability
    interpretAvailability
    [ debounce (Milliseconds 250)
    , commitWhilePending BlockCommit
    ]
  where
    checkDocumentTitleAvailability candidate =
      pure (Text.toCaseFold (Text.strip candidate) /= "reserved")

    interpretAvailability True = AsyncValid
    interpretAvailability False =
      AsyncInvalid
        (BindingIssue "document-title.reserved" "This document title is reserved")

documentsProperty :: Property EditorModel (Map DocumentId Document)
documentsProperty = asProperty properties.documents

fontSizeBinding :: Binding EditorModel Text
fontSizeBinding =
  bindText
    properties.settings.fontSize
    (textCodec (Text.pack . show) parseFontSize)
    [ validateWith validFontSize
    , commitPolicy OnEnterOrBlur
    , undoPolicy (SingleUndo (UndoGroup "change-editor-font-size"))
    , syncPolicy PreserveLocalDraft
    , labelTransaction "Change editor font size"
    ]

parseFontSize :: Text -> Either BindingIssue Int
parseFontSize candidate =
  case reads (Text.unpack candidate) of
    [(size, "")] -> Right size
    _ -> Left (BindingIssue "font-size.not-an-integer" "Font size must be an integer")

validFontSize :: Int -> Either BindingIssue ()
validFontSize size
  | size >= 8 && size <= 96 = Right ()
  | otherwise = Left (BindingIssue "font-size.out-of-range" "Font size must be between 8 and 96")

currentFontSize :: EditorModel -> Int
currentFontSize model = model.settings.fontSize

saveCommandId :: CommandId
saveCommandId = CommandId "document.save"

closeCommandId :: CommandId
closeCommandId = CommandId "document.close"

closeRequested :: Event EditorModel DocumentId
closeRequested =
  event (EventId "document.close-requested") $ \documentId model ->
    case Map.lookup documentId model.documents of
      Just document
        | document.dirty && model.settings.confirmBeforeClose ->
            model {pendingClose = Just documentId}
      _ -> removeDocument documentId model

confirmClose :: Event EditorModel DocumentId
confirmClose =
  event (EventId "document.close-confirmed") removeDocument

saveFinished :: Event EditorModel DocumentId
saveFinished =
  event (EventId "document.save-finished") $ \documentId model ->
    model
      { lastSaved = Just documentId
      , documents = Map.adjust (\document -> document {dirty = False}) documentId model.documents
      }

removeDocument :: DocumentId -> EditorModel -> EditorModel
removeDocument documentId model =
  model
    { documents = Map.delete documentId model.documents
    , pendingClose = Nothing
    }

data SaveRequest = SaveRequest !DocumentId !Document

saveDocument :: Effect EditorModel SaveRequest DocumentId
saveDocument =
  effect
    (EffectId "document.save")
    (\(SaveRequest documentId _) -> pure documentId)
    (emit saveFinished)

documentEditor :: Component Document
documentEditor = component $ \document ->
  focusScope (FocusKey "document-editor") $
    column
      [ textField documentTitleBinding [validateAsync documentTitleAvailability]
      , textArea documentBodyBinding []
      , row
          [ label (if document.dirty then "Unsaved changes" else "Saved")
          , button "Save" [onClick (invoke saveCommandId)]
          ]
      ]

documentWindow
  :: EditorModel
  -> DocumentId
  -> Document
  -> WindowSpec EditorModel
documentWindow model documentId document =
  window
    (documentWindowKey documentId)
    document.title
    [ content $
        focusScope (FocusKey ("document-" <> documentKeyText documentId)) $
          handleCommand saveCommandId (start saveDocument (SaveRequest documentId document)) $
            handleCommand closeCommandId (emit closeRequested documentId) $
              scopeAt documentsProperty documentId documentEditor model
    , onCloseRequest (emit closeRequested documentId)
    , menuBar
        [ commandMenu
            "File"
            [ commandItem saveCommandId
            , commandItem closeCommandId
            ]
        ]
    ]

documentWindowKey :: DocumentId -> WindowKey
documentWindowKey (DocumentId identifier) =
  WindowKey ("document-" <> Text.pack (show identifier))

documentKeyText :: DocumentId -> Text
documentKeyText (DocumentId identifier) = Text.pack (show identifier)

settingsWindow :: EditorModel -> WindowSpec EditorModel
settingsWindow _ =
  window
    (WindowKey "settings")
    "Settings"
    [ content $
        column
          [ checkbox
              "Confirm before closing unsaved documents"
              (bind properties.settings.confirmBeforeClose)
          , textField fontSizeBinding []
          , button
              "Done"
              [onClick (properties.settings.showSettings .= False)]
          ]
    ]

closeDialog :: EditorModel -> DocumentId -> WindowSpec EditorModel
closeDialog _ documentId =
  window
    (WindowKey "confirm-close")
    "Unsaved changes"
    [ content $
        column
          [ label "Close this document without saving?"
          , row
              [ button "Cancel" [onClick (properties.pendingClose .= Nothing)]
              , button "Close" [onClick (emit confirmClose documentId)]
              ]
          ]
    ]

editorScenes :: EditorModel -> [Scene EditorModel]
editorScenes model =
  [ documentGroup
      (SceneKey "documents")
      [ documentWindow model documentId document
      | (documentId, document) <- Map.toList model.documents
      ]
  ]
    <> [settingsScene (settingsWindow model) | model.settings.showSettings]
    <> [ dialogScene (SceneKey "confirm-close") (closeDialog model documentId)
       | documentId <- maybeToList model.pendingClose
       ]

editorCommands :: EditorModel -> [CommandSpec EditorModel]
editorCommands _ =
  [ command
      saveCommandId
      "Save"
      [ shortcut (Shortcut "Primary+S")
      ]
  , command
      closeCommandId
      "Close Document"
      [ shortcut (Shortcut "Primary+W")
      ]
  ]

editorApp :: App EditorModel
editorApp =
  App
    { appInitial = (initialEditorModel, [])
    , appScenes = editorScenes
    , appCommands = editorCommands
    , appSubscriptions = const [subscription "platform.open-files"]
    }

initialEditorModel :: EditorModel
initialEditorModel =
  EditorModel
    { documents =
        Map.fromList
          [ (DocumentId 1, Document "Notes" "First document" True)
          , (DocumentId 2, Document "Reference" "Second document" False)
          ]
    , pendingClose = Nothing
    , settings = Settings True True 14
    , lastSaved = Nothing
    }

maybeToList :: Maybe value -> [value]
maybeToList Nothing = []
maybeToList (Just item) = [item]
