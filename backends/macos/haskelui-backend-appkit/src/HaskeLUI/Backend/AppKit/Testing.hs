{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedRecordDot #-}

module HaskeLUI.Backend.AppKit.Testing
  ( AppKitDebugCounters (..)
  , AppKitControlGalleryTestSpec (..)
  , AppKitTextEditorTestSpec (..)
  , AppKitVerticalTestSpec (..)
  , appKitBackendWithTextEditorTest
  , appKitBackendWithControlGalleryTest
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
import HaskeLUI.Backend.AppKit (appKitBackend)
import HaskeLUI.Backend.AppKit.Internal.FFI
  ( CDebugCounters (..)
  , c_debugCounters
  , c_testLastFailure
  , c_testScheduleVerticalScript
  , c_testScheduleTextEditorScript
  , c_testScheduleControlGalleryScript
  )
import HaskeLUI.Core
  ( CommandId (..)
  , ElementKey (..)
  , TabKey (..)
  , WindowKey (..)
  )
import HaskeLUI.Runtime
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
  , testDocumentTab :: !TabKey
  , testEditorSaveCommand :: !CommandId
  , testEditorOpenFolderCommand :: !CommandId
  }
  deriving stock (Eq, Show)

data AppKitControlGalleryTestSpec = AppKitControlGalleryTestSpec
  { testGalleryWindow :: !WindowKey
  , testGalleryRootTab :: !ElementKey
  , testGalleryTextInput :: !ElementKey
  , testGalleryTextMirror :: !ElementKey
  , testGalleryToggle :: !ElementKey
  , testGalleryChoice :: !ElementKey
  , testGalleryNumeric :: !ElementKey
  , testGalleryCollection :: !ElementKey
  , testGalleryDialogButton :: !ElementKey
  , testGalleryDialog :: !ElementKey
  , testGalleryPopoverButton :: !ElementKey
  , testGalleryPopover :: !ElementKey
  , testGalleryContainer :: !ElementKey
  , testGalleryNestedChild :: !ElementKey
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
      spec.testDocumentTab.unTabKey
      spec.testEditorSaveCommand.unCommandId
      spec.testEditorOpenFolderCommand.unCommandId
    pure session

appKitBackendWithControlGalleryTest :: AppKitControlGalleryTestSpec -> Backend
appKitBackendWithControlGalleryTest spec =
  Backend $ \dispatch -> do
    session <- appKitBackend.openBackend dispatch
    c_testScheduleControlGalleryScript
      spec.testGalleryWindow.unWindowKey
      spec.testGalleryRootTab.unElementKey
      spec.testGalleryTextInput.unElementKey
      spec.testGalleryTextMirror.unElementKey
      spec.testGalleryToggle.unElementKey
      spec.testGalleryChoice.unElementKey
      spec.testGalleryNumeric.unElementKey
      spec.testGalleryCollection.unElementKey
      spec.testGalleryDialogButton.unElementKey
      spec.testGalleryDialog.unElementKey
      spec.testGalleryPopoverButton.unElementKey
      spec.testGalleryPopover.unElementKey
      spec.testGalleryContainer.unElementKey
      spec.testGalleryNestedChild.unElementKey
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
