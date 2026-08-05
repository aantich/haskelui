{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

module UIH.Core
  ( Action
  , App (..)
  , AppView (..)
  , CommandId (..)
  , CommandSpec (..)
  , Control (..)
  , Effect (..)
  , EffectKey (..)
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
  , requestEffect
  , transaction
  , transactionWithEffects
  ) where

import Data.Text (Text)
import Data.Word (Word64)

newtype WindowKey = WindowKey {unWindowKey :: Word64}
  deriving stock (Eq, Ord, Show)

newtype ElementKey = ElementKey {unElementKey :: Word64}
  deriving stock (Eq, Ord, Show)

newtype CommandId = CommandId {unCommandId :: Word64}
  deriving stock (Eq, Ord, Show)

newtype EffectKey = EffectKey {unEffectKey :: Word64}
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
  | TextEditor
      !ElementKey
      !Rect
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
  | WindowActivated !WindowKey
  | TextFileChosen !FilePath
  | TextFileRead !FilePath !(Either Text Text)
  | TextFileWritten !EffectKey !FilePath !Text !(Either Text ())
  deriving stock (Eq, Show)

data Effect
  = RequestOpenTextFiles
  | ReadTextFile !FilePath
  | WriteTextFile !EffectKey !FilePath !Text
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
  , transactionEffects :: ![Effect]
  }

transaction
  :: Text
  -> UndoPolicy
  -> (model -> model)
  -> Transaction model
transaction description undo change =
  transactionWithEffects description undo [] change

transactionWithEffects
  :: Text
  -> UndoPolicy
  -> [Effect]
  -> (model -> model)
  -> Transaction model
transactionWithEffects description undo effects change =
  Transaction
    { transactionAction = action description change
    , transactionUndo = undo
    , transactionDescription = Just description
    , transactionEffects = effects
    }

requestEffect :: Text -> Effect -> Transaction model
requestEffect description requested =
  transactionWithEffects description NoUndo [requested] id

noTransaction :: Transaction model
noTransaction =
  Transaction
    { transactionAction = action "No operation" id
    , transactionUndo = NoUndo
    , transactionDescription = Nothing
    , transactionEffects = []
    }

applyTransaction :: Transaction model -> model -> model
applyTransaction (Transaction (Action _ change) _ _ _) = change
