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
import qualified Data.Text as Text
import System.Directory
  ( createDirectory
  , getTemporaryDirectory
  , removeDirectoryRecursive
  , removeFile
  )
import System.FilePath ((</>))
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
  bracket createDirectoryFixture removeDirectoryRecursive testDirectoryRead
  putStrLn "uih-runtime: render/dispatch, file, and lazy directory-effect tests passed"

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
              , backendRequestOpenProjectFolder = pure ()
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
              , backendRequestOpenProjectFolder = pure ()
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

testDirectoryRead :: FilePath -> IO ()
testDirectoryRead path = do
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
              , backendRequestOpenProjectFolder = pure ()
              , backendRun = dispatch (ProjectFolderChosen path)
              , backendStop = pure ()
              , backendShutdown = pure ()
              }
      application =
        App
          { appInitialModel = "Waiting"
          , appView = \title -> AppView [WindowSpec (WindowKey 3) title (Rect 0 0 100 100) []] []
          , appHandleEvent = \event _ ->
              case event of
                ProjectFolderChosen chosen -> requestEffect "Read folder" (ReadDirectory chosen)
                DirectoryRead _ (Right entries) ->
                  transaction "Show entries" NoUndo
                    (const (Text.intercalate "," (fmap (.fileSystemEntryName) entries)))
                DirectoryRead _ (Left message) -> transaction "Show error" NoUndo (const message)
                _ -> noTransaction
          }
  runApp backend application
  actual <- readIORef latestTitle
  if actual == "src,README.md"
    then pure ()
    else error ("uih-runtime: unexpected directory-effect result " <> show actual)

createFixture :: IO FilePath
createFixture = do
  temporaryDirectory <- getTemporaryDirectory
  (path, handle) <- openTempFile temporaryDirectory "uih-runtime.txt"
  hPutStr handle "runtime file effect\n"
  hClose handle
  pure path

createDirectoryFixture :: IO FilePath
createDirectoryFixture = do
  temporaryDirectory <- getTemporaryDirectory
  (path, handle) <- openTempFile temporaryDirectory "uih-runtime-directory"
  hClose handle
  removeFile path
  createDirectory path
  createDirectory (path </> "src")
  writeFile (path </> "README.md") "fixture\n"
  pure path
