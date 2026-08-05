{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

module UIH.Core
  ( Action
  , App (..)
  , AppView (..)
  , CommandId (..)
  , CommandSpec (..)
  , Control (..)
  , ElementKey (..)
  , Rect (..)
  , Transaction (..)
  , UIEvent (..)
  , UndoGroup (..)
  , UndoPolicy (..)
  , WindowKey (..)
  , WindowSpec (..)
  , action
  , applyTransaction
  , noTransaction
  , transaction
  ) where

import Data.Text (Text)
import Data.Word (Word64)

newtype WindowKey = WindowKey {unWindowKey :: Word64}
  deriving stock (Eq, Ord, Show)

newtype ElementKey = ElementKey {unElementKey :: Word64}
  deriving stock (Eq, Ord, Show)

newtype CommandId = CommandId {unCommandId :: Word64}
  deriving stock (Eq, Ord, Show)

data Rect = Rect
  { rectX :: !Double
  , rectY :: !Double
  , rectWidth :: !Double
  , rectHeight :: !Double
  }
  deriving stock (Eq, Show)

data Control
  = Label
      !ElementKey
      !Rect
      !Text
  | Button
      !ElementKey
      !Rect
      !Text
      !CommandId
      !Bool
  | TextField
      !ElementKey
      !Rect
      !Text
      !Text
      !Bool
  deriving stock (Eq, Show)

data WindowSpec = WindowSpec
  { windowKey :: !WindowKey
  , windowTitle :: !Text
  , windowFrame :: !Rect
  , windowControls :: ![Control]
  }
  deriving stock (Eq, Show)

data CommandSpec = CommandSpec
  { commandId :: !CommandId
  , commandTitle :: !Text
  , commandKeyEquivalent :: !(Maybe Text)
  , commandEnabled :: !Bool
  }
  deriving stock (Eq, Show)

data AppView = AppView
  { appWindows :: ![WindowSpec]
  , appCommands :: ![CommandSpec]
  }
  deriving stock (Eq, Show)

data UIEvent
  = CommandInvoked !CommandId
  | TextChanged !ElementKey !Text
  | WindowCloseRequested !WindowKey
  deriving stock (Eq, Show)

data App model = App
  { appInitialModel :: !model
  , appView :: model -> AppView
  , appHandleEvent :: UIEvent -> model -> Transaction model
  }

data Action model = Action
  !Text
  (model -> model)

action :: Text -> (model -> model) -> Action model
action = Action

newtype UndoGroup = UndoGroup Text
  deriving stock (Eq, Show)

data UndoPolicy
  = NoUndo
  | UndoEveryEdit
  | Coalesce !UndoGroup
  | SingleUndo !UndoGroup
  deriving stock (Eq, Show)

data Transaction model = Transaction
  { transactionAction :: !(Action model)
  , transactionUndo :: !UndoPolicy
  , transactionDescription :: !(Maybe Text)
  }

transaction
  :: Text
  -> UndoPolicy
  -> (model -> model)
  -> Transaction model
transaction description undo change =
  Transaction
    { transactionAction = action description change
    , transactionUndo = undo
    , transactionDescription = Just description
    }

noTransaction :: Transaction model
noTransaction =
  Transaction
    { transactionAction = action "No operation" id
    , transactionUndo = NoUndo
    , transactionDescription = Nothing
    }

applyTransaction :: Transaction model -> model -> model
applyTransaction (Transaction (Action _ change) _ _) = change
