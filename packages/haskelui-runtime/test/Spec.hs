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
  , listDirectory
  , removeDirectoryRecursive
  , removeFile
  )
import System.FilePath ((</>))
import System.IO
  ( hClose
  , hPutStr
  , openTempFile
  )
import HaskeLUI.Core
import HaskeLUI.Runtime

main :: IO ()
main = do
  testRenderDispatch
  bracket createFixture removeFile testFileRead
  bracket createDirectoryFixture removeDirectoryRecursive $ \path -> do
    testDirectoryRead path
    testInitialOptionalReadAndAtomicWrite path
  putStrLn "haskelui-runtime: startup, render/dispatch, optional/atomic file, and directory-effect tests passed"

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
          , appInitialEffects = []
          , appView = \open -> AppView [testWindow | open] []
          , appHandleEvent = \event _ ->
              case event of
                CommandInvoked command
                  | command == closeCommand -> transaction "Close" NoUndo (const False)
                _ -> noTransaction
          }

  runApp testBackend testApp
  actual <- readIORef renderCount
  if actual == 2 then pure () else error ("haskelui-runtime: expected two renders, got " <> show actual)
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
          , appInitialEffects = []
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
    else error ("haskelui-runtime: unexpected file-effect result " <> show actual)

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
          , appInitialEffects = []
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
    else error ("haskelui-runtime: unexpected directory-effect result " <> show actual)

testInitialOptionalReadAndAtomicWrite :: FilePath -> IO ()
testInitialOptionalReadAndAtomicWrite directory = do
  latestTitle <- newIORef "Waiting"
  let statePath = directory </> ".vihs"
      effectKey = EffectKey 99
      backend =
        Backend $ \_ ->
          pure
            BackendSession
              { backendRender = \view ->
                  case view.appWindows of
                    window : _ -> writeIORef latestTitle window.windowTitle
                    [] -> pure ()
              , backendRequestOpenTextFiles = pure ()
              , backendRequestOpenProjectFolder = pure ()
              , backendRun = pure ()
              , backendStop = pure ()
              , backendShutdown = pure ()
              }
      application =
        App
          { appInitialModel = "Waiting"
          , appInitialEffects = [ReadOptionalTextFile statePath]
          , appView = \title -> AppView [WindowSpec (WindowKey 4) title (Rect 0 0 100 100) []] []
          , appHandleEvent = \event _ ->
              case event of
                OptionalTextFileRead path (Right Nothing)
                  | path == statePath ->
                      transactionWithEffects
                        "Create state"
                        NoUndo
                        [WriteTextFileAtomically effectKey statePath "atomic state\n"]
                        id
                TextFileWritten key path _ (Right ())
                  | key == effectKey && path == statePath ->
                      transaction "Finish state write" NoUndo (const "Written")
                OptionalTextFileRead _ (Left message) ->
                  transaction "Show optional read error" NoUndo (const message)
                TextFileWritten _ _ _ (Left message) ->
                  transaction "Show atomic write error" NoUndo (const message)
                _ -> noTransaction
          }
  runApp backend application
  title <- readIORef latestTitle
  contents <- readFile statePath
  names <- listDirectory directory
  if title == "Written" && contents == "atomic state\n" && all (not . (".tmp" `Text.isInfixOf`) . Text.pack) names
    then pure ()
    else
      error
        ( "haskelui-runtime: optional/atomic startup effect failed: "
            <> show (title, contents, names)
        )

createFixture :: IO FilePath
createFixture = do
  temporaryDirectory <- getTemporaryDirectory
  (path, handle) <- openTempFile temporaryDirectory "haskelui-runtime.txt"
  hPutStr handle "runtime file effect\n"
  hClose handle
  pure path

createDirectoryFixture :: IO FilePath
createDirectoryFixture = do
  temporaryDirectory <- getTemporaryDirectory
  (path, handle) <- openTempFile temporaryDirectory "haskelui-runtime-directory"
  hClose handle
  removeFile path
  createDirectory path
  createDirectory (path </> "src")
  writeFile (path </> "README.md") "fixture\n"
  pure path
