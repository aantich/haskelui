{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedRecordDot #-}

module HaskeLUI.Backend.AppKit.Testing
  ( AppKitDebugCounters (..)
  , AppKitControlGalleryTestSpec (..)
  , AppKitDrawingTestSpec (..)
  , AppKitExplorerTestSpec (..)
  , AppKitTextEditorTestSpec (..)
  , AppKitVerticalTestSpec (..)
  , appKitBackendWithTextEditorTest
  , appKitBackendWithControlGalleryTest
  , appKitBackendWithDrawingTest
  , appKitBackendWithExplorerTest
  , appKitBackendWithVerticalTest
  , appKitResourcesReleased
  , queryAppKitDebugCounters
  , queryAppKitLastTestFailure
  ) where

import Control.Exception (finally, mask, onException)
import Control.Monad (unless)
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
  , c_testAcquireProcessLock
  , c_testLastFailure
  , c_testReleaseProcessLock
  , c_testScheduleVerticalScript
  , c_testScheduleTextEditorScript
  , c_testScheduleControlGalleryScript
  , c_testScheduleDrawingScript
  , c_testScheduleExplorerScript
  )
import HaskeLUI.Core
  ( CommandId (..)
  , CollectionItemKey (..)
  , ElementKey (..)
  , TabKey (..)
  , WindowKey (..)
  )
import HaskeLUI.Runtime
  ( Backend (..)
  , BackendSession (..)
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

data AppKitExplorerTestSpec = AppKitExplorerTestSpec
  { testExplorerWindow :: !WindowKey
  , testProjectTree :: !ElementKey
  , testProjectFile :: !CollectionItemKey
  , testOpenedFileTab :: !TabKey
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

data AppKitDrawingTestSpec = AppKitDrawingTestSpec
  { testDrawingWindow :: !WindowKey
  , testDrawingSurface :: !ElementKey
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
  serializedAppKitTestBackend $ do
    c_testScheduleVerticalScript
      spec.testMainWindow.unWindowKey
      spec.testNameField.unElementKey
      spec.testGreetingLabel.unElementKey
      spec.testSaveCommand.unCommandId

appKitBackendWithTextEditorTest :: AppKitTextEditorTestSpec -> Backend
appKitBackendWithTextEditorTest spec =
  serializedAppKitTestBackend $ do
    c_testScheduleTextEditorScript
      spec.testDocumentWindow.unWindowKey
      spec.testTextEditor.unElementKey
      spec.testDocumentTab.unTabKey
      spec.testEditorSaveCommand.unCommandId
      spec.testEditorOpenFolderCommand.unCommandId

appKitBackendWithExplorerTest :: AppKitExplorerTestSpec -> Backend
appKitBackendWithExplorerTest spec =
  serializedAppKitTestBackend $ do
    c_testScheduleExplorerScript
      spec.testExplorerWindow.unWindowKey
      spec.testProjectTree.unElementKey
      spec.testProjectFile.unCollectionItemKey
      spec.testOpenedFileTab.unTabKey

appKitBackendWithControlGalleryTest :: AppKitControlGalleryTestSpec -> Backend
appKitBackendWithControlGalleryTest spec =
  serializedAppKitTestBackend $ do
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

appKitBackendWithDrawingTest :: AppKitDrawingTestSpec -> Backend
appKitBackendWithDrawingTest spec =
  serializedAppKitTestBackend $ do
    c_testScheduleDrawingScript
      spec.testDrawingWindow.unWindowKey
      spec.testDrawingSurface.unElementKey

-- Native AppKit scripts activate windows and synthesize input. Separate test
-- executables therefore cannot safely run them concurrently: the OS routes
-- keyboard focus to one foreground application. A process lock keeps Stack's
-- parallel package runner while serializing only these native UI sessions.
serializedAppKitTestBackend :: IO () -> Backend
serializedAppKitTestBackend schedule =
  Backend $ \dispatch ->
    mask $ \restore -> do
      acquired <- restore c_testAcquireProcessLock
      unless (acquired /= 0) $
        error "HaskeLUI AppKit test backend could not acquire its native UI lock"
      session <-
        restore (appKitBackend.openBackend dispatch)
          `onException` c_testReleaseProcessLock
      restore schedule
        `onException` (session.backendShutdown `finally` c_testReleaseProcessLock)
      pure
        session
          { backendShutdown =
              session.backendShutdown `finally` c_testReleaseProcessLock
          }

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
