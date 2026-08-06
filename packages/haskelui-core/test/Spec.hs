{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import LayoutSpec (runLayoutTests)
import PropertySpec (runPropertyTests)
import DrawingSpec (runDrawingTests)
import HaskeLUI.Core

main :: IO ()
main = do
  runLayoutTests
  runPropertyTests
  runDrawingTests
  let increment = transaction "Increment" (SingleUndo (UndoGroup "counter")) (+ 1)
  assert "transaction application" (applyTransaction increment (1 :: Int) == 2)
  let updateWithEffect =
        transactionFromActionWithEffects
          "Update and request files"
          NoUndo
          [RequestOpenTextFiles]
          (actionWithProperties "Set counter" [PropertyId "counter"] (const (3 :: Int)))
  assert "action/effect transaction retains action metadata and effects" $
    applyTransaction updateWithEffect 1 == 3
      && actionPropertyIds updateWithEffect.transactionAction == [PropertyId "counter"]
      && updateWithEffect.transactionEffects == [RequestOpenTextFiles]

  let revision = TextRevision 4
      black = RGBA 0 0 0 1
      red = RGBA 1 0 0 1
      yellow = RGBA 1 1 0 1
      base = mempty {textForeground = Just black, textFontFamily = Just MonospaceFont}
      syntax =
        TextLayer
          (TextLayerKey 1)
          revision
          [TextSpan (TextRange 1 3) (mempty {textForeground = Just red})]
      search =
        TextLayer
          (TextLayerKey 2)
          revision
          [TextSpan (TextRange 2 3) (mempty {textBackground = Just yellow})]
      stale =
        TextLayer
          (TextLayerKey 3)
          (TextRevision 3)
          [TextSpan (TextRange 0 6) (mempty {textStrikethrough = Just True})]
      invalid =
        TextLayer
          (TextLayerKey 4)
          revision
          [TextSpan (TextRange 99 2) (mempty {textUnderline = Just UnderlineSingle})]
      resolved = resolveTextLayers 6 base revision [syntax, search, stale, invalid]
  assert
    "layer boundaries"
    ( fmap textSpanRange resolved
        == [ TextRange 0 1
           , TextRange 1 1
           , TextRange 2 2
           , TextRange 4 1
           , TextRange 5 1
           ]
    )
  assert "syntax foreground survives overlap" $
    case drop 2 resolved of
      TextSpan _ style : _ ->
        textForeground style == Just red
          && textBackground style == Just yellow
          && textFontFamily style == Just MonospaceFont
          && textStrikethrough style == Nothing
      _ -> False
  let authoredRuns =
        [ TextRun "plain " mempty
        , TextRun "large" (mempty {textFontSize = Just 24})
        , TextRun " italic" (mempty {textFontSlant = Just Italic})
        ]
      authored = attributedTextFromRuns authoredRuns
  assert "rich text run construction preserves text" $
    attributedTextValue authored == "plain large italic"
      && attributedTextToRuns authored == authoredRuns
  assert "rich text rejects out-of-snapshot spans" $
    case attributedTextFromSpans "short" [TextSpan (TextRange 4 2) mempty] of
      Left _ -> True
      Right _ -> False

  let sourceItem =
        WorkspaceItemSpec
          (WorkspaceItemKey 1)
          (WorkspaceItemControls [Label (ElementKey 10) (Rect 0 0 100 20) "Source"])
      typesItem =
        WorkspaceItemSpec
          (WorkspaceItemKey 2)
          (WorkspaceItemControls [Label (ElementKey 20) (Rect 0 0 100 20) "Types"])
      paneFor key role item =
        WorkspacePaneSpec
          key
          role
          (PaneSizing (Just 100) (Just 240) Nothing 1)
          (PaneState PaneVisible Nothing)
          item
      sourceCenter = paneFor (PaneKey 1) ContentPane sourceItem
      typesRight = paneFor (PaneKey 2) InspectorPane typesItem
      typesCenter = sourceCenter {workspacePaneItem = typesItem}
      sourceRight = typesRight {workspacePaneItem = sourceItem}
      beforeSwap =
        WorkspaceSpec
          (WorkspaceSplit (SplitKey 1) SideBySide (WorkspacePane sourceCenter) (WorkspacePane typesRight) [])
          []
      afterSwap =
        WorkspaceSpec
          (WorkspaceSplit (SplitKey 1) SideBySide (WorkspacePane typesCenter) (WorkspacePane sourceRight) [])
          []
      beforeWindow = WorkspaceWindowSpec (WindowKey 1) "Before" (Rect 0 0 800 600) beforeSwap
      afterWindow = WorkspaceWindowSpec (WindowKey 1) "After" (Rect 0 0 800 600) afterSwap
  assert "workspace item identities survive pane swaps" $
    validateWorkspaceSpec beforeSwap == []
      && validateWorkspaceSpec afterSwap == []
      && fmap controlIdentity (windowLeafControls beforeWindow) == [ElementKey 10, ElementKey 20]
      && fmap controlIdentity (windowLeafControls afterWindow) == [ElementKey 20, ElementKey 10]
  assert "tab successor prefers the following tab" $
    nextTabAfterRemoval (TabKey 2) [TabKey 1, TabKey 2, TabKey 3] == Just (TabKey 3)
      && nextTabAfterRemoval (TabKey 3) [TabKey 1, TabKey 2, TabKey 3] == Just (TabKey 2)
  putStrLn "haskelui-core: transactions, text layers, and workspace identity tests passed"

controlIdentity :: Control -> ElementKey
controlIdentity = controlKey

assert :: String -> Bool -> IO ()
assert label condition =
  if condition then pure () else error (label <> " failed")
