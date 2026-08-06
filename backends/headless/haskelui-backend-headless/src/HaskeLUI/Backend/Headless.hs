{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedRecordDot #-}

module HaskeLUI.Backend.Headless
  ( CapturedDrawingSurface (..)
  , captureDrawingSurfaces
  , newHeadlessBackend
  ) where

import Data.IORef
  ( newIORef
  , readIORef
  , writeIORef
  )
import HaskeLUI.Core
  ( AppView (..)
  , Control (..)
  , DrawingCommand
  , DrawingRevision
  , DrawingSurfaceSpec (..)
  , ElementKey
  , Rect
  , compileDrawing
  , windowLeafControls
  )
import HaskeLUI.Runtime
  ( Backend (..)
  , BackendSession (..)
  )

data CapturedDrawingSurface = CapturedDrawingSurface
  { capturedDrawingSurfaceKey :: !ElementKey
  , capturedDrawingSurfaceFrame :: !Rect
  , capturedDrawingSurfaceRevision :: !DrawingRevision
  , capturedDrawingCommands :: ![DrawingCommand]
  }
  deriving stock (Eq, Show)

-- | Produce the same normalized display lists consumed by native backends.
-- This intentionally performs no rasterization, keeping headless tests exact
-- and independent of platform font or antialiasing behavior.
captureDrawingSurfaces :: AppView -> [CapturedDrawingSurface]
captureDrawingSurfaces view =
  [ CapturedDrawingSurface
      surface.drawingSurfaceKey
      surface.drawingSurfaceFrame
      surface.drawingSurfaceRevision
      (compileDrawing surface.drawingSurfaceDrawing)
  | window <- view.appWindows
  , DrawingSurface surface <- windowLeafControls window
  ]

newHeadlessBackend :: IO (Backend, IO (Maybe AppView))
newHeadlessBackend = do
  latestView <- newIORef Nothing
  let backend =
        Backend $ \_ ->
          pure
            BackendSession
              { backendRender = writeIORef latestView . Just
              , backendScheduleOnUI = id
              , backendRequestOpenTextFiles = pure ()
              , backendRequestOpenProjectFolder = pure ()
              , backendRun = pure ()
              , backendStop = pure ()
              , backendShutdown = pure ()
              }
  pure (backend, readIORef latestView)
