{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Example.TextEditor
  ( application
  , firstDocumentEditorKey
  , firstDocumentTabKey
  , firstDocumentWindowKey
  , openCommand
  , saveCommand
  )
import Example.TextEditor.Highlighting
  ( SyntaxClass (..)
  , highlightHaskell
  )
import qualified Data.Text as Text
import UIH.Core

main :: IO ()
main = do
  let highlighted = highlightHaskell "😀 module Main where\nvalue = \"hi\" -- note\n"
  assert
    "pure highlighter uses Unicode scalar ranges"
    ( TextSpan (TextRange 2 6) SyntaxKeyword `elem` highlighted
        && TextSpan (TextRange 9 4) SyntaxTypeName `elem` highlighted
        && TextSpan (TextRange 28 4) SyntaxString `elem` highlighted
        && TextSpan (TextRange 33 7) SyntaxComment `elem` highlighted
    )

  let initial = application.appInitialModel
      initialView = application.appView initial
      openRequest = application.appHandleEvent (CommandInvoked openCommand) initial
  assertEqual "Open command effect" [RequestOpenTextFiles] openRequest.transactionEffects
  assert "editor starts with one workspace window" (length initialView.appWindows == 1)
  assert "empty workspace validates" (all (null . validateWindowWorkspace) initialView.appWindows)

  let opened = applyEvent (TextFileRead "/tmp/example.hs" (Right "module Old where\n")) initial
      openedTwice = applyEvent (TextFileRead "/tmp/notes.txt" (Right "notes\n")) opened
      twiceView = application.appView openedTwice
  assert "two reads stay in one workspace window" (length twiceView.appWindows == 1)
  assertEqual "two document tabs" [TabKey 1000, TabKey 1001] (concatMap windowTabKeys twiceView.appWindows)
  assert "workspace exposes a shared status area" $
    case twiceView.appWindows of
      [window] -> maybe False (not . null . workspaceStatusControls) (windowWorkspace window)
      _ -> False

  let selectedFirst = applyEvent (TabSelected firstDocumentTabKey) openedTwice
      edited = applyEvent (TextChanged firstDocumentEditorKey "module New where\n") selectedFirst
      editedView = application.appView edited
  assert "edited active tab updates shared window title" (any windowIsEdited editedView.appWindows)
  assert "Save enabled for selected edited document" (isCommandEnabled saveCommand editedView.appCommands)
  assert "Haskell document receives a generic syntax presentation layer" $
    case textEditorSpecs editedView.appWindows of
      editor : _ ->
        editor.textEditorRevision == TextRevision 1
          && case editor.textEditorLayers of
            [layer] ->
              layer.textLayerRevision == editor.textEditorRevision
                && not (null layer.textLayerSpans)
            _ -> False
      [] -> False

  let saveRequest = application.appHandleEvent (CommandInvoked saveCommand) edited
  assertEqual
    "Save command effect"
    [WriteTextFile (EffectKey 1000) "/tmp/example.hs" "module New where\n"]
    saveRequest.transactionEffects

  let saving = applyTransaction saveRequest edited
      saved =
        applyEvent
          (TextFileWritten (EffectKey 1000) "/tmp/example.hs" "module New where\n" (Right ()))
          saving
      savedView = application.appView saved
  assert "saved workspace title" (not (any windowIsEdited savedView.appWindows))
  assert "Save disabled after successful write" (not (isCommandEnabled saveCommand savedView.appCommands))

  let closedCleanly = applyEvent (TabCloseRequested firstDocumentTabKey) saved
      cleanCloseView = application.appView closedCleanly
  assert "clean tab close removes only that tab" $
    not (firstDocumentTabKey `elem` concatMap windowTabKeys cleanCloseView.appWindows)
      && length cleanCloseView.appWindows == 1

  let reopened = applyEvent (TextFileRead "/tmp/example.hs" (Right "module Old where\n")) initial
      dirtyAgain = applyEvent (TextChanged firstDocumentEditorKey "changed again") reopened
      closeDeferred = applyEvent (TabCloseRequested firstDocumentTabKey) dirtyAgain
  assert "dirty tab close is vetoed" $
    firstDocumentTabKey `elem` concatMap windowTabKeys (application.appView closeDeferred).appWindows

  let closeSaveRequest = application.appHandleEvent (CommandInvoked saveCommand) closeDeferred
      closeSaving = applyTransaction closeSaveRequest closeDeferred
      closed =
        applyEvent
          (TextFileWritten (EffectKey 1000) "/tmp/example.hs" "changed again" (Right ()))
          closeSaving
  assert "save after dirty tab close removes the tab but retains workspace" $
    null (concatMap windowTabKeys (application.appView closed).appWindows)
      && length (application.appView closed).appWindows == 1

  let workspaceClosed = applyEvent (WindowCloseRequested firstDocumentWindowKey) closed
  assert "clean workspace close removes the OS window" (null (application.appView workspaceClosed).appWindows)
  putStrLn "uih-text-editor: pure workspace/tab/document model test passed"
  where
    applyEvent event model =
      applyTransaction (application.appHandleEvent event model) model

validateWindowWorkspace :: WindowSpec -> [Text.Text]
validateWindowWorkspace window = maybe [] validateWorkspaceSpec (windowWorkspace window)

windowIsEdited :: WindowSpec -> Bool
windowIsEdited window = window.windowKey == firstDocumentWindowKey && "Edited" `textIn` window.windowTitle

windowTabKeys :: WindowSpec -> [TabKey]
windowTabKeys window = maybe [] workspaceTabKeys (windowWorkspace window)

isCommandEnabled :: CommandId -> [CommandSpec] -> Bool
isCommandEnabled identifier commands =
  case filter ((== identifier) . (.commandId)) commands of
    [command] -> command.commandEnabled
    _ -> False

textEditorSpecs :: [WindowSpec] -> [TextEditorSpec]
textEditorSpecs windows =
  [ editor
  | window <- windows
  , TextEditor editor <- windowLeafControls window
  ]

textIn :: String -> Text.Text -> Bool
textIn needle = Text.isInfixOf (Text.pack needle)

assert :: String -> Bool -> IO ()
assert label condition =
  if condition then pure () else error (label <> " failed")

assertEqual :: (Eq value, Show value) => String -> value -> value -> IO ()
assertEqual label expected actual =
  if expected == actual
    then pure ()
    else error (label <> ": expected " <> show expected <> ", got " <> show actual)
