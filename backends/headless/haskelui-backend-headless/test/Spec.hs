{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE OverloadedRecordDot #-}

module Main (main) where

import HaskeLUI.Backend.Headless (newHeadlessBackend)
import HaskeLUI.Core
import HaskeLUI.Runtime (runApp)

main :: IO ()
main = do
  (backend, latestView) <- newHeadlessBackend
  runApp backend application
  rendered <- latestView
  case rendered of
    Just (AppView [window] [])
      | window.windowKey == WindowKey 1 ->
          pure ()
    _ -> error "haskelui-backend-headless: unexpected rendered view"
  (workspaceBackend, latestWorkspace) <- newHeadlessBackend
  runApp workspaceBackend workspaceApplication
  workspaceRendered <- latestWorkspace
  case workspaceRendered of
    Just (AppView [window] [])
      | window.windowKey == WindowKey 2
      , Just spec <- windowWorkspace window
      , workspaceTabKeys spec == [TabKey 1] ->
          putStrLn "haskelui-backend-headless: flat and workspace render tests passed"
    _ -> error "haskelui-backend-headless: unexpected workspace view"
  where
    application =
      App
        { appInitialModel = ()
        , appInitialEffects = []
        , appInitialCommands = []
        , appServices = []
        , appSubscriptions = const []
        , appView = const (AppView [WindowSpec (WindowKey 1) "Headless" (Rect 0 0 100 100) []] [])
        , appHandleEvent = \_ _ -> noTransaction
        }
    workspaceApplication =
      App
        { appInitialModel = ()
        , appInitialEffects = []
        , appInitialCommands = []
        , appServices = []
        , appSubscriptions = const []
        , appView = const (AppView [workspaceWindow] [])
        , appHandleEvent = \_ _ -> noTransaction
        }
    workspaceWindow =
      WorkspaceWindowSpec
        (WindowKey 2)
        "Workspace"
        (Rect 0 0 800 600)
        ( WorkspaceSpec
            ( WorkspaceSplit
                (SplitKey 1)
                SideBySide
                (WorkspacePane sidebar)
                (WorkspacePane content)
                []
            )
            [Label (ElementKey 3) (Rect 0 0 200 20) "Ready"]
        )
    sidebar =
      WorkspacePaneSpec
        (PaneKey 1)
        SidebarPane
        (PaneSizing Nothing (Just 200) Nothing 0)
        (PaneState PaneVisible Nothing)
        (WorkspaceItemSpec (WorkspaceItemKey 1) (WorkspaceItemControls []))
    content =
      WorkspacePaneSpec
        (PaneKey 2)
        ContentPane
        (PaneSizing Nothing Nothing Nothing 1)
        (PaneState PaneVisible Nothing)
        ( WorkspaceItemSpec
            (WorkspaceItemKey 2)
            ( WorkspaceItemTabGroup
                ( WorkspaceTabGroupSpec
                    (TabGroupKey 1)
                    (Just (TabKey 1))
                    [ WorkspaceTabSpec
                        (TabKey 1)
                        (Just (DocumentKey 1))
                        "Document"
                        False
                        True
                        []
                    ]
                )
            )
        )
