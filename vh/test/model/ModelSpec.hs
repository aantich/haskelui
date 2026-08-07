{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import VisualHaskell
  ( application
  , applicationWithAnalysisEnvironment
  , applicationWithWorkspaceRegistry
  , firstDocumentEditorKey
  , firstDocumentTabKey
  , firstDocumentWindowKey
  , openCommand
  , openFolderCommand
  , projectTreeKey
  , saveCommand
  )
import VisualHaskell.Analysis.Service (defaultAnalysisConfiguration)
import VisualHaskell.Highlighting
  ( SyntaxClass (..)
  , highlightHaskell
  )
import qualified VisualHaskell.Diagnostics as Diagnostics
import qualified VisualHaskell.Semantic as Semantic
import VisualHaskell.TextMate (defaultTextMateConfiguration)
import VisualHaskell.WorkspaceState
  ( WorkspaceState (..)
  , decodeWorkspaceState
  , encodeWorkspaceState
  , fromWorkspaceRelativePath
  , toWorkspaceRelativePath
  )
import qualified Data.Text as Text
import HaskeLUI.Core

main :: IO ()
main = do
  let workspaceState =
        WorkspaceState
          { workspaceOpenFiles = ["src/Main.hs", "README.md"]
          , workspaceActiveFile = Just "src/Main.hs"
          , workspaceExpandedFolders = [".", "src"]
          , workspaceSelectedExplorerEntry = Just "src/Main.hs"
          , workspaceNavigatorPane = PaneState PaneVisible (Just 246)
          , workspaceInspectorPane = PaneState PaneCollapsed (Just 300)
          , workspaceAnalysisTrusted = True
          }
  assertEqual
    "workspace JSON round-trips its versioned portable state"
    (Right workspaceState)
    (decodeWorkspaceState (encodeWorkspaceState workspaceState))
  assert
    "workspace JSON rejects paths that escape the project root"
    ( case decodeWorkspaceState
        "{\"format\":\"visual-haskell-workspace\",\"version\":1,\"openFiles\":[\"../secret\"]}" of
        Left _ -> True
        Right _ -> False
    )
  assertEqual
    "workspace paths are stored relative to their root"
    (Just "src/Main.hs")
    (toWorkspaceRelativePath "/tmp/project" "/tmp/project/src/Main.hs")
  assertEqual
    "workspace paths resolve underneath their root"
    (Just "/tmp/project/src/Main.hs")
    (fromWorkspaceRelativePath "/tmp/project" "src/Main.hs")
  assertEqual
    "workspace paths outside the root are not persisted"
    Nothing
    (toWorkspaceRelativePath "/tmp/project" "/tmp/elsewhere/Main.hs")

  let highlighted = highlightHaskell "😀 module Main where\nvalue = \"hi\" -- note\n"
  assert
    "pure highlighter uses Unicode scalar ranges"
    ( TextSpan (TextRange 2 6) SyntaxKeyword `elem` highlighted
        && TextSpan (TextRange 9 4) SyntaxTypeName `elem` highlighted
        && TextSpan (TextRange 28 4) SyntaxString `elem` highlighted
        && TextSpan (TextRange 33 7) SyntaxComment `elem` highlighted
    )

  let diagnosticSource = "module Main where\nbroken =\n"
      diagnosticRevision = TextRevision 7
      semanticDiagnosticRevision = Semantic.TextRevision 7
      compilerDiagnostic =
        Semantic.Diagnostic
          { Semantic.diagnosticId = Semantic.DiagnosticId "ghc:test"
          , Semantic.diagnosticSeverity = Semantic.DiagnosticError
          , Semantic.diagnosticSource = "GHC 9.10.3"
          , Semantic.diagnosticCode = Just "GHC-00000"
          , Semantic.diagnosticMessage = "parse error"
          , Semantic.diagnosticRange =
              Semantic.RevisionedSourceRange
                semanticDiagnosticRevision
                (Semantic.SourcePosition 1 0 Semantic.GhcColumn)
                (Semantic.SourcePosition 1 6 Semantic.GhcColumn)
          , Semantic.diagnosticRelated = []
          }
      diagnosticSnapshot =
        Semantic.AnalysisSnapshot
          { Semantic.analysisWorkspaceGeneration = Semantic.WorkspaceGeneration 1
          , Semantic.analysisSession = Semantic.SessionId "test"
          , Semantic.analysisDocument = Semantic.DocumentId "/tmp/Main.hs"
          , Semantic.analysisRevision = semanticDiagnosticRevision
          , Semantic.analysisContentHash = Semantic.contentHash diagnosticSource
          , Semantic.analysisCompleteness = Semantic.PartiallyFailed
          , Semantic.analysisFreshness = Semantic.CurrentAnalysis
          , Semantic.analysisDiagnostics = [compilerDiagnostic]
          , Semantic.analysisDeclarations = []
          , Semantic.analysisTypes = mempty
          }
      projectedDiagnostics =
        Diagnostics.projectCurrentDiagnostics
          (Semantic.DocumentId "/tmp/Main.hs")
          diagnosticRevision
          diagnosticSource
          diagnosticSnapshot
  assertEqual
    "current compiler diagnostics become Unicode-scalar editor ranges"
    [TextRange 18 6]
    (fmap (.projectedRange) projectedDiagnostics)
  assert
    "diagnostic presentation composes as a colored underline-only layer"
    ( case Diagnostics.diagnosticTextLayer DarkColorScheme diagnosticRevision projectedDiagnostics of
        Just layer ->
          case layer.textLayerSpans of
            [spanValue] ->
              spanValue.textSpanValue.textUnderline == Just UnderlineWavy
                && spanValue.textSpanValue.textUnderlineColor /= Nothing
                && spanValue.textSpanValue.textForeground == Nothing
            _ -> False
        Nothing -> False
    )
  assertEqual
    "a late diagnostic snapshot never decorates a newer text revision"
    []
    ( Diagnostics.projectCurrentDiagnostics
        (Semantic.DocumentId "/tmp/Main.hs")
        (TextRevision 8)
        diagnosticSource
        diagnosticSnapshot
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

  let persistedApplication = applicationWithWorkspaceRegistry "/tmp/visual-haskell/last-workspace"
  assertEqual
    "Visual Haskell asks for the last-workspace locator at startup"
    [ ReadOptionalTextFile "/tmp/visual-haskell/last-workspace"
    , ReadOptionalTextFile "/tmp/visual-haskell/trusted-workspaces.json"
    ]
    persistedApplication.appInitialEffects
  let startupRestore =
        persistedApplication.appHandleEvent
          (OptionalTextFileRead "/tmp/visual-haskell/last-workspace" (Right (Just "/tmp/project\n")))
          persistedApplication.appInitialModel
  assertEqual
    "the last-workspace locator starts the normal workspace restore path"
    [ ReadDirectory "/tmp/project"
    , ReadOptionalTextFile "/tmp/project/.vihs"
    ]
    startupRestore.transactionEffects
  let startupRootModel = applyTransaction startupRestore persistedApplication.appInitialModel
      trustedWorkspaceRequest =
        workspaceState
          { workspaceOpenFiles = []
          , workspaceActiveFile = Nothing
          , workspaceExpandedFolders = ["."]
          , workspaceSelectedExplorerEntry = Nothing
          }
      metadataRestore =
        persistedApplication.appHandleEvent
          ( OptionalTextFileRead
              "/tmp/project/.vihs"
              (Right (Just (encodeWorkspaceState trustedWorkspaceRequest)))
          )
          startupRootModel
      awaitingTrust = applyTransaction metadataRestore startupRootModel
      trustUpdate =
        persistedApplication.appHandleEvent
          (CommandInvoked (CommandId 13))
          awaitingTrust
      trustedModel = applyTransaction trustUpdate awaitingTrust
  assert
    "project metadata cannot grant compiler trust without user authorization"
    (isCommandEnabled (CommandId 13) (persistedApplication.appView awaitingTrust).appCommands)
  assert
    "trusting writes both user authority and the workspace restoration preference"
    ( any
        ( \case
            WriteTextFileAtomically _ "/tmp/visual-haskell/trusted-workspaces.json" _ -> True
            _ -> False
        )
        trustUpdate.transactionEffects
        && any
          ( \case
              WriteTextFileAtomically _ "/tmp/project/.vihs" contents ->
                case decodeWorkspaceState contents of
                  Right state -> state.workspaceAnalysisTrusted
                  Left _ -> False
              _ -> False
          )
          trustUpdate.transactionEffects
    )
  assert
    "trusted workspace disables the trust command immediately"
    (not (isCommandEnabled (CommandId 13) (persistedApplication.appView trustedModel).appCommands))
  let rememberedWorkspace =
        persistedApplication.appHandleEvent
          (ProjectFolderChosen "/tmp/remember-me")
          persistedApplication.appInitialModel
  assert
    "opening a workspace updates the per-user last-workspace locator"
    ( any
        ( \case
            WriteTextFileAtomically _ "/tmp/visual-haskell/last-workspace" contents ->
              contents == "/tmp/remember-me\n"
            _ -> False
        )
        rememberedWorkspace.transactionEffects
    )

  let folderChosen = application.appHandleEvent (ProjectFolderChosen "/tmp/project") initial
      projectOpening = applyTransaction folderChosen initial
  assertEqual
    "choosing a project reads its root and optional Visual Haskell state"
    [ ReadDirectory "/tmp/project"
    , ReadOptionalTextFile "/tmp/project/.vihs"
    ]
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

  let freshWorkspaceRead =
        application.appHandleEvent
          (OptionalTextFileRead "/tmp/project/.vihs" (Right Nothing))
          projectOpening
  assertWorkspaceWrite
    "a workspace without .vihs immediately gets a safe initial snapshot"
    "/tmp/project/.vihs"
    freshWorkspaceRead.transactionEffects
    ( \state ->
        null state.workspaceOpenFiles
          && state.workspaceExpandedFolders == ["."]
    )

  let restoreChosen = application.appHandleEvent (ProjectFolderChosen "/tmp/restored") initial
      restoreOpening = applyTransaction restoreChosen initial
      restoreRootLoaded =
        applyEvent
          ( DirectoryRead
              "/tmp/restored"
              ( Right
                  [ FileSystemEntry "/tmp/restored/src" "src" FileSystemDirectory
                  , FileSystemEntry "/tmp/restored/.vihs" ".vihs" FileSystemFile
                  , FileSystemEntry "/tmp/restored/README.md" "README.md" FileSystemFile
                  ]
              )
          )
          restoreOpening
      restoreMetadata =
        application.appHandleEvent
          ( OptionalTextFileRead
              "/tmp/restored/.vihs"
              (Right (Just (encodeWorkspaceState workspaceState)))
          )
          restoreRootLoaded
      restoring = applyTransaction restoreMetadata restoreRootLoaded
  assertEqual
    "valid .vihs state restores directories shallow-first and files in tab order"
    [ ReadDirectory "/tmp/restored/src"
    , ReadTextFile "/tmp/restored/src/Main.hs"
    , ReadTextFile "/tmp/restored/README.md"
    ]
    restoreMetadata.transactionEffects
  let restoredSource =
        applyEvent
          ( DirectoryRead
              "/tmp/restored/src"
              (Right [FileSystemEntry "/tmp/restored/src/Main.hs" "Main.hs" FileSystemFile])
          )
          restoring
      restoredMain =
        applyEvent
          (TextFileRead "/tmp/restored/src/Main.hs" (Right "module Main where\n"))
          restoredSource
      restoreReadme =
        application.appHandleEvent
          (TextFileRead "/tmp/restored/README.md" (Right "# Restored\n"))
          restoredMain
      restoredWorkspace = applyTransaction restoreReadme restoredMain
  assertEqual
    "workspace recovery preserves tab order"
    [TabKey 1000, TabKey 1001]
    (concatMap windowTabKeys (application.appView restoredWorkspace).appWindows)
  assertEqual
    "workspace recovery selects the saved active tab"
    (Just (TabKey 1000))
    (firstWorkspaceSelectedTab (application.appView restoredWorkspace).appWindows)
  assertEqual
    "workspace recovery restores portable pane state"
    [ PaneState PaneVisible (Just 246)
    , PaneState PaneCollapsed (Just 300)
    ]
    (sidebarAndInspectorStates (application.appView restoredWorkspace).appWindows)
  assertProjectItems
    "workspace recovery expands the saved folder hierarchy and hides .vihs"
    [ (CollectionItemKey 1, "restored", 0, Just (SystemSymbol "folder.fill"), True, True)
    , (CollectionItemKey 2, "src", 1, Just (SystemSymbol "folder.fill"), True, True)
    , (CollectionItemKey 4, "Main.hs", 2, Just (SystemSymbol "doc.text"), False, False)
    , (CollectionItemKey 3, "README.md", 1, Just (SystemSymbol "doc.text"), False, False)
    ]
    restoredWorkspace
  assertWorkspaceWrite
    "the completed recovery is canonicalized back to .vihs"
    "/tmp/restored/.vihs"
    restoreReadme.transactionEffects
    (== workspaceState)

  let malformedWorkspace =
        application.appHandleEvent
          (OptionalTextFileRead "/tmp/restored/.vihs" (Right (Just "not-json")))
          restoreRootLoaded
      malformedModel = applyTransaction malformedWorkspace restoreRootLoaded
      attemptedChange =
        application.appHandleEvent
          (PaneStateChanged (PaneKey 10) (PaneState PaneCollapsed Nothing))
          malformedModel
  assertEqual
    "malformed workspace state is preserved and blocks later metadata writes"
    []
    attemptedChange.transactionEffects

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

  textMateConfiguration <- defaultTextMateConfiguration "/tmp/visual-haskell-scheduler"
  let compilerApplication =
        applicationWithAnalysisEnvironment
          "/tmp/visual-haskell-scheduler/last-workspace"
          textMateConfiguration
          (defaultAnalysisConfiguration "visual-haskell-analysis-ghc910")
      compilerInitial = compilerApplication.appInitialModel
      compilerFolderUpdate =
        compilerApplication.appHandleEvent
          (ProjectFolderChosen "/tmp/compiler-project")
          compilerInitial
      compilerFolder = applyTransaction compilerFolderUpdate compilerInitial
      compilerTrustUpdate =
        compilerApplication.appHandleEvent (CommandInvoked (CommandId 13)) compilerFolder
      compilerTrusted = applyTransaction compilerTrustUpdate compilerFolder
      compilerOpenUpdate =
        compilerApplication.appHandleEvent
          (TextFileRead "/tmp/compiler-project/Main.hs" (Right "module Main where\nvalue = 1\n"))
          compilerTrusted
      compilerOpened = applyTransaction compilerOpenUpdate compilerTrusted
      compilerEditUpdate =
        compilerApplication.appHandleEvent
          (TextChanged firstDocumentEditorKey "module Main where\nvalue = 2\n")
          compilerOpened
      compilerEdited = applyTransaction compilerEditUpdate compilerOpened
  assertEqual
    "opening an active Haskell document schedules one debounced compiler request"
    [TaskKey "visual-haskell.analysis.edit-debounce"]
    (taskKeys compilerOpenUpdate.transactionCommands)
  assertEqual
    "editing replaces the same document-analysis debounce task"
    [TaskKey "visual-haskell.analysis.edit-debounce"]
    (taskKeys compilerEditUpdate.transactionCommands)
  debouncedRequest <- runOnlyTask compilerEditUpdate.transactionCommands compilerEdited
  assertEqual
    "the completed debounce sends the latest snapshot and one analysis request"
    2
    (length debouncedRequest.transactionCommands)

  putStrLn "vh: pure workspace/tab/document model test passed"
  where
    applyEvent event model =
      applyTransaction (application.appHandleEvent event model) model

taskKeys :: [RuntimeCommand model] -> [TaskKey]
taskKeys commands =
  [ key
  | StartTaskCommand key _ _ _ _ <- commands
  ]

runOnlyTask :: [RuntimeCommand model] -> model -> IO (Transaction model)
runOnlyTask commands model =
  case [command | command@StartTaskCommand {} <- commands] of
    [StartTaskCommand _ _ _ runTask finishTask] -> do
      result <- runTask (CancellationToken (pure False) (pure ()))
      pure (handleExternalEvent (finishTask (TaskSucceeded result)) model)
    matches -> error ("expected one task command, got " <> show (length matches))

validateWindowWorkspace :: WindowSpec -> [Text.Text]
validateWindowWorkspace window = maybe [] validateWorkspaceSpec (windowWorkspace window)

windowIsEdited :: WindowSpec -> Bool
windowIsEdited window = window.windowKey == firstDocumentWindowKey && "Edited" `textIn` window.windowTitle

windowTabKeys :: WindowSpec -> [TabKey]
windowTabKeys window =
  [ tab.workspaceTabKey
  | workspace <- maybe [] pure (windowWorkspace window)
  , pane <- paneSpecs workspace.workspaceRoot
  , WorkspaceItemTabGroup group <- [pane.workspacePaneItem.workspaceItemContent]
  , tab <- group.workspaceTabs
  , tab.workspaceTabDocument /= Nothing
  ]

firstWorkspaceSelectedTab :: [WindowSpec] -> Maybe TabKey
firstWorkspaceSelectedTab windows =
  case
      [ selected
      | window <- windows
      , workspace <- maybe [] pure (windowWorkspace window)
      , pane <- paneSpecs workspace.workspaceRoot
      , WorkspaceItemTabGroup group <- [pane.workspacePaneItem.workspaceItemContent]
      , any ((/= Nothing) . (.workspaceTabDocument)) group.workspaceTabs
      , selected <- maybe [] pure group.workspaceSelectedTab
      ] of
    selected : _ -> Just selected
    [] -> Nothing

sidebarAndInspectorStates :: [WindowSpec] -> [PaneState]
sidebarAndInspectorStates windows =
  [ pane.workspacePaneState
  | window <- windows
  , workspace <- maybe [] pure (windowWorkspace window)
  , pane <- paneSpecs workspace.workspaceRoot
  , pane.workspacePaneRole `elem` [SidebarPane, InspectorPane]
  ]

paneSpecs :: PaneTree -> [WorkspacePaneSpec]
paneSpecs (WorkspacePane pane) = [pane]
paneSpecs (WorkspaceSplit _ _ first second rest) =
  concatMap paneSpecs (first : second : rest)

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

assertWorkspaceWrite
  :: String
  -> FilePath
  -> [Effect]
  -> (WorkspaceState -> Bool)
  -> IO ()
assertWorkspaceWrite label expectedPath effects predicate =
  case
      [ contents
      | WriteTextFileAtomically _ path contents <- effects
      , path == expectedPath
      ] of
    [contents] ->
      case decodeWorkspaceState contents of
        Right state -> assert label (predicate state)
        Left message -> error (label <> ": invalid workspace JSON: " <> Text.unpack message)
    matches -> error (label <> ": expected one atomic workspace write, got " <> show matches)

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
