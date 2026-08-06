{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

module Example.AppKitVertical
  ( application
  , greetingLabelKey
  , mainWindowKey
  , nameFieldKey
  , saveCommand
  ) where

import Data.Text (Text)
import qualified Data.Text as Text
import GHC.Generics (Generic)
import HaskeLUI.Binding
import HaskeLUI.Core
import HaskeLUI.Property

data Model = Model
  { name :: !Text
  , status :: !Text
  , dirty :: !Bool
  , mainWindowOpen :: !Bool
  , inspectorOpen :: !Bool
  }
  deriving stock (Eq, Generic, Show)

properties :: Path Model Model
properties = rootPath

nameBinding :: Binding Model Text
nameBinding =
  bindWith
    properties.name
    [ alsoWrite (const (properties.dirty .= True))
    , alsoWrite
        ( const
            ( properties.status
                .= "Unsaved changes — closing this window is currently vetoed"
            )
        )
    , commitPolicy Live
    , undoPolicy (Coalesce (UndoGroup "edit-name"))
    , labelTransaction "Edit name"
    ]

mainWindowKey, inspectorWindowKey :: WindowKey
mainWindowKey = WindowKey 1
inspectorWindowKey = WindowKey 2

greetingLabelKey, nameFieldKey :: ElementKey
greetingLabelKey = ElementKey 100
nameFieldKey = ElementKey 101

saveCommand, toggleInspectorCommand :: CommandId
saveCommand = CommandId 1
toggleInspectorCommand = CommandId 2

application :: App Model
application =
  App
    { appInitialModel =
        Model
          { name = "Haskell"
          , status = "Unsaved changes — closing this window is currently vetoed"
          , dirty = True
          , mainWindowOpen = True
          , inspectorOpen = True
        }
    , appInitialEffects = []
    , appView = render
    , appHandleEvent = handleEvent
    }

render :: Model -> AppView
render model =
  AppView
    { appWindows =
        [mainWindow model | model.mainWindowOpen]
          <> [inspectorWindow model | model.inspectorOpen]
    , appCommands =
        [ CommandSpec saveCommand "Save" (Just "s") model.dirty
        , CommandSpec toggleInspectorCommand "Toggle Inspector" (Just "i") True
        ]
    }

mainWindow :: Model -> WindowSpec
mainWindow model =
  WindowSpec
    { windowKey = mainWindowKey
    , windowTitle = if model.dirty then "HaskeLUI AppKit PoC — Edited" else "HaskeLUI AppKit PoC"
    , windowFrame = Rect 120 180 540 320
    , windowControls =
        [ Label greetingLabelKey (Rect 24 260 480 24) ("Hello, " <> model.name <> "!")
        , TextField nameFieldKey (Rect 24 215 300 28) (readBinding nameBinding model) "Your name" True
        , Button (ElementKey 102) (Rect 24 160 120 32) "Save" saveCommand model.dirty
        , Button (ElementKey 103) (Rect 156 160 168 32) inspectorTitle toggleInspectorCommand True
        , Label (ElementKey 104) (Rect 24 95 490 44) model.status
        , Label
            (ElementKey 105)
            (Rect 24 38 490 40)
            "The Save button and Command-S invoke the same command. Try closing before and after saving."
        ]
    }
  where
    inspectorTitle
      | model.inspectorOpen = "Hide Inspector"
      | otherwise = "Show Inspector"

inspectorWindow :: Model -> WindowSpec
inspectorWindow model =
  WindowSpec
    { windowKey = inspectorWindowKey
    , windowTitle = "Inspector"
    , windowFrame = Rect 700 240 320 220
    , windowControls =
        [ Label (ElementKey 200) (Rect 24 160 270 24) "Retained native inspector window"
        , Label (ElementKey 201) (Rect 24 120 270 24) ("Name length: " <> Text.pack (show (Text.length model.name)))
        , Label (ElementKey 202) (Rect 24 80 270 24) (if model.dirty then "Document state: edited" else "Document state: saved")
        , Button (ElementKey 203) (Rect 24 28 160 32) "Toggle Inspector" toggleInspectorCommand True
        ]
    }

handleEvent :: UIEvent -> Model -> Transaction Model
handleEvent event model =
  case event of
    TextChanged key updatedName
      | key == nameFieldKey ->
          case editBinding model InputChanged nameBinding updatedName of
            EditCommitted _ committed -> committed
            DraftStaged _ -> noTransaction
            DraftInvalid _ _ -> noTransaction
    CommandInvoked command
      | command == saveCommand ->
          transactionFromAction
            "Save"
            NoUndo
            ( batchActions
                "Save"
                [ properties.dirty .= False
                , properties.status .= "Saved — the main window may now close"
                ]
            )
      | command == toggleInspectorCommand ->
          transactionFromAction "Toggle inspector" NoUndo (modify properties.inspectorOpen not)
    WindowCloseRequested key
      | key == inspectorWindowKey ->
          transactionFromAction "Close inspector" NoUndo (properties.inspectorOpen .= False)
      | key == mainWindowKey && model.dirty ->
          transaction
            "Veto close"
            NoUndo
            (\current -> current {status = "Close vetoed: save with Command-S, then close again"})
      | key == mainWindowKey ->
          transactionFromAction
            "Close main window"
            NoUndo
            ( batchActions
                "Close main window"
                [ properties.mainWindowOpen .= False
                , properties.inspectorOpen .= False
                ]
            )
    _ -> noTransaction
