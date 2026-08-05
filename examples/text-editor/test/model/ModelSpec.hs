{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Example.TextEditor
  ( application
  , firstDocumentEditorKey
  , firstDocumentWindowKey
  , openCommand
  , saveCommand
  )
import qualified Data.Text as Text
import UIH.Core

main :: IO ()
main = do
  let initial = application.appInitialModel
      openRequest = application.appHandleEvent (CommandInvoked openCommand) initial
  assertEqual "Open command effect" [RequestOpenTextFiles] openRequest.transactionEffects

  let opened = applyEvent (TextFileRead "/tmp/example.hs" (Right "module Old where\n")) initial
      openedTwice = applyEvent (TextFileRead "/tmp/notes.txt" (Right "notes\n")) opened
      activated = applyEvent (WindowActivated firstDocumentWindowKey) opened
      edited = applyEvent (TextChanged firstDocumentEditorKey "module New where\n") activated
      editedView = application.appView edited
  assert "two reads create two document windows" (length (application.appView openedTwice).appWindows == 3)
  assert "edited window title" (any windowIsEdited editedView.appWindows)
  assert "Save enabled for active edited document" (isCommandEnabled saveCommand editedView.appCommands)

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
  assert "saved window title" (not (any windowIsEdited savedView.appWindows))
  assert "Save disabled after successful write" (not (isCommandEnabled saveCommand savedView.appCommands))
  let closedCleanly = applyEvent (WindowCloseRequested firstDocumentWindowKey) saved
  assert "clean close removes document" (not (hasWindow firstDocumentWindowKey (application.appView closedCleanly).appWindows))

  let editedAgain = applyEvent (TextChanged firstDocumentEditorKey "changed again") saved
      closeDeferred = applyEvent (WindowCloseRequested firstDocumentWindowKey) editedAgain
  assert "dirty close is vetoed" (hasWindow firstDocumentWindowKey (application.appView closeDeferred).appWindows)

  let closeSaveRequest = application.appHandleEvent (CommandInvoked saveCommand) closeDeferred
      closeSaving = applyTransaction closeSaveRequest closeDeferred
      closed =
        applyEvent
          (TextFileWritten (EffectKey 1000) "/tmp/example.hs" "changed again" (Right ()))
          closeSaving
  assert "save after dirty close removes document" (not (hasWindow firstDocumentWindowKey (application.appView closed).appWindows))
  putStrLn "uih-text-editor: pure multi-document model/effect test passed"
  where
    applyEvent event model =
      applyTransaction (application.appHandleEvent event model) model

windowIsEdited :: WindowSpec -> Bool
windowIsEdited window = window.windowKey == firstDocumentWindowKey && "Edited" `textIn` window.windowTitle

hasWindow :: WindowKey -> [WindowSpec] -> Bool
hasWindow key = any ((== key) . (.windowKey))

isCommandEnabled :: CommandId -> [CommandSpec] -> Bool
isCommandEnabled identifier commands =
  case filter ((== identifier) . (.commandId)) commands of
    [command] -> command.commandEnabled
    _ -> False

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
