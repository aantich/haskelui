{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Data.Text (Text)
import qualified Data.Text as Text
import UIH.Backend.AppKit
  ( AppKitCapabilities (..)
  , appKitBackend
  , queryAppKitCapabilities
  )
import UIH.Core
import UIH.Runtime (runApp)

data Model = Model
  { name :: !Text
  , status :: !Text
  , dirty :: !Bool
  , mainWindowOpen :: !Bool
  , inspectorOpen :: !Bool
  }
  deriving stock (Eq, Show)

mainWindowKey, inspectorWindowKey :: WindowKey
mainWindowKey = WindowKey 1
inspectorWindowKey = WindowKey 2

nameFieldKey :: ElementKey
nameFieldKey = ElementKey 101

saveCommand, toggleInspectorCommand :: CommandId
saveCommand = CommandId 1
toggleInspectorCommand = CommandId 2

main :: IO ()
main = do
  capabilities <- queryAppKitCapabilities
  putStrLn ("Starting UIH AppKit vertical slice on " <> show capabilities.appKitVersion)
  runApp appKitBackend application

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
    , windowTitle = if model.dirty then "UIH AppKit PoC — Edited" else "UIH AppKit PoC"
    , windowFrame = Rect 120 180 540 320
    , windowControls =
        [ Label (ElementKey 100) (Rect 24 260 480 24) ("Hello, " <> model.name <> "!")
        , TextField nameFieldKey (Rect 24 215 300 28) model.name "Your name" True
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
          transaction
            "Edit name"
            (Coalesce (UndoGroup "edit-name"))
            ( \current ->
                current
                  { name = updatedName
                  , dirty = True
                  , status = "Unsaved changes — closing this window is currently vetoed"
                  }
            )
    CommandInvoked command
      | command == saveCommand ->
          transaction
            "Save"
            NoUndo
            (\current -> current {dirty = False, status = "Saved — the main window may now close"})
      | command == toggleInspectorCommand ->
          transaction
            "Toggle inspector"
            NoUndo
            (\current -> current {inspectorOpen = not current.inspectorOpen})
    WindowCloseRequested key
      | key == inspectorWindowKey ->
          transaction "Close inspector" NoUndo (\current -> current {inspectorOpen = False})
      | key == mainWindowKey && model.dirty ->
          transaction
            "Veto close"
            NoUndo
            (\current -> current {status = "Close vetoed: save with Command-S, then close again"})
      | key == mainWindowKey ->
          transaction
            "Close main window"
            NoUndo
            (\current -> current {mainWindowOpen = False, inspectorOpen = False})
    _ -> noTransaction
