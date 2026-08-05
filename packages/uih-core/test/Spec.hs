{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import UIH.Core

main :: IO ()
main = do
  let increment = transaction "Increment" (SingleUndo (UndoGroup "counter")) (+ 1)
  assert "transaction application" (applyTransaction increment (1 :: Int) == 2)

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
  putStrLn "uih-core: transaction and generic text-layer tests passed"

assert :: String -> Bool -> IO ()
assert label condition =
  if condition then pure () else error (label <> " failed")
