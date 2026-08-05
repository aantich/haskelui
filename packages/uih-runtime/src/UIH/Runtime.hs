{-# LANGUAGE OverloadedRecordDot #-}

module UIH.Runtime
  ( Backend (..)
  , BackendSession (..)
  , runApp
  ) where

import Control.Exception (finally)
import Control.Monad (when)
import Data.IORef
  ( newIORef
  , readIORef
  , writeIORef
  )
import UIH.Core
  ( App (..)
  , AppView (..)
  , UIEvent
  , applyTransaction
  )

newtype Backend = Backend
  { openBackend :: (UIEvent -> IO ()) -> IO BackendSession
  }

data BackendSession = BackendSession
  { backendRender :: AppView -> IO ()
  , backendRun :: IO ()
  , backendStop :: IO ()
  , backendShutdown :: IO ()
  }

runApp :: Backend -> App model -> IO ()
runApp backend application = do
  modelReference <- newIORef application.appInitialModel
  sessionReference <- newIORef Nothing
  session <- openBackend backend (dispatch modelReference sessionReference)
  writeIORef sessionReference (Just session)
  backendRender session (application.appView application.appInitialModel)
  backendRun session `finally` backendShutdown session
  where
    dispatch modelReference sessionReference event = do
      model <- readIORef modelReference
      let updated = applyTransaction (application.appHandleEvent event model) model
          desired = application.appView updated
      writeIORef modelReference updated
      maybeSession <- readIORef sessionReference
      case maybeSession of
        Nothing -> pure ()
        Just session -> do
          backendRender session desired
          when (null desired.appWindows) (backendStop session)
