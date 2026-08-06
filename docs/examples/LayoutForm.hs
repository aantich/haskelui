{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

module LayoutForm
  ( ProfileModel (..)
  , profileForm
  ) where

import Data.Text (Text)
import UIH.Core

data ProfileModel = ProfileModel
  { profileName :: Text
  , profileShowWhitespace :: ToggleValue
  }

profileNameKey, profileWhitespaceKey, profileSaveButtonKey :: ElementKey
profileNameKey = ElementKey 101
profileWhitespaceKey = ElementKey 102
profileSaveButtonKey = ElementKey 103

profileSaveCommand :: CommandId
profileSaveCommand = CommandId 20

profileForm :: ProfileModel -> Control
profileForm model =
  LayoutContainer
    LayoutContainerSpec
      { layoutContainerKey = ElementKey 100
      , layoutContainerFrame = Rect 20 20 520 220
      , layoutContainerPresentation = GroupLayoutContainer "Profile"
      , layoutContainerEnvironment = defaultLayoutEnvironment
      , layoutContainerLayout =
          LayoutBox
            defaultBoxSpec {boxPadding = uniformInsets 16}
            ( LayoutFlow
                defaultColumn
                  { flowGap = 12
                  , flowCrossAlignment = CrossStretch
                  }
                [ FlowItem defaultFlowItem (LayoutLeaf profileNameKey)
                , FlowItem defaultFlowItem (LayoutLeaf profileWhitespaceKey)
                , FlowItem defaultFlowItem (LayoutLeaf profileSaveButtonKey)
                ]
            )
      , layoutContainerChildren =
          [ TextField profileNameKey (Rect 0 0 320 28) model.profileName "Name" False
          , CheckBox
              ToggleControlSpec
                { toggleControlKey = profileWhitespaceKey
                , toggleControlFrame = Rect 0 0 240 28
                , toggleControlLabel = ControlLabel "Show whitespace" Nothing
                , toggleControlValue = model.profileShowWhitespace
                , toggleControlEnabled = True
                }
          , Button profileSaveButtonKey (Rect 0 0 120 32) "Save" profileSaveCommand True
          ]
      }
