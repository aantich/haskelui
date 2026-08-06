module HaskeLUI.Backend.Headless
  ( newHeadlessBackend
  ) where

import Data.IORef
  ( newIORef
  , readIORef
  , writeIORef
  )
import HaskeLUI.Core (AppView)
import HaskeLUI.Runtime
  ( Backend (..)
  , BackendSession (..)
  )

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
