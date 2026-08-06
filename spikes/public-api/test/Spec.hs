{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Examples.MultiwindowEditor
import HaskeLUI.Sketch

main :: IO ()
main = do
  assertEqual
    "two documents plus settings produce three windows"
    3
    (appWindowCount editorApp initialEditorModel)

  let commands = appCommands editorApp initialEditorModel
  assertEqual "editor declares save and close commands" 2 (length commands)
  case commands of
    saveCommand : _ -> do
      assertEqual "save is the first shared command" saveCommandId (commandIdentifier saveCommand)
    [] -> error "expected editor commands"

  let confirmingClose = initialEditorModel {pendingClose = Just (DocumentId 1)}
  assertEqual
    "pending close state declaratively adds a confirmation window"
    4
    (appWindowCount editorApp confirmingClose)

  assertEqual
    "a direct binding reads the authoritative property"
    "Draft"
    (readBinding documentTitleBinding (Document "Draft" "Body" False))

  case editBinding InputChanged documentTitleBinding "Renamed" of
    EditCommitted _ transaction -> do
      let edited = applyTransaction transaction (Document "Draft" "Body" False)
      assertEqual "the edit updates the bound property" "Renamed" edited.title
      assertEqual "the same transaction marks the document dirty" True edited.dirty
      assertEqual
        "live typing carries its undo coalescing policy"
        (Coalesce (UndoGroup "rename-document"))
        transaction.transactionUndo
      assertEqual
        "a committed edit has a user-facing transaction label"
        (Just "Rename document")
        transaction.transactionDescription
    DraftStaged _ -> error "a valid live edit should commit"
    DraftInvalid _ issues -> error ("a valid title was rejected: " <> show issues)

  case editBinding InputChanged documentTitleBinding "   " of
    DraftInvalid draft issues -> do
      assertEqual "invalid text remains available as the element draft" "   " draft
      assertEqual "title validation reports one issue" 1 (length issues)
    DraftStaged _ -> error "an empty title should not stage as valid"
    EditCommitted {} -> error "an empty title should not reach the model"

  let baseDocument = Document "Draft" "Body" False
      titleBaseline = captureDraftBaseline documentTitleBinding baseDocument
      remotelyRenamed = Document "Remote title" "Body" False
  assertEqual
    "an externally changed value refreshes a pristine draft"
    (DraftRefreshed "Remote title")
    (reconcileDraft titleBaseline remotelyRenamed "Draft")
  assertEqual
    "concurrent local and external edits produce an explicit three-way conflict"
    ( DraftConflictDetected
        BindingConflict
          { conflictOriginal = "Draft"
          , conflictLocalDraft = "Local title"
          , conflictAuthoritative = "Remote title"
          }
    )
    (reconcileDraft titleBaseline remotelyRenamed "Local title")

  assertEqual
    "formatted bindings read model values as control text"
    "14"
    (readBinding fontSizeBinding initialEditorModel)

  case editBinding InputChanged fontSizeBinding "18" of
    DraftStaged draft ->
      assertEqual "commit-on-enter keeps a valid intermediate draft" "18" draft
    DraftInvalid _ issues -> error ("a valid font size was rejected: " <> show issues)
    EditCommitted {} -> error "font size should not commit on each keystroke"

  case editBinding InputChanged fontSizeBinding "12x" of
    DraftInvalid draft _ ->
      assertEqual "a parse failure preserves the exact typed text" "12x" draft
    DraftStaged _ -> error "unparseable text should be an invalid draft"
    EditCommitted {} -> error "unparseable text should not reach the model"

  case editBinding EnterPressed fontSizeBinding "18" of
    EditCommitted _ transaction -> do
      assertEqual
        "enter commits the parsed model value"
        18
        (currentFontSize (applyTransaction transaction initialEditorModel))
      assertEqual
        "commit-based edits form one undo unit"
        (SingleUndo (UndoGroup "change-editor-font-size"))
        transaction.transactionUndo
    DraftStaged _ -> error "enter should commit a valid staged font size"
    DraftInvalid _ issues -> error ("a valid font size was rejected: " <> show issues)

  let fontBaseline = captureDraftBaseline fontSizeBinding initialEditorModel
  case editBinding EnterPressed fontSizeBinding "20" of
    EditCommitted _ transaction ->
      assertEqual
        "preserve-local policy keeps a staged edit after an external update"
        (DraftPreserved "18")
        ( reconcileDraft
            fontBaseline
            (applyTransaction transaction initialEditorModel)
            "18"
        )
    DraftStaged _ -> error "enter should commit a valid external font-size update"
    DraftInvalid _ issues -> error ("a valid font size was rejected: " <> show issues)

  assertEqual
    "asynchronous validation is a separately identified declaration"
    (ValidationId "document-title.available")
    (validationIdentifier documentTitleAvailability)

  putStrLn "public API spike: bindings and multiwindow editor smoke tests pass"

assertEqual :: (Eq value, Show value) => String -> value -> value -> IO ()
assertEqual message expected actual
  | expected == actual = pure ()
  | otherwise = error (message <> ": expected " <> show expected <> ", got " <> show actual)
