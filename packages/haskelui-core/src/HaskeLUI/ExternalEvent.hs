module HaskeLUI.ExternalEvent
  ( ExternalEvent
  , ExternalSink (..)
  , EventCoalescingKey (..)
  , EventDelivery (..)
  , emitExternalEvent
  , externalEvent
  , externalEventDelivery
  , externalEventDescription
  , handleExternalEvent
  , latestExternalEvent
  ) where

import HaskeLUI.Core

