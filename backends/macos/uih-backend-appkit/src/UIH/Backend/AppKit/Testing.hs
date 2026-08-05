{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedRecordDot #-}

module UIH.Backend.AppKit.Testing
  ( AppKitDebugCounters (..)
  , AppKitTextEditorTestSpec (..)
  , AppKitVerticalTestSpec (..)
  , appKitBackendWithTextEditorTest
  , appKitBackendWithVerticalTest
  , appKitResourcesReleased
  , queryAppKitDebugCounters
  , queryAppKitLastTestFailure
  ) where

import qualified Data.ByteString as ByteString
import Data.Text (Text)
import qualified Data.Text.Encoding as Text
import Data.Text.Encoding.Error (lenientDecode)
import Foreign (alloca, peek)
import Foreign.Ptr (nullPtr)
import UIH.Backend.AppKit (appKitBackend)
import UIH.Backend.AppKit.Internal.FFI
  ( CDebugCounters (..)
  , c_debugCounters
  , c_testLastFailure
  , c_testScheduleVerticalScript
  , c_testScheduleTextEditorScript
  )
import UIH.Core
  ( CommandId (..)
  , ElementKey (..)
  , WindowKey (..)
  )
import UIH.Runtime
  ( Backend (..)
  )

data AppKitVerticalTestSpec = AppKitVerticalTestSpec
  { testMainWindow :: !WindowKey
  , testNameField :: !ElementKey
  , testGreetingLabel :: !ElementKey
  , testSaveCommand :: !CommandId
  }
  deriving stock (Eq, Show)

data AppKitTextEditorTestSpec = AppKitTextEditorTestSpec
  { testDocumentWindow :: !WindowKey
  , testTextEditor :: !ElementKey
  , testEditorSaveCommand :: !CommandId
  }
  deriving stock (Eq, Show)

data AppKitDebugCounters = AppKitDebugCounters
  { debugLiveWindows :: !Int
  , debugLiveControls :: !Int
  , debugLiveActionTargets :: !Int
  , debugLiveWindowDelegates :: !Int
  , debugQueuedCallbacks :: !Int
  , debugTestFailures :: !Int
  }
  deriving stock (Eq, Show)

appKitBackendWithVerticalTest :: AppKitVerticalTestSpec -> Backend
appKitBackendWithVerticalTest spec =
  Backend $ \dispatch -> do
    session <- appKitBackend.openBackend dispatch
    c_testScheduleVerticalScript
      spec.testMainWindow.unWindowKey
      spec.testNameField.unElementKey
      spec.testGreetingLabel.unElementKey
      spec.testSaveCommand.unCommandId
    pure session

appKitBackendWithTextEditorTest :: AppKitTextEditorTestSpec -> Backend
appKitBackendWithTextEditorTest spec =
  Backend $ \dispatch -> do
    session <- appKitBackend.openBackend dispatch
    c_testScheduleTextEditorScript
      spec.testDocumentWindow.unWindowKey
      spec.testTextEditor.unElementKey
      spec.testEditorSaveCommand.unCommandId
    pure session

queryAppKitDebugCounters :: IO AppKitDebugCounters
queryAppKitDebugCounters =
  alloca $ \pointer -> do
    c_debugCounters pointer
    CDebugCounters windows controls targets delegates callbacks failures <- peek pointer
    pure
      AppKitDebugCounters
        { debugLiveWindows = fromIntegral windows
        , debugLiveControls = fromIntegral controls
        , debugLiveActionTargets = fromIntegral targets
        , debugLiveWindowDelegates = fromIntegral delegates
        , debugQueuedCallbacks = fromIntegral callbacks
        , debugTestFailures = fromIntegral failures
        }

queryAppKitLastTestFailure :: IO (Maybe Text)
queryAppKitLastTestFailure = do
  pointer <- c_testLastFailure
  if pointer == nullPtr
    then pure Nothing
    else Just . Text.decodeUtf8With lenientDecode <$> ByteString.packCString pointer

appKitResourcesReleased :: AppKitDebugCounters -> Bool
appKitResourcesReleased counters =
  counters.debugLiveWindows == 0
    && counters.debugLiveControls == 0
    && counters.debugLiveActionTargets == 0
    && counters.debugLiveWindowDelegates == 0
    && counters.debugQueuedCallbacks == 0
