{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Control.Exception (bracket)
import Control.Monad (unless)
import HaskeLUI.Backend.AppKit.Testing
  ( AppKitDebugCounters (..)
  , AppKitExplorerTestSpec (..)
  , appKitBackendWithExplorerTest
  , appKitResourcesReleased
  , queryAppKitDebugCounters
  , queryAppKitLastTestFailure
  )
import HaskeLUI.Core
  ( App (..)
  , CollectionItemKey (..)
  , FileSystemEntry (..)
  , FileSystemEntryKind (..)
  , TabKey (..)
  , UIEvent (..)
  , applyTransaction
  )
import HaskeLUI.Runtime (runApp)
import System.Directory
  ( createDirectory
  , getTemporaryDirectory
  , removeFile
  , removePathForcibly
  )
import System.FilePath ((</>))
import System.IO (hClose, openTempFile)
import VisualHaskell
  ( application
  , applicationWithEnvironment
  , projectTreeKey
  , workspaceWindowKey
  )
import VisualHaskell.TextMate (defaultTextMateConfiguration)

main :: IO ()
main =
  bracket createFixture (removePathForcibly . fixtureDirectory) $ \fixture -> do
    configuration <- defaultTextMateConfiguration fixture.visualHaskellHome
    let reducer = application
        projectOpening =
          applyTransaction
            (reducer.appHandleEvent (ProjectFolderChosen fixture.projectRoot) reducer.appInitialModel)
            reducer.appInitialModel
        projectLoaded =
          applyTransaction
            ( reducer.appHandleEvent
                ( DirectoryRead
                    fixture.projectRoot
                    ( Right
                        [ FileSystemEntry
                            fixture.markdownPath
                            "README.md"
                            FileSystemFile
                        ]
                    )
                )
                projectOpening
            )
            projectOpening
        projectReady =
          applyTransaction
            ( reducer.appHandleEvent
                ( OptionalTextFileRead
                    (fixture.projectRoot </> ".vihs")
                    ( Right
                        ( Just
                            "{\"format\":\"visual-haskell-workspace\",\"version\":1,\"openFiles\":[],\"expandedFolders\":[\".\"],\"selectedExplorerEntry\":\"README.md\"}"
                        )
                    )
                )
                projectLoaded
            )
            projectLoaded
        production = applicationWithEnvironment fixture.lastWorkspacePath configuration
        testApplication =
          production
            { appInitialModel = projectReady
            , appInitialEffects = []
            , appServices = []
            , appSubscriptions = const []
            }
        testSpec =
          AppKitExplorerTestSpec
            { testExplorerWindow = workspaceWindowKey
            , testProjectTree = projectTreeKey
            , testProjectFile = CollectionItemKey 2
            , testOpenedFileTab = TabKey 1000
            }
    runApp (appKitBackendWithExplorerTest testSpec) testApplication
    counters <- queryAppKitDebugCounters
    lastFailure <- queryAppKitLastTestFailure
    unless (counters.debugTestFailures == 0) $
      error ("native explorer validation failed: " <> show lastFailure)
    unless (appKitResourcesReleased counters) $
      error ("native explorer resources survived shutdown: " <> show counters)
    putStrLn ("Visual Haskell native project-file activation passed: " <> show counters)

data Fixture = Fixture
  { fixtureDirectory :: !FilePath
  , projectRoot :: !FilePath
  , markdownPath :: !FilePath
  , visualHaskellHome :: !FilePath
  , lastWorkspacePath :: !FilePath
  }

createFixture :: IO Fixture
createFixture = do
  temporaryDirectory <- getTemporaryDirectory
  (directory, handle) <- openTempFile temporaryDirectory "vh-explorer-native"
  hClose handle
  removeFile directory
  createDirectory directory
  let root = directory </> "project"
      markdown = root </> "README.md"
      home = directory </> "home"
  createDirectory root
  createDirectory home
  writeFile markdown "# Native explorer fixture\n"
  pure
    Fixture
      { fixtureDirectory = directory
      , projectRoot = root
      , markdownPath = markdown
      , visualHaskellHome = home
      , lastWorkspacePath = home </> "last-workspace"
      }
