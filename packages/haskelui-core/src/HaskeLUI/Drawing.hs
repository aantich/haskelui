{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

-- | A small retained, backend-neutral 2D drawing language.
--
-- Coordinates are logical units with a top-left origin and positive Y down.
-- Drawings are immutable values; backends compile them to their native
-- display representation and never call Haskell from a paint callback.
module HaskeLUI.Drawing
  ( DrawingRevision (..)
  , Point (..)
  , Affine2 (..)
  , identityAffine
  , translation
  , scaling
  , rotation
  , FillRule (..)
  , Paint (..)
  , LineCap (..)
  , LineJoin (..)
  , StrokeStyle (..)
  , defaultStrokeStyle
  , PathSegment (..)
  , Path (..)
  , Geometry (..)
  , HorizontalTextAlignment (..)
  , VerticalTextAlignment (..)
  , TextWrapping (..)
  , TextDraw (..)
  , Drawing (..)
  , DrawingCommand (..)
  , DrawingValidationError (..)
  , compileDrawing
  , validateDrawing
  ) where

import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word64)
import HaskeLUI.Graphics.Types

newtype DrawingRevision = DrawingRevision {unDrawingRevision :: Word64}
  deriving stock (Eq, Ord, Show)

data Point = Point
  { pointX :: !Double
  , pointY :: !Double
  }
  deriving stock (Eq, Show)

-- | The matrix [a c tx; b d ty; 0 0 1].
data Affine2 = Affine2
  { affineA :: !Double
  , affineB :: !Double
  , affineC :: !Double
  , affineD :: !Double
  , affineTx :: !Double
  , affineTy :: !Double
  }
  deriving stock (Eq, Show)

identityAffine :: Affine2
identityAffine = Affine2 1 0 0 1 0 0

translation :: Double -> Double -> Affine2
translation x y = Affine2 1 0 0 1 x y

scaling :: Double -> Double -> Affine2
scaling x y = Affine2 x 0 0 y 0 0

rotation :: Double -> Affine2
rotation radians =
  let cosine = cos radians
      sine = sin radians
   in Affine2 cosine sine (-sine) cosine 0 0

data FillRule = NonZero | EvenOdd
  deriving stock (Eq, Ord, Show)

data Paint = Solid !Color
  deriving stock (Eq, Show)

data LineCap = ButtCap | RoundCap | SquareCap
  deriving stock (Eq, Ord, Show)

data LineJoin = MiterJoin | RoundJoin | BevelJoin
  deriving stock (Eq, Ord, Show)

data StrokeStyle = StrokeStyle
  { strokeWidth :: !Double
  , strokeLineCap :: !LineCap
  , strokeLineJoin :: !LineJoin
  , strokeMiterLimit :: !Double
  , strokeDashPattern :: ![Double]
  , strokeDashPhase :: !Double
  }
  deriving stock (Eq, Show)

defaultStrokeStyle :: StrokeStyle
defaultStrokeStyle = StrokeStyle 1 ButtCap MiterJoin 10 [] 0

data PathSegment
  = MoveTo !Point
  | LineTo !Point
  | QuadraticTo !Point !Point
  | CubicTo !Point !Point !Point
  | ClosePath
  deriving stock (Eq, Show)

newtype Path = Path {pathSegments :: [PathSegment]}
  deriving stock (Eq, Show)

data Geometry
  = Rectangle !Rect
  | RoundedRectangle !Rect !Double !Double
  | Ellipse !Rect
  | PathGeometry !Path
  deriving stock (Eq, Show)

data HorizontalTextAlignment = TextStart | TextCenter | TextEnd
  deriving stock (Eq, Ord, Show)

data VerticalTextAlignment = TextTop | TextMiddle | TextBottom
  deriving stock (Eq, Ord, Show)

data TextWrapping = NoWrap | WordWrap | CharacterWrap
  deriving stock (Eq, Ord, Show)

data TextDraw = TextDraw
  { drawnText :: !Text
  , drawnTextRect :: !Rect
  , drawnTextStyle :: !TextStyle
  , drawnTextHorizontalAlignment :: !HorizontalTextAlignment
  , drawnTextVerticalAlignment :: !VerticalTextAlignment
  , drawnTextWrapping :: !TextWrapping
  }
  deriving stock (Eq, Show)

data Drawing
  = Empty
  | Group ![Drawing]
  | Transform !Affine2 !Drawing
  | Clip !FillRule !Geometry !Drawing
  | Opacity !Double !Drawing
  | Fill !FillRule !Paint !Geometry
  | Stroke !StrokeStyle !Paint !Geometry
  | DrawText !TextDraw
  deriving stock (Eq, Show)

-- | Normalized commands consumed by backends and headless snapshot tests.
data DrawingCommand
  = PushState
  | PopState
  | ConcatTransform !Affine2
  | ClipGeometry !FillRule !Geometry
  | BeginOpacity !Double
  | EndOpacity
  | FillGeometry !FillRule !Paint !Geometry
  | StrokeGeometry !StrokeStyle !Paint !Geometry
  | DrawTextCommand !TextDraw
  deriving stock (Eq, Show)

newtype DrawingValidationError = DrawingValidationError
  { drawingValidationMessage :: Text
  }
  deriving stock (Eq, Show)

compileDrawing :: Drawing -> [DrawingCommand]
compileDrawing = \case
  Empty -> []
  Group drawings -> foldMap compileDrawing drawings
  Transform affine drawing ->
    [PushState, ConcatTransform affine]
      <> compileDrawing drawing
      <> [PopState]
  Clip rule geometry drawing ->
    [PushState, ClipGeometry rule geometry]
      <> compileDrawing drawing
      <> [PopState]
  Opacity alpha drawing ->
    [BeginOpacity alpha]
      <> compileDrawing drawing
      <> [EndOpacity]
  Fill rule paint geometry -> [FillGeometry rule paint geometry]
  Stroke style paint geometry -> [StrokeGeometry style paint geometry]
  DrawText text -> [DrawTextCommand text]

validateDrawing :: Drawing -> [DrawingValidationError]
validateDrawing drawing = validateCommands 0 (compileDrawing drawing)
  where
    validateCommands _ [] = []
    validateCommands index (command : rest) =
      validateCommand index command <> validateCommands (index + 1) rest

validateCommand :: Int -> DrawingCommand -> [DrawingValidationError]
validateCommand index command =
  prefix $ case command of
    PushState -> []
    PopState -> []
    ConcatTransform affine ->
      requireFinite "transform" [affine.affineA, affine.affineB, affine.affineC, affine.affineD, affine.affineTx, affine.affineTy]
    ClipGeometry _ geometry -> validateGeometry geometry
    BeginOpacity alpha -> requireUnit "opacity" alpha
    EndOpacity -> []
    FillGeometry _ paint geometry -> validatePaint paint <> validateGeometry geometry
    StrokeGeometry style paint geometry -> validateStroke style <> validatePaint paint <> validateGeometry geometry
    DrawTextCommand text -> validateText text
  where
    prefix = fmap (\(DrawingValidationError message) -> DrawingValidationError ("command " <> Text.pack (show index) <> ": " <> message))

validatePaint :: Paint -> [DrawingValidationError]
validatePaint (Solid color) =
  requireUnit "red" color.colorRed
    <> requireUnit "green" color.colorGreen
    <> requireUnit "blue" color.colorBlue
    <> requireUnit "alpha" color.colorAlpha

validateStroke :: StrokeStyle -> [DrawingValidationError]
validateStroke style =
  requireNonnegative "stroke width" style.strokeWidth
    <> requirePositive "miter limit" style.strokeMiterLimit
    <> requireFinite "dash phase" [style.strokeDashPhase]
    <> concatMap (requireNonnegative "dash component") style.strokeDashPattern
    <> [DrawingValidationError "a non-empty dash pattern must contain a positive component" | not (null style.strokeDashPattern) && not (any (> 0) style.strokeDashPattern)]

validateGeometry :: Geometry -> [DrawingValidationError]
validateGeometry = \case
  Rectangle rect -> validateRect rect
  RoundedRectangle rect radiusX radiusY ->
    validateRect rect
      <> requireNonnegative "horizontal corner radius" radiusX
      <> requireNonnegative "vertical corner radius" radiusY
  Ellipse rect -> validateRect rect
  PathGeometry (Path segments) -> validatePath False segments

validatePath :: Bool -> [PathSegment] -> [DrawingValidationError]
validatePath _ [] = []
validatePath hasCurrentPoint (segment : rest) =
  case segment of
    MoveTo point -> validatePoint point <> validatePath True rest
    LineTo point -> requireCurrent "line" <> validatePoint point <> validatePath True rest
    QuadraticTo control end -> requireCurrent "quadratic curve" <> validatePoint control <> validatePoint end <> validatePath True rest
    CubicTo first second end -> requireCurrent "cubic curve" <> validatePoint first <> validatePoint second <> validatePoint end <> validatePath True rest
    ClosePath -> requireCurrent "close path" <> validatePath hasCurrentPoint rest
  where
    requireCurrent operation = [DrawingValidationError (operation <> " requires a preceding move") | not hasCurrentPoint]

validatePoint :: Point -> [DrawingValidationError]
validatePoint point = requireFinite "point" [point.pointX, point.pointY]

validateRect :: Rect -> [DrawingValidationError]
validateRect rect =
  requireFinite "rectangle" [rect.rectX, rect.rectY, rect.rectWidth, rect.rectHeight]
    <> requireNonnegative "rectangle width" rect.rectWidth
    <> requireNonnegative "rectangle height" rect.rectHeight

validateText :: TextDraw -> [DrawingValidationError]
validateText text =
  validateRect text.drawnTextRect
    <> maybe [] (requirePositive "font size") text.drawnTextStyle.textFontSize
    <> maybe [] (requireFinite "letter spacing" . pure) text.drawnTextStyle.textLetterSpacing
    <> maybe [] (requireFinite "baseline offset" . pure) text.drawnTextStyle.textBaselineOffset
    <> maybe [] validateColor text.drawnTextStyle.textForeground
    <> maybe [] validateColor text.drawnTextStyle.textBackground
  where
    validateColor color = validatePaint (Solid color)

requireFinite :: Text -> [Double] -> [DrawingValidationError]
requireFinite label values =
  [ DrawingValidationError (label <> " must contain only finite values")
  | any (\value -> isNaN value || isInfinite value) values
  ]

requireNonnegative :: Text -> Double -> [DrawingValidationError]
requireNonnegative label value =
  requireFinite label [value]
    <> [DrawingValidationError (label <> " must be nonnegative") | value < 0]

requirePositive :: Text -> Double -> [DrawingValidationError]
requirePositive label value =
  requireFinite label [value]
    <> [DrawingValidationError (label <> " must be greater than zero") | value <= 0]

requireUnit :: Text -> Double -> [DrawingValidationError]
requireUnit label value =
  requireFinite label [value]
    <> [DrawingValidationError (label <> " must be between zero and one") | value < 0 || value > 1]
