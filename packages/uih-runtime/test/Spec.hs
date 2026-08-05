{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Control.Exception (bracket)
import Data.IORef
  ( modifyIORef'
  , newIORef
  , readIORef
  , writeIORef
  )
import System.Directory
  ( getTemporaryDirectory
  , removeFile
  )
import System.IO
  ( hClose
  , hPutStr
  , openTempFile
  )
import UIH.Core
import UIH.Runtime

main :: IO ()
main = do
  testRenderDispatch
  bracket createFixture removeFile testFileRead
  putStrLn "uih-runtime: render/dispatch and UTF-8 file-effect tests passed"

testRenderDispatch :: IO ()
testRenderDispatch = do
  renderCount <- newIORef (0 :: Int)
  let closeCommand = CommandId 1
      testBackend =
        Backend $ \dispatch ->
          pure
            BackendSession
              { backendRender = const (modifyIORef' renderCount (+ 1))
              , backendRequestOpenTextFiles = pure ()
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
  if actual == 2 then pure () else error ("uih-runtime: expected two renders, got " <> show actual)
  where
    testWindow = WindowSpec (WindowKey 1) "Test" (Rect 0 0 100 100) []

testFileRead :: FilePath -> IO ()
testFileRead path = do
  latestTitle <- newIORef ""
  let backend =
        Backend $ \dispatch ->
          pure
            BackendSession
              { backendRender = \view ->
                  case view.appWindows of
                    window : _ -> writeIORef latestTitle window.windowTitle
                    [] -> pure ()
              , backendRequestOpenTextFiles = pure ()
              , backendRun = dispatch (TextFileChosen path)
              , backendStop = pure ()
              , backendShutdown = pure ()
              }
      application =
        App
          { appInitialModel = Nothing
          , appView = \contents ->
              AppView
                [WindowSpec (WindowKey 2) (maybe "Waiting" id contents) (Rect 0 0 100 100) []]
                []
          , appHandleEvent = \event _ ->
              case event of
                TextFileChosen chosen -> requestEffect "Read fixture" (ReadTextFile chosen)
                TextFileRead _ (Right contents) -> transaction "Store fixture" NoUndo (const (Just contents))
                TextFileRead _ (Left message) -> transaction "Store read error" NoUndo (const (Just message))
                _ -> noTransaction
          }
  runApp backend application
  actual <- readIORef latestTitle
  if actual == "runtime file effect\n"
    then pure ()
    else error ("uih-runtime: unexpected file-effect result " <> show actual)

createFixture :: IO FilePath
createFixture = do
  temporaryDirectory <- getTemporaryDirectory
  (path, handle) <- openTempFile temporaryDirectory "uih-runtime.txt"
  hPutStr handle "runtime file effect\n"
  hClose handle
  pure path
