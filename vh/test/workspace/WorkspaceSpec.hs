{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Control.Concurrent (threadDelay)
import Control.Exception (bracket)
import Data.IORef
  ( IORef
  , newIORef
  , readIORef
  , writeIORef
  )
import qualified Data.Text as Text
import VisualHaskell
  ( applicationWithEnvironment
  , applicationWithWorkspaceRegistry
  , firstDocumentTabKey
  , projectTreeKey
  )
import VisualHaskell.WorkspaceState
  ( WorkspaceState (..)
  , decodeWorkspaceState
  )
import VisualHaskell.Paths
  ( ensureVisualHaskellPaths
  , resolveVisualHaskellPaths
  , visualHaskellExtensionDirectory
  , visualHaskellGrammarDirectory
  , visualHaskellHome
  , visualHaskellSettingsPath
  , visualHaskellThemeDirectory
  )
import VisualHaskell.TextMate
  ( defaultTextMateConfiguration
  , textMateSyntaxLayerKey
  )
import System.Directory
  ( createDirectory
  , doesDirectoryExist
  , doesFileExist
  , getTemporaryDirectory
  , listDirectory
  , removeDirectoryRecursive
  , removeFile
  )
import System.Environment (lookupEnv, setEnv, unsetEnv)
import System.FilePath ((</>))
import System.IO
  ( hClose
  , openTempFile
  )
import HaskeLUI.Core
import HaskeLUI.Runtime

main :: IO ()
main =
  bracket createFixture removeDirectoryRecursive $ \fixtureRoot -> do
    let providerHome = fixtureRoot </> "portable-vh-home"
    testVisualHaskellHome providerHome
    testProductionTextMateIntegration fixtureRoot providerHome
    let workspaceRoot = fixtureRoot </> "workspace"
        registryPath = fixtureRoot </> "state" </> "last-workspace"
        mainPath = workspaceRoot </> "src" </> "Main.hs"
        readmePath = workspaceRoot </> "README.md"
        firstApplication = applicationWithWorkspaceRegistry registryPath
    firstView <- newIORef (firstApplication.appView firstApplication.appInitialModel)
    runApp
      ( scriptedBackend firstView $ \dispatch -> do
          dispatch (ProjectFolderChosen workspaceRoot)
          dispatch (TextFileChosen mainPath)
          dispatch (TextFileChosen readmePath)
          dispatch (TabSelected firstDocumentTabKey)
          dispatch (CollectionExpansionChanged projectTreeKey (CollectionItemKey 2) True)
          dispatch (PaneStateChanged (PaneKey 10) (PaneState PaneVisible (Just 252)))
          dispatch (PaneStateChanged (PaneKey 12) (PaneState PaneCollapsed (Just 318)))
          dispatch (WindowCloseRequested (WindowKey 10))
      )
      firstApplication

    registryContents <- readFile registryPath
    workspaceContents <- readFile (workspaceRoot </> ".vihs")
    workspaceNames <- listDirectory workspaceRoot
    assertEqual "last workspace locator" (workspaceRoot <> "\n") registryContents
    assert "atomic workspace write left no temporary sibling" $
      all (not . Text.isInfixOf ".tmp" . Text.pack) workspaceNames
    savedState <-
      case decodeWorkspaceState (Text.pack workspaceContents) of
        Left message -> error ("saved .vihs did not decode: " <> Text.unpack message)
        Right state -> pure state
    assertEqual "saved tab order" ["src/Main.hs", "README.md"] savedState.workspaceOpenFiles
    assertEqual "saved active document" (Just "src/Main.hs") savedState.workspaceActiveFile
    assertEqual "saved expanded folders" [".", "src"] savedState.workspaceExpandedFolders
    assertEqual
      "saved pane state"
      (PaneState PaneVisible (Just 252), PaneState PaneCollapsed (Just 318))
      (savedState.workspaceNavigatorPane, savedState.workspaceInspectorPane)

    let secondApplication = applicationWithWorkspaceRegistry registryPath
    secondView <- newIORef (secondApplication.appView secondApplication.appInitialModel)
    runApp (scriptedBackend secondView (const (pure ()))) secondApplication
    restoredView <- readIORef secondView
    assertEqual "restored tab order" ["Main.hs", "README.md"] (tabTitles restoredView)
    assertEqual "restored active tab" (Just firstDocumentTabKey) (selectedTab restoredView)
    assertEqual
      "restored pane state"
      [PaneState PaneVisible (Just 252), PaneState PaneCollapsed (Just 318)]
      (sidebarAndInspectorStates restoredView)
    assert "restored source folder is expanded" $
      any
        ( \item ->
            item.collectionItemLabel == "src" && item.collectionItemExpanded
        )
        (projectItems restoredView)
    assert "workspace metadata stays hidden from the project tree" $
      all ((/= ".vihs") . (.collectionItemLabel)) (projectItems restoredView)
    putStrLn "Visual Haskell workspace survives a complete runtime restart"

testProductionTextMateIntegration :: FilePath -> FilePath -> IO ()
testProductionTextMateIntegration fixtureRoot providerHome = do
  configuration <- defaultTextMateConfiguration providerHome
  let sourcePath = fixtureRoot </> "workspace" </> "src" </> "Main.hs"
      registryPath = fixtureRoot </> "state" </> "textmate-last-workspace"
      applicationValue = applicationWithEnvironment registryPath configuration
  latestView <- newIORef (applicationValue.appView applicationValue.appInitialModel)
  runApp
    ( scriptedBackend latestView $ \dispatch -> do
        dispatch (TextFileRead sourcePath (Right "module Main where\nvalue = 42\n"))
        highlighted <- waitForTextMateLayer latestView (ElementKey 1001000) 80
        assert "production runtime applies the asynchronous TextMate layer" highlighted
        let customGrammarPath = providerHome </> "grammars" </> "custom.tmLanguage.json"
            customSourcePath = fixtureRoot </> "Sample.foo"
        writeFile customGrammarPath customGrammar
        threadDelay 1500000
        dispatch (TextFileRead customSourcePath (Right "special ordinary\n"))
        reloaded <- waitForTextMateLayer latestView (ElementKey 1001001) 80
        assert "copying a user grammar triggers discovery and live reload" reloaded
        dispatch (WindowCloseRequested (WindowKey 10))
    )
    applicationValue
  where
    waitForTextMateLayer :: IORef AppView -> ElementKey -> Int -> IO Bool
    waitForTextMateLayer _ _ 0 = pure False
    waitForTextMateLayer latestView editorKey attempts = do
      view <- readIORef latestView
      if any
          (\(key, layer) -> key == editorKey && layer.textLayerKey == textMateSyntaxLayerKey)
          (editorLayers view)
        then pure True
        else threadDelay 50000 >> waitForTextMateLayer latestView editorKey (attempts - 1)

    editorLayers :: AppView -> [(ElementKey, TextLayer)]
    editorLayers view =
      [ (editor.textEditorKey, layer)
      | window <- view.appWindows
      , TextEditor editor <- windowLeafControls window
      , layer <- editor.textEditorLayers
      ]

    customGrammar =
      unlines
        [ "{"
        , "  \"name\": \"Custom fixture\","
        , "  \"scopeName\": \"source.custom\","
        , "  \"fileTypes\": [\"foo\"],"
        , "  \"patterns\": ["
        , "    { \"name\": \"keyword.control.custom\", \"match\": \"\\\\bspecial\\\\b\" }"
        , "  ]"
        , "}"
        ]

testVisualHaskellHome :: FilePath -> IO ()
testVisualHaskellHome requestedHome =
  bracket (lookupEnv "VH_HOME") restoreEnvironment $ \_ -> do
    setEnv "VH_HOME" requestedHome
    paths <- resolveVisualHaskellPaths
    ensureVisualHaskellPaths paths
    assertEqual "VH_HOME override is normalized" requestedHome paths.visualHaskellHome
    created <-
      traverse
        doesDirectoryExist
        [ paths.visualHaskellExtensionDirectory
        , paths.visualHaskellGrammarDirectory
        , paths.visualHaskellThemeDirectory
        ]
    assert "Visual Haskell creates all user provider directories" (and created)
    settingsExists <- doesFileExist paths.visualHaskellSettingsPath
    assert "an absent settings file continues to mean defaults" (not settingsExists)
  where
    restoreEnvironment Nothing = unsetEnv "VH_HOME"
    restoreEnvironment (Just previous) = setEnv "VH_HOME" previous

scriptedBackend
  :: IORef AppView
  -> ((UIEvent -> IO ()) -> IO ())
  -> Backend
scriptedBackend latestView script =
  Backend $ \dispatch ->
    pure
      BackendSession
        { backendRender = writeIORef latestView
        , backendScheduleOnUI = id
        , backendRequestOpenTextFiles = pure ()
        , backendRequestOpenProjectFolder = pure ()
        , backendRun = script dispatch
        , backendStop = pure ()
        , backendShutdown = pure ()
        }

tabTitles :: AppView -> [Text.Text]
tabTitles view =
  [ tab.workspaceTabTitle
  | pane <- viewPanes view
  , WorkspaceItemTabGroup group <- [pane.workspacePaneItem.workspaceItemContent]
  , tab <- group.workspaceTabs
  ]

selectedTab :: AppView -> Maybe TabKey
selectedTab view =
  case
      [ selected
      | pane <- viewPanes view
      , WorkspaceItemTabGroup group <- [pane.workspacePaneItem.workspaceItemContent]
      , selected <- maybe [] pure group.workspaceSelectedTab
      ] of
    selected : _ -> Just selected
    [] -> Nothing

sidebarAndInspectorStates :: AppView -> [PaneState]
sidebarAndInspectorStates view =
  [ pane.workspacePaneState
  | pane <- viewPanes view
  , pane.workspacePaneRole `elem` [SidebarPane, InspectorPane]
  ]

projectItems :: AppView -> [CollectionItem]
projectItems view =
  [ item
  | window <- view.appWindows
  , TreeView collection <- windowLeafControls window
  , collection.collectionControlKey == projectTreeKey
  , item <- collection.collectionControlItems
  ]

viewPanes :: AppView -> [WorkspacePaneSpec]
viewPanes view =
  [ pane
  | window <- view.appWindows
  , workspace <- maybe [] pure (windowWorkspace window)
  , pane <- paneSpecs workspace.workspaceRoot
  ]

paneSpecs :: PaneTree -> [WorkspacePaneSpec]
paneSpecs (WorkspacePane pane) = [pane]
paneSpecs (WorkspaceSplit _ _ first second rest) =
  concatMap paneSpecs (first : second : rest)

createFixture :: IO FilePath
createFixture = do
  temporaryDirectory <- getTemporaryDirectory
  (fixtureRoot, handle) <- openTempFile temporaryDirectory "visual-haskell-workspace"
  hClose handle
  removeFile fixtureRoot
  createDirectory fixtureRoot
  createDirectory (fixtureRoot </> "workspace")
  createDirectory (fixtureRoot </> "workspace" </> "src")
  createDirectory (fixtureRoot </> "state")
  writeFile (fixtureRoot </> "workspace" </> "src" </> "Main.hs") "module Main where\n"
  writeFile (fixtureRoot </> "workspace" </> "README.md") "# Workspace\n"
  pure fixtureRoot

assert :: String -> Bool -> IO ()
assert label condition =
  if condition then pure () else error (label <> " failed")

assertEqual :: (Eq value, Show value) => String -> value -> value -> IO ()
assertEqual label expected actual =
  if expected == actual
    then pure ()
    else error (label <> ": expected " <> show expected <> ", got " <> show actual)
