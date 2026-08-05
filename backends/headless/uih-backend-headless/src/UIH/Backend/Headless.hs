module UIH.Backend.Headless
  ( newHeadlessBackend
  ) where

import Data.IORef
  ( newIORef
  , readIORef
  , writeIORef
  )
import UIH.Core (AppView)
import UIH.Runtime
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
              , backendRequestOpenTextFiles = pure ()
              , backendRun = pure ()
              , backendStop = pure ()
              , backendShutdown = pure ()
              }
  pure (backend, readIORef latestView)
