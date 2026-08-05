{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Data.IORef
  ( modifyIORef'
  , newIORef
  , readIORef
  )
import UIH.Core
import UIH.Runtime

main :: IO ()
main = do
  renderCount <- newIORef (0 :: Int)
  let closeCommand = CommandId 1
      testBackend =
        Backend $ \dispatch ->
          pure
            BackendSession
              { backendRender = const (modifyIORef' renderCount (+ 1))
              , backendRun = dispatch (CommandInvoked closeCommand)
              , backendStop = pure ()
              , backendShutdown = pure ()
              }
      testApp =
        App
          { appInitialModel = True
          , appView = \open -> AppView [testWindow | open] []
          , appHandleEvent = \event _ ->
              case event of
                CommandInvoked command
                  | command == closeCommand -> transaction "Close" NoUndo (const False)
                _ -> noTransaction
          }

  runApp testBackend testApp
  actual <- readIORef renderCount
  if actual == 2
    then putStrLn "uih-runtime: render/dispatch smoke test passed"
    else error ("uih-runtime: expected two renders, got " <> show actual)
  where
    testWindow = WindowSpec (WindowKey 1) "Test" (Rect 0 0 100 100) []
