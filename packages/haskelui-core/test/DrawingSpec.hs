{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

module DrawingSpec (runDrawingTests) where

import HaskeLUI.Core

runDrawingTests :: IO ()
runDrawingTests = do
  let red = Solid (RGBA 1 0 0 1)
      blue = Solid (RGBA 0 0 1 1)
      path =
        Path
          [ MoveTo (Point 0 0)
          , LineTo (Point 20 0)
          , QuadraticTo (Point 30 10) (Point 20 20)
          , CubicTo (Point 10 30) (Point 0 30) (Point 0 20)
          , ClosePath
          ]
      text =
        TextDraw
          "portable text"
          (Rect 0 0 200 40)
          (mempty {textForeground = Just (RGBA 0 0 0 1), textFontSize = Just 14})
          TextCenter
          TextMiddle
          WordWrap
      drawing =
        Group
          [ Fill NonZero red (Rectangle (Rect 0 0 20 20))
          , Fill EvenOdd blue (RoundedRectangle (Rect 25 0 20 20) 4 4)
          , Stroke defaultStrokeStyle red (Ellipse (Rect 50 0 20 20))
          , Clip NonZero (PathGeometry path) (Opacity 0.5 (DrawText text))
          , Transform (translation 10 10) (Stroke defaultStrokeStyle blue (PathGeometry path))
          ]
      commands = compileDrawing drawing
      metrics = IntrinsicMetrics (Size 10 10) (Size 200 100) (Size 400 200) Nothing Nothing
      surface =
        DrawingSurface
          DrawingSurfaceSpec
            { drawingSurfaceKey = ElementKey 90
            , drawingSurfaceFrame = Rect 1 2 200 100
            , drawingSurfaceRevision = DrawingRevision 7
            , drawingSurfaceDrawing = drawing
            , drawingSurfaceIntrinsicMetrics = metrics
            , drawingSurfaceAccessibleLabel = "drawing test"
            }
  assert "valid drawing" (null (validateDrawing drawing))
  assert "all drawing commands compile" $
    any isFill commands
      && any isStroke commands
      && any isClip commands
      && any isTransform commands
      && any isOpacity commands
      && any isText commands
  assert "drawing surface participates in Core identity and layout" $
    controlKey surface == ElementKey 90
      && controlFrame surface == Rect 1 2 200 100
      && controlIntrinsicMetrics surface == metrics
      && controlCatalogKind surface == Nothing
      && controlFrame (setControlFrame (Rect 3 4 50 60) surface) == Rect 3 4 50 60
  assert "invalid path state is rejected" $
    not (null (validateDrawing (Stroke defaultStrokeStyle red (PathGeometry (Path [LineTo (Point 1 1)])))))
  assert "non-finite and out-of-range values are rejected" $
    not (null (validateDrawing (Opacity 1.5 (Fill NonZero (Solid (RGBA (0 / 0) 0 0 1)) (Rectangle (Rect 0 0 (-1) 2))))))
  putStrLn "haskelui-drawing: display-list compilation, validation, and Core surface integration passed"

isFill, isStroke, isClip, isTransform, isOpacity, isText :: DrawingCommand -> Bool
isFill FillGeometry {} = True
isFill _ = False
isStroke StrokeGeometry {} = True
isStroke _ = False
isClip ClipGeometry {} = True
isClip _ = False
isTransform ConcatTransform {} = True
isTransform _ = False
isOpacity BeginOpacity {} = True
isOpacity _ = False
isText DrawTextCommand {} = True
isText _ = False

assert :: String -> Bool -> IO ()
assert label condition = if condition then pure () else error (label <> " failed")
