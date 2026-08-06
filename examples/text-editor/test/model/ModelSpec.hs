{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Example.TextEditor
  ( application
  , firstDocumentEditorKey
  , firstDocumentTabKey
  , firstDocumentWindowKey
  , openCommand
  , openFolderCommand
  , projectTreeKey
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
  let openFolderRequest = application.appHandleEvent (CommandInvoked openFolderCommand) initial
  assertEqual
    "Open Folder command effect"
    [RequestOpenProjectFolder]
    openFolderRequest.transactionEffects
  assert "editor starts with one workspace window" (length initialView.appWindows == 1)
  assert "empty workspace validates" (all (null . validateWindowWorkspace) initialView.appWindows)

  let folderChosen = application.appHandleEvent (ProjectFolderChosen "/tmp/project") initial
      projectOpening = applyTransaction folderChosen initial
  assertEqual
    "choosing a project lazily requests only its root directory"
    [ReadDirectory "/tmp/project"]
    folderChosen.transactionEffects
  assertProjectItems
    "project root is immediately visible with an expanded folder icon"
    [ (CollectionItemKey 1, "project", 0, Just (SystemSymbol "folder.fill"), True, True)
    ]
    projectOpening

  let rootLoaded =
        applyEvent
          ( DirectoryRead
              "/tmp/project"
              ( Right
                  [ FileSystemEntry "/tmp/project/src" "src" FileSystemDirectory
                  , FileSystemEntry "/tmp/project/README.md" "README.md" FileSystemFile
                  ]
              )
          )
          projectOpening
      expandSource =
        application.appHandleEvent
          (CollectionSelectionChanged projectTreeKey [CollectionItemKey 2])
          rootLoaded
      sourceOpening = applyTransaction expandSource rootLoaded
  assertProjectItems
    "an unloaded folder advertises expansion before it has child rows"
    [ (CollectionItemKey 1, "project", 0, Just (SystemSymbol "folder.fill"), True, True)
    , (CollectionItemKey 2, "src", 1, Just (SystemSymbol "folder"), True, False)
    , (CollectionItemKey 3, "README.md", 1, Just (SystemSymbol "doc.text"), False, False)
    ]
    rootLoaded
  assertEqual
    "activating an unloaded folder requests exactly that directory"
    [ReadDirectory "/tmp/project/src"]
    expandSource.transactionEffects

  let sourceLoaded =
        applyEvent
          ( DirectoryRead
              "/tmp/project/src"
              (Right [FileSystemEntry "/tmp/project/src/Main.hs" "Main.hs" FileSystemFile])
          )
          sourceOpening
  assertProjectItems
    "loaded project hierarchy retains depth, folder state, and file icons"
    [ (CollectionItemKey 1, "project", 0, Just (SystemSymbol "folder.fill"), True, True)
    , (CollectionItemKey 2, "src", 1, Just (SystemSymbol "folder.fill"), True, True)
    , (CollectionItemKey 4, "Main.hs", 2, Just (SystemSymbol "doc.text"), False, False)
    , (CollectionItemKey 3, "README.md", 1, Just (SystemSymbol "doc.text"), False, False)
    ]
    sourceLoaded

  let emptyRootLoaded =
        applyEvent
          ( DirectoryRead
              "/tmp/project"
              (Right [FileSystemEntry "/tmp/project/empty" "empty" FileSystemDirectory])
          )
          projectOpening
      emptyOpening =
        applyEvent
          (CollectionSelectionChanged projectTreeKey [CollectionItemKey 2])
          emptyRootLoaded
      emptyLoaded =
        applyEvent
          (DirectoryRead "/tmp/project/empty" (Right []))
          emptyOpening
  assertProjectItems
    "a directory known to be empty no longer advertises expansion"
    [ (CollectionItemKey 1, "project", 0, Just (SystemSymbol "folder.fill"), True, True)
    , (CollectionItemKey 2, "empty", 1, Just (SystemSymbol "folder.fill"), False, True)
    ]
    emptyLoaded

  let mainSelected =
        application.appHandleEvent
          (CollectionSelectionChanged projectTreeKey [CollectionItemKey 4])
          sourceLoaded
      mainOpened =
        applyEvent
          (TextFileRead "/tmp/project/src/Main.hs" (Right "module Main where\n"))
          (applyTransaction mainSelected sourceLoaded)
      mainSelectedAgain =
        application.appHandleEvent
          (CollectionSelectionChanged projectTreeKey [CollectionItemKey 4])
          mainOpened
  assertEqual
    "selecting a project file reads it"
    [ReadTextFile "/tmp/project/src/Main.hs"]
    mainSelected.transactionEffects
  assertEqual
    "selecting an already-open project file only activates its existing tab"
    []
    mainSelectedAgain.transactionEffects
  assertEqual
    "opening the same project file never creates a duplicate tab"
    [TabKey 1000]
    (concatMap windowTabKeys (application.appView (applyTransaction mainSelectedAgain mainOpened)).appWindows)

  let opened = applyEvent (TextFileRead "/tmp/example.hs" (Right "module Old where\n")) initial
      openedTwice = applyEvent (TextFileRead "/tmp/notes.txt" (Right "notes\n")) opened
      twiceView = application.appView openedTwice
  assert "two reads stay in one workspace window" (length twiceView.appWindows == 1)
  assertEqual "two document tabs" [TabKey 1000, TabKey 1001] (concatMap windowTabKeys twiceView.appWindows)
  assert "workspace exposes a shared status area" $
    case twiceView.appWindows of
      [window] -> maybe False (not . null . workspaceStatusControls) (windowWorkspace window)
      _ -> False

  let selectFirst = application.appHandleEvent (TabSelected firstDocumentTabKey) openedTwice
      selectedFirst = applyTransaction selectFirst openedTwice
      editText =
        application.appHandleEvent
          (TextChanged firstDocumentEditorKey "module New where\n")
          selectedFirst
      edited = applyTransaction editText selectedFirst
      editedView = application.appView edited
  assertEqual
    "tab selection uses its named property"
    [PropertyId "selectedTab"]
    (actionPropertyIds selectFirst.transactionAction)
  assertEqual
    "controlled document binding reports every qualified child property"
    [ PropertyId "documents.1000.documentCloseAfterSave"
    , PropertyId "documents.1000.documentContents"
    , PropertyId "documents.1000.documentRevision"
    , PropertyId "documents.1000.documentStatus"
    ]
    (actionPropertyIds editText.transactionAction)
  assertEqual
    "document binding keeps its coalescing policy"
    (Coalesce (UndoGroup "edit-document-1000"))
    editText.transactionUndo
  let firstClosedBeforeStaleEdit =
        applyEvent (TabCloseRequested firstDocumentTabKey) selectedFirst
      staleEditApplied = applyTransaction editText firstClosedBeforeStaleEdit
  assertEqual
    "a lifted stale document edit never retargets the remaining document"
    ["notes\n"]
    (fmap (.textEditorText) (textEditorSpecs (application.appView staleEditApplied).appWindows))
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
  assertEqual
    "Save retains touched-property metadata alongside its effect"
    [PropertyId "documents.1000.documentStatus"]
    (actionPropertyIds saveRequest.transactionAction)

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

assertProjectItems label expected model =
  assertEqual label expected actual
  where
    actual =
      [ ( item.collectionItemKey
        , item.collectionItemLabel
        , item.collectionItemDepth
        , item.collectionItemIcon
        , item.collectionItemExpandable
        , item.collectionItemExpanded
        )
      | window <- (application.appView model).appWindows
      , TreeView collection <- windowLeafControls window
      , collection.collectionControlKey == projectTreeKey
      , item <- collection.collectionControlItems
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
