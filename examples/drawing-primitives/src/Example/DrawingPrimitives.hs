{-# LANGUAGE OverloadedStrings #-}

module Example.DrawingPrimitives
  ( application
  , galleryDrawing
  , gallerySurfaceKey
  , galleryWindowKey
  ) where

import Data.Text (Text)
import HaskeLUI.Core

gallerySurfaceKey :: ElementKey
gallerySurfaceKey = ElementKey 7001

galleryWindowKey :: WindowKey
galleryWindowKey = WindowKey 7000

application :: App ()
application =
  App
    { appInitialModel = ()
    , appInitialEffects = []
    , appInitialCommands = []
    , appServices = []
    , appSubscriptions = const []
    , appView = const galleryView
    , appHandleEvent = \_ _ -> noTransaction
    }

galleryView :: AppView
galleryView =
  AppView
    [ WindowSpec
        galleryWindowKey
        "HaskeLUI portable drawing primitives"
        (Rect 80 80 1100 780)
        [ DrawingSurface
            DrawingSurfaceSpec
              { drawingSurfaceKey = gallerySurfaceKey
              , drawingSurfaceFrame = Rect 20 20 1060 740
              , drawingSurfaceRevision = DrawingRevision 1
              , drawingSurfaceDrawing = galleryDrawing
              , drawingSurfaceIntrinsicMetrics =
                  IntrinsicMetrics
                    (Size 640 420)
                    (Size 1060 740)
                    (Size 1600 1200)
                    Nothing
                    Nothing
              , drawingSurfaceAccessibleLabel =
                  "Gallery of portable rectangles, paths, strokes, transforms, clipping, opacity, and text"
              }
        ]
    ]
    []

galleryDrawing :: Drawing
galleryDrawing =
  Group
    [ Fill NonZero (paintRGBA 0.965 0.97 0.985 1) (Rectangle (Rect 0 0 1060 740))
    , title "Portable retained 2D drawing" (Rect 28 20 720 38) 28 TextStart
    , caption "Logical units · top-left origin · immutable display list · Core Graphics executor" (Rect 30 58 900 24)
    , sectionFrame (Rect 24 96 318 250)
    , sectionTitle "Geometry + fill rules" (Rect 40 108 280 24)
    , Fill NonZero (Solid coral) (Rectangle (Rect 44 150 72 58))
    , Fill NonZero (Solid mint) (RoundedRectangle (Rect 132 150 82 58) 14 14)
    , Fill NonZero (Solid blue) (Ellipse (Rect 232 150 76 58))
    , caption "rect" (Rect 44 216 72 20)
    , caption "rounded" (Rect 132 216 82 20)
    , caption "ellipse" (Rect 232 216 76 20)
    , Fill EvenOdd (Solid purple) (PathGeometry evenOddPath)
    , caption "Even-odd compound path" (Rect 56 316 250 20)
    , sectionFrame (Rect 364 96 672 250)
    , sectionTitle "Paths + stroke styles" (Rect 380 108 300 24)
    , Stroke (stroke 5 RoundCap RoundJoin [] 0) (Solid coral) (PathGeometry curvePath)
    , Stroke (stroke 4 ButtCap MiterJoin [12, 7] 0) (Solid blue) (PathGeometry zigZagPath)
    , Stroke (stroke 8 SquareCap BevelJoin [2, 9] 4) (Solid mint) (PathGeometry baselinePath)
    , caption "quadratic + cubic / round" (Rect 386 218 210 20)
    , caption "miter dash" (Rect 616 218 150 20)
    , caption "square cap / bevel / dot" (Rect 790 218 220 20)
    , Stroke (stroke 10 ButtCap MiterJoin [] 0) (Solid ink) (PathGeometry (Path [MoveTo (Point 410 288), LineTo (Point 470 288)]))
    , Stroke (stroke 10 RoundCap RoundJoin [] 0) (Solid ink) (PathGeometry (Path [MoveTo (Point 520 288), LineTo (Point 580 288)]))
    , Stroke (stroke 10 SquareCap BevelJoin [] 0) (Solid ink) (PathGeometry (Path [MoveTo (Point 630 288), LineTo (Point 690 288)]))
    , caption "butt" (Rect 416 306 60 18)
    , caption "round" (Rect 526 306 60 18)
    , caption "square" (Rect 636 306 70 18)
    , sectionFrame (Rect 24 366 498 166)
    , sectionTitle "Transforms + opacity" (Rect 40 378 280 24)
    , Transform
        (translation 150 466)
        ( Transform
            (rotation (-0.28))
            (Group
              [ Fill NonZero (Solid blue) (RoundedRectangle (Rect (-58) (-34) 116 68) 12 12)
              , title "rotate" (Rect (-48) (-13) 96 26) 16 TextCenter
              ])
        )
    , Transform
        (translation 312 430)
        (Transform (scaling 1.35 0.75) (Fill NonZero (Solid mint) (Ellipse (Rect 0 0 92 82))))
    , Opacity
        0.48
        ( Group
            [ Fill NonZero (Solid coral) (Ellipse (Rect 388 424 82 82))
            , Fill NonZero (Solid blue) (Ellipse (Rect 430 424 82 82))
            ]
        )
    , sectionFrame (Rect 542 366 494 166)
    , sectionTitle "Nested clipping" (Rect 558 378 280 24)
    , Clip
        EvenOdd
        (RoundedRectangle (Rect 574 418 430 88) 24 24)
        ( Group
            [ Fill NonZero (paintRGBA 0.10 0.13 0.24 1) (Rectangle (Rect 560 400 470 125))
            , Transform (rotation (-0.12)) clippedStripes
            ]
        )
    , sectionFrame (Rect 24 552 1012 164)
    , sectionTitle "Text layout inside explicit rectangles" (Rect 40 564 420 24)
    , textCard TextStart TextTop NoWrap "Start / top / no-wrap" (Rect 44 606 292 82)
    , textCard TextCenter TextMiddle WordWrap "Centered and vertically aligned. This text wraps by words." (Rect 384 606 292 82)
    , textCard TextEnd TextBottom CharacterWrap "End aligned · character wrapping" (Rect 724 606 292 82)
    , Empty
    ]

sectionFrame :: Rect -> Drawing
sectionFrame rect =
  Group
    [ Fill NonZero (paintRGBA 1 1 1 0.92) (RoundedRectangle rect 12 12)
    , Stroke (defaultStrokeStyle {strokeWidth = 1}) (paintRGBA 0.78 0.80 0.87 1) (RoundedRectangle rect 12 12)
    ]

sectionTitle :: Text -> Rect -> Drawing
sectionTitle value rect = title value rect 16 TextStart

title :: Text -> Rect -> Double -> HorizontalTextAlignment -> Drawing
title value rect size alignment =
  DrawText
    TextDraw
      { drawnText = value
      , drawnTextRect = rect
      , drawnTextStyle =
          mempty
            { textForeground = Just ink
            , textFontFamily = Just SystemFont
            , textFontWeight = Just SemiBold
            , textFontSize = Just size
            }
      , drawnTextHorizontalAlignment = alignment
      , drawnTextVerticalAlignment = TextTop
      , drawnTextWrapping = NoWrap
      }

caption :: Text -> Rect -> Drawing
caption value rect =
  DrawText $
    TextDraw
      value
      rect
      (mempty {textForeground = Just muted, textFontSize = Just 12})
      TextStart
      TextTop
      NoWrap

textCard :: HorizontalTextAlignment -> VerticalTextAlignment -> TextWrapping -> Text -> Rect -> Drawing
textCard horizontal vertical wrapping value rect =
  Group
    [ Fill NonZero (paintRGBA 0.94 0.95 0.98 1) (RoundedRectangle rect 10 10)
    , DrawText
        TextDraw
          { drawnText = value
          , drawnTextRect = insetRect 12 rect
          , drawnTextStyle =
              mempty
                { textForeground = Just ink
                , textFontFamily = Just MonospaceFont
                , textFontSize = Just 13
                , textLetterSpacing = Just 0.2
                }
          , drawnTextHorizontalAlignment = horizontal
          , drawnTextVerticalAlignment = vertical
          , drawnTextWrapping = wrapping
          }
    ]

insetRect :: Double -> Rect -> Rect
insetRect inset (Rect x y width height) =
  Rect (x + inset) (y + inset) (width - 2 * inset) (height - 2 * inset)

clippedStripes :: Drawing
clippedStripes =
  Group
    [ Fill NonZero (Solid color) (Rectangle (Rect x 340 28 240))
    | (x, color) <- zip [520, 568 .. 1048] (cycle [coral, mint, blue, purple])
    ]

evenOddPath :: Path
evenOddPath =
  Path
    [ MoveTo (Point 74 230)
    , CubicTo (Point 74 210) (Point 104 210) (Point 104 230)
    , LineTo (Point 104 278)
    , CubicTo (Point 104 298) (Point 74 298) (Point 74 278)
    , ClosePath
    , MoveTo (Point 84 242)
    , LineTo (Point 94 242)
    , LineTo (Point 94 266)
    , LineTo (Point 84 266)
    , ClosePath
    ]

curvePath :: Path
curvePath =
  Path
    [ MoveTo (Point 392 188)
    , QuadraticTo (Point 438 128) (Point 484 188)
    , CubicTo (Point 520 234) (Point 558 128) (Point 596 188)
    ]

zigZagPath :: Path
zigZagPath =
  Path
    [ MoveTo (Point 620 190)
    , LineTo (Point 654 146)
    , LineTo (Point 688 194)
    , LineTo (Point 722 146)
    , LineTo (Point 756 194)
    ]

baselinePath :: Path
baselinePath = Path [MoveTo (Point 796 170), LineTo (Point 996 170)]

stroke :: Double -> LineCap -> LineJoin -> [Double] -> Double -> StrokeStyle
stroke width cap join dash phase =
  defaultStrokeStyle
    { strokeWidth = width
    , strokeLineCap = cap
    , strokeLineJoin = join
    , strokeDashPattern = dash
    , strokeDashPhase = phase
    }

paintRGBA :: Double -> Double -> Double -> Double -> Paint
paintRGBA red green blueValue alpha = Solid (RGBA red green blueValue alpha)

ink, muted, coral, mint, blue, purple :: Color
ink = RGBA 0.10 0.12 0.18 1
muted = RGBA 0.38 0.41 0.50 1
coral = RGBA 0.93 0.30 0.32 1
mint = RGBA 0.14 0.72 0.55 1
blue = RGBA 0.18 0.45 0.93 1
purple = RGBA 0.56 0.30 0.88 1
