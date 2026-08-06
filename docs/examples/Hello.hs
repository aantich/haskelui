{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Data.Text (Text)
import UIH.Backend.AppKit (appKitBackend)
import UIH.Core
import UIH.Runtime (runApp)

data Model = Model
  { name :: !Text
  , saved :: !Bool
  , windowOpen :: !Bool
  }
  deriving stock (Eq, Show)

helloWindowKey :: WindowKey
helloWindowKey = WindowKey 1

nameKey :: ElementKey
nameKey = ElementKey 10

saveCommand :: CommandId
saveCommand = CommandId 1

application :: App Model
application =
  App
    { appInitialModel = Model "Haskell" False True
    , appView = view
    , appHandleEvent = update
    }

view :: Model -> AppView
view model =
  AppView
    { appWindows =
        [ WindowSpec
            { windowKey = helloWindowKey
            , windowTitle = if model.saved then "Hello — Saved" else "Hello"
            , windowFrame = Rect 120 160 480 240
            , windowControls =
                [ Label (ElementKey 11) (Rect 24 176 420 24) ("Hello, " <> model.name)
                , TextField nameKey (Rect 24 126 300 28) model.name "Your name" False
                , Button (ElementKey 12) (Rect 24 70 120 32) "Save" saveCommand (not model.saved)
                ]
            }
        | model.windowOpen
        ]
    , appCommands =
        [CommandSpec saveCommand "Save" (Just "s") (not model.saved)]
    }

update :: UIEvent -> Model -> Transaction Model
update event model =
  case event of
    TextChanged key value
      | key == nameKey ->
          transaction "Edit name" (Coalesce (UndoGroup "name")) $ \current ->
            current {name = value, saved = False}
    CommandInvoked command
      | command == saveCommand ->
          transaction "Save" NoUndo $ \current -> current {saved = True}
    WindowCloseRequested key
      | key == helloWindowKey ->
          transaction "Close window" NoUndo $ \current -> current {windowOpen = False}
    _ -> noTransaction

main :: IO ()
main = runApp appKitBackend application
