{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.STM
  ( atomically
  , newTQueueIO
  , readTQueue
  , writeTQueue
  )
import Control.Exception (bracket)
import Control.Monad (void)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import qualified Data.Text as Text
import HaskeLUI.Core
import HaskeLUI.Runtime
import System.Directory
  ( createDirectory
  , getTemporaryDirectory
  , removeFile
  , removePathForcibly
  )
import System.FilePath ((</>))
import System.IO (hClose, openTempFile)
import VisualHaskell
  ( applicationWithEnvironment
  , firstDocumentEditorKey
  )
import VisualHaskell.TextMate (defaultTextMateConfiguration)

main :: IO ()
main =
  bracket createFixture removePathForcibly $ \fixture -> do
    configuration <- defaultTextMateConfiguration (fixture </> "home")
    let workspaceRoot = fixture </> "workspace"
        sourcePath = workspaceRoot </> "src" </> "Fixture.hs"
        applicationValue =
          applicationWithEnvironment (fixture </> "last-workspace") configuration
    latestView <- newIORef (applicationValue.appView applicationValue.appInitialModel)
    runApp
      ( scriptedBackend latestView $ \dispatch -> do
          -- Reproduce the production ordering where the worker handshake may
          -- finish before the user trusts/opens a workspace.
          threadDelay 500000
          dispatch (ProjectFolderChosen workspaceRoot)
          dispatch (TextFileRead sourcePath (Right sourceText))
          analyzed <- waitForCompilerAnalysis latestView 150
          if analyzed
            then do
              dispatch (TextChanged firstDocumentEditorKey brokenSourceText)
              problem <- waitForCompilerProblem latestView 150
              case problem of
                Just (listKey, itemKey) -> do
                  dispatch (CollectionSelectionChanged listKey [itemKey])
                  navigated <- waitForProblemNavigation latestView 50
                  if navigated
                    then dispatch (WindowCloseRequested (WindowKey 10))
                    else error "Visual Haskell did not reveal the selected compiler problem"
                Nothing -> error "Visual Haskell did not render the current compiler problem"
            else do
              currentView <- readIORef latestView
              error
                ( "Visual Haskell did not accept a current direct-GHC result; labels: "
                    <> show (labelTexts currentView)
                )
      )
      applicationValue
    putStrLn "Visual Haskell typed service accepted a current direct-GHC result"
  where
    sourceText = "module Fixture where\nvalue :: Int\nvalue = 42\n"
    brokenSourceText = "module Fixture where\nvalue :: Int\nvalue = missingName\n"

waitForCompilerAnalysis :: IORef AppView -> Int -> IO Bool
waitForCompilerAnalysis _ 0 = pure False
waitForCompilerAnalysis latestView attempts = do
  view <- readIORef latestView
  if any (Text.isInfixOf "GHC: clean") (labelTexts view)
    then pure True
    else threadDelay 100000 >> waitForCompilerAnalysis latestView (attempts - 1)

waitForCompilerProblem :: IORef AppView -> Int -> IO (Maybe (ElementKey, CollectionItemKey))
waitForCompilerProblem _ 0 = pure Nothing
waitForCompilerProblem latestView attempts = do
  view <- readIORef latestView
  case
      [ (collection.collectionControlKey, item.collectionItemKey)
      | window <- view.appWindows
      , ListView collection <- windowLeafControls window
      , item <- collection.collectionControlItems
      ] of
    problem : _
      | hasDiagnosticUnderline view -> pure (Just problem)
    _ -> threadDelay 100000 >> waitForCompilerProblem latestView (attempts - 1)

waitForProblemNavigation :: IORef AppView -> Int -> IO Bool
waitForProblemNavigation _ 0 = pure False
waitForProblemNavigation latestView attempts = do
  view <- readIORef latestView
  if
      or
        [ editor.textEditorNavigation /= Nothing
        | window <- view.appWindows
        , TextEditor editor <- windowLeafControls window
        ]
    then pure True
    else threadDelay 100000 >> waitForProblemNavigation latestView (attempts - 1)

hasDiagnosticUnderline :: AppView -> Bool
hasDiagnosticUnderline view =
  or
    [ spanValue.textSpanValue.textUnderline /= Nothing
        && spanValue.textSpanValue.textUnderlineColor /= Nothing
    | window <- view.appWindows
    , TextEditor editor <- windowLeafControls window
    , layer <- editor.textEditorLayers
    , spanValue <- layer.textLayerSpans
    ]

labelTexts :: AppView -> [Text.Text]
labelTexts view =
  [ contents
  | window <- view.appWindows
  , Label _ _ contents <- windowLeafControls window
  ]

scriptedBackend
  :: IORef AppView
  -> ((UIEvent -> IO ()) -> IO ())
  -> Backend
scriptedBackend latestView script =
  Backend $ \dispatch -> do
    uiQueue <- newTQueueIO
    let schedule action = atomically (writeTQueue uiQueue (Just action))
        stop = atomically (writeTQueue uiQueue Nothing)
        runUI = do
          next <- atomically (readTQueue uiQueue)
          maybe (pure ()) (\action -> action >> runUI) next
    void (forkIO runUI)
    pure
      BackendSession
        { backendRender = writeIORef latestView
        , backendScheduleOnUI = schedule
        , backendRequestOpenTextFiles = pure ()
        , backendRequestOpenProjectFolder = pure ()
        , backendRun = script dispatch
        , backendStop = stop
        , backendShutdown = pure ()
        }

createFixture :: IO FilePath
createFixture = do
  temporary <- getTemporaryDirectory
  (fixture, handle) <- openTempFile temporary "visual-haskell-analysis-service-"
  hClose handle
  removeFile fixture
  createDirectory fixture
  createDirectory (fixture </> "home")
  createDirectory (fixture </> "workspace")
  createDirectory (fixture </> "workspace" </> "src")
  writeFile (fixture </> "workspace" </> "src" </> "Fixture.hs") sourceText
  writeFile
    (fixture </> "workspace" </> "hie.yaml")
    "cradle:\n  direct:\n    arguments:\n      - -isrc\n      - src/Fixture.hs\n"
  pure fixture
  where
    sourceText = "module Fixture where\nvalue :: Int\nvalue = 42\n"
