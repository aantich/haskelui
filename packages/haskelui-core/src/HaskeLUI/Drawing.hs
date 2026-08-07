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
  , composeAffine
  , applyAffine
  , invertAffine
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
  , DrawingHitRegionKey (..)
  , DrawingCursor (..)
  , DrawingHitShape (..)
  , DrawingHitTest (..)
  , DrawingHitResult (..)
  , DrawingInputMode (..)
  , DrawingPointerId (..)
  , DrawingPointerButton (..)
  , DrawingPointerButtons (..)
  , noDrawingPointerButtons
  , DrawingModifiers (..)
  , noDrawingModifiers
  , DrawingPointerPhase (..)
  , DrawingPointerEvent (..)
  , DrawingScrollEvent (..)
  , DrawingInput (..)
  , compileDrawing
  , validateDrawing
  , validateDrawingHitTest
  , hitTestDrawing
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

-- | Compose transforms so that the right-hand transform is applied first.
composeAffine :: Affine2 -> Affine2 -> Affine2
composeAffine outer inner =
  Affine2
    (outer.affineA * inner.affineA + outer.affineC * inner.affineB)
    (outer.affineB * inner.affineA + outer.affineD * inner.affineB)
    (outer.affineA * inner.affineC + outer.affineC * inner.affineD)
    (outer.affineB * inner.affineC + outer.affineD * inner.affineD)
    (outer.affineA * inner.affineTx + outer.affineC * inner.affineTy + outer.affineTx)
    (outer.affineB * inner.affineTx + outer.affineD * inner.affineTy + outer.affineTy)

applyAffine :: Affine2 -> Point -> Point
applyAffine affine point =
  Point
    (affine.affineA * point.pointX + affine.affineC * point.pointY + affine.affineTx)
    (affine.affineB * point.pointX + affine.affineD * point.pointY + affine.affineTy)

invertAffine :: Affine2 -> Maybe Affine2
invertAffine affine
  | not (finite determinant) || abs determinant <= 1e-12 = Nothing
  | otherwise =
      let inverseA = affine.affineD / determinant
          inverseB = -affine.affineB / determinant
          inverseC = -affine.affineC / determinant
          inverseD = affine.affineA / determinant
       in Just
            ( Affine2
                inverseA
                inverseB
                inverseC
                inverseD
                (-(inverseA * affine.affineTx + inverseC * affine.affineTy))
                (-(inverseB * affine.affineTx + inverseD * affine.affineTy))
            )
  where
    determinant = affine.affineA * affine.affineD - affine.affineB * affine.affineC
    finite value = not (isNaN value || isInfinite value)

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

newtype DrawingHitRegionKey = DrawingHitRegionKey {unDrawingHitRegionKey :: Word64}
  deriving stock (Eq, Ord, Show)

data DrawingCursor
  = DefaultCursor
  | PointingHandCursor
  | CrosshairCursor
  | OpenHandCursor
  | ClosedHandCursor
  | TextCursor
  | HorizontalResizeCursor
  | VerticalResizeCursor
  deriving stock (Eq, Ord, Show)

data DrawingHitShape
  = HitFill !FillRule !Geometry
  | HitStroke !StrokeStyle !Geometry
  deriving stock (Eq, Show)

-- | Semantic hit testing mirrors drawing state. Groups are ordered back to
-- front, so the last matching region wins. Hit shapes are deliberately
-- separate from paint: interaction remains stable when visual styling changes.
data DrawingHitTest
  = NoDrawingHitTest
  | DrawingHitGroup ![DrawingHitTest]
  | DrawingHitTransform !Affine2 !DrawingHitTest
  | DrawingHitClip !FillRule !Geometry !DrawingHitTest
  | DrawingHitRegion !DrawingHitRegionKey !DrawingCursor !DrawingHitShape
  deriving stock (Eq, Show)

data DrawingHitResult = DrawingHitResult
  { drawingHitResultKey :: !DrawingHitRegionKey
  , drawingHitResultCursor :: !DrawingCursor
  }
  deriving stock (Eq, Show)

data DrawingInputMode
  = DrawingInputDisabled
  | DrawingInputEnabled
  deriving stock (Eq, Ord, Show)

newtype DrawingPointerId = DrawingPointerId {unDrawingPointerId :: Word64}
  deriving stock (Eq, Ord, Show)

data DrawingPointerButton
  = PrimaryPointerButton
  | SecondaryPointerButton
  | MiddlePointerButton
  | BackPointerButton
  | ForwardPointerButton
  deriving stock (Eq, Ord, Show)

data DrawingPointerButtons = DrawingPointerButtons
  { primaryPointerButtonPressed :: !Bool
  , secondaryPointerButtonPressed :: !Bool
  , middlePointerButtonPressed :: !Bool
  , backPointerButtonPressed :: !Bool
  , forwardPointerButtonPressed :: !Bool
  }
  deriving stock (Eq, Show)

noDrawingPointerButtons :: DrawingPointerButtons
noDrawingPointerButtons = DrawingPointerButtons False False False False False

data DrawingModifiers = DrawingModifiers
  { drawingShiftPressed :: !Bool
  , drawingControlPressed :: !Bool
  , drawingAltPressed :: !Bool
  , drawingMetaPressed :: !Bool
  }
  deriving stock (Eq, Show)

noDrawingModifiers :: DrawingModifiers
noDrawingModifiers = DrawingModifiers False False False False

data DrawingPointerPhase
  = DrawingPointerDown
  | DrawingPointerMoved
  | DrawingPointerUp
  | DrawingPointerCancelled
  | DrawingPointerEntered
  | DrawingPointerExited
  deriving stock (Eq, Ord, Show)

data DrawingPointerEvent = DrawingPointerEvent
  { drawingPointerId :: !DrawingPointerId
  , drawingPointerPhase :: !DrawingPointerPhase
  , drawingPointerPosition :: !Point
  , drawingPointerDelta :: !Point
  , drawingPointerChangedButton :: !(Maybe DrawingPointerButton)
  , drawingPointerButtons :: !DrawingPointerButtons
  , drawingPointerModifiers :: !DrawingModifiers
  , drawingPointerClickCount :: !Int
  , drawingPointerTarget :: !(Maybe DrawingHitResult)
  }
  deriving stock (Eq, Show)

data DrawingScrollEvent = DrawingScrollEvent
  { drawingScrollPosition :: !Point
  , drawingScrollDelta :: !Point
  , drawingScrollIsPrecise :: !Bool
  , drawingScrollModifiers :: !DrawingModifiers
  , drawingScrollTarget :: !(Maybe DrawingHitResult)
  }
  deriving stock (Eq, Show)

data DrawingInput
  = DrawingPointerInput !DrawingPointerEvent
  | DrawingScrollInput !DrawingScrollEvent
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

validateDrawingHitTest :: DrawingHitTest -> [DrawingValidationError]
validateDrawingHitTest = go "hit test"
  where
    go _ NoDrawingHitTest = []
    go context (DrawingHitGroup children) =
      concat
        [ go (context <> " group " <> Text.pack (show index)) child
        | (index, child) <- zip [(0 :: Int) ..] children
        ]
    go context (DrawingHitTransform affine child) =
      prefix context
        (requireFinite "transform" [affine.affineA, affine.affineB, affine.affineC, affine.affineD, affine.affineTx, affine.affineTy])
        <> go context child
    go context (DrawingHitClip _ geometry child) =
      prefix context (validateGeometry geometry) <> go context child
    go context (DrawingHitRegion _ _ shape) =
      prefix context $ case shape of
        HitFill _ geometry -> validateGeometry geometry
        HitStroke style geometry -> validateStroke style <> validateGeometry geometry
    prefix context =
      fmap
        (\(DrawingValidationError message) ->
          DrawingValidationError (context <> ": " <> message)
        )

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

-- | Resolve the topmost semantic region at a surface-local point. Transform
-- inversion and clipping happen in the same nested order as drawing state.
hitTestDrawing :: Point -> DrawingHitTest -> Maybe DrawingHitResult
hitTestDrawing point = go point
  where
    go _ NoDrawingHitTest = Nothing
    go localPoint (DrawingHitGroup children) = firstJust (fmap (go localPoint) (reverse children))
    go localPoint (DrawingHitTransform affine child) = do
      inverse <- invertAffine affine
      go (applyAffine inverse localPoint) child
    go localPoint (DrawingHitClip rule geometry child)
      | pointInGeometry rule localPoint geometry = go localPoint child
      | otherwise = Nothing
    go localPoint (DrawingHitRegion key cursor shape)
      | pointInHitShape localPoint shape = Just (DrawingHitResult key cursor)
      | otherwise = Nothing

firstJust :: [Maybe value] -> Maybe value
firstJust [] = Nothing
firstJust (Just value : _) = Just value
firstJust (Nothing : rest) = firstJust rest

pointInHitShape :: Point -> DrawingHitShape -> Bool
pointInHitShape point = \case
  HitFill rule geometry -> pointInGeometry rule point geometry
  HitStroke style geometry -> pointOnGeometryStroke style point geometry

pointInGeometry :: FillRule -> Point -> Geometry -> Bool
pointInGeometry rule point geometry =
  case geometry of
    Rectangle rect -> pointInRect point rect
    RoundedRectangle rect radiusX radiusY -> pointInRoundedRect point rect radiusX radiusY
    Ellipse rect -> pointInEllipse point rect
    PathGeometry path -> pointInPolygons rule point (flattenPath path)

pointOnGeometryStroke :: StrokeStyle -> Point -> Geometry -> Bool
pointOnGeometryStroke style point geometry =
  let radius = max 0.5 (style.strokeWidth / 2)
      paths = geometryPolylines geometry
   in any (polylineNearPoint radius point) paths

pointInRect :: Point -> Rect -> Bool
pointInRect point rect =
  point.pointX >= rect.rectX
    && point.pointY >= rect.rectY
    && point.pointX <= rect.rectX + rect.rectWidth
    && point.pointY <= rect.rectY + rect.rectHeight

pointInRoundedRect :: Point -> Rect -> Double -> Double -> Bool
pointInRoundedRect point rect requestedRadiusX requestedRadiusY
  | not (pointInRect point rect) = False
  | radiusX <= 0 || radiusY <= 0 = True
  | point.pointX >= left + radiusX && point.pointX <= right - radiusX = True
  | point.pointY >= top + radiusY && point.pointY <= bottom - radiusY = True
  | otherwise =
      let centerX = if point.pointX < left + radiusX then left + radiusX else right - radiusX
          centerY = if point.pointY < top + radiusY then top + radiusY else bottom - radiusY
          normalizedX = (point.pointX - centerX) / radiusX
          normalizedY = (point.pointY - centerY) / radiusY
       in normalizedX * normalizedX + normalizedY * normalizedY <= 1
  where
    left = rect.rectX
    right = rect.rectX + rect.rectWidth
    top = rect.rectY
    bottom = rect.rectY + rect.rectHeight
    radiusX = min (max 0 requestedRadiusX) (rect.rectWidth / 2)
    radiusY = min (max 0 requestedRadiusY) (rect.rectHeight / 2)

pointInEllipse :: Point -> Rect -> Bool
pointInEllipse point rect
  | rect.rectWidth <= 0 || rect.rectHeight <= 0 = False
  | otherwise =
      let radiusX = rect.rectWidth / 2
          radiusY = rect.rectHeight / 2
          centerX = rect.rectX + radiusX
          centerY = rect.rectY + radiusY
          normalizedX = (point.pointX - centerX) / radiusX
          normalizedY = (point.pointY - centerY) / radiusY
       in normalizedX * normalizedX + normalizedY * normalizedY <= 1

pointInPolygons :: FillRule -> Point -> [[Point]] -> Bool
pointInPolygons EvenOdd point polygons = odd (sum (fmap (crossingCount point) polygons))
pointInPolygons NonZero point polygons = sum (fmap (windingNumber point) polygons) /= 0

crossingCount :: Point -> [Point] -> Int
crossingCount point polygon =
  length
    [ ()
    | (start, end) <- closedSegments polygon
    , (start.pointY > point.pointY) /= (end.pointY > point.pointY)
    , let crossingX = start.pointX + (point.pointY - start.pointY) * (end.pointX - start.pointX) / (end.pointY - start.pointY)
    , point.pointX < crossingX
    ]

windingNumber :: Point -> [Point] -> Int
windingNumber point = sum . fmap contribution . closedSegments
  where
    contribution (start, end)
      | start.pointY <= point.pointY
          && end.pointY > point.pointY
          && isLeft start end point > 0 = 1
      | start.pointY > point.pointY
          && end.pointY <= point.pointY
          && isLeft start end point < 0 = -1
      | otherwise = 0

isLeft :: Point -> Point -> Point -> Double
isLeft start end point =
  (end.pointX - start.pointX) * (point.pointY - start.pointY)
    - (point.pointX - start.pointX) * (end.pointY - start.pointY)

closedSegments :: [Point] -> [(Point, Point)]
closedSegments [] = []
closedSegments [_] = []
closedSegments points = zip points (drop 1 points <> take 1 points)

geometryPolylines :: Geometry -> [[Point]]
geometryPolylines = \case
  Rectangle rect -> [rectPoints rect]
  RoundedRectangle rect radiusX radiusY -> [roundedRectPoints rect radiusX radiusY]
  Ellipse rect -> [ellipsePoints rect]
  PathGeometry path -> flattenPath path

polylineNearPoint :: Double -> Point -> [Point] -> Bool
polylineNearPoint _ _ [] = False
polylineNearPoint radius point points =
  any (\(start, end) -> distanceToSegment point start end <= radius) (zip points (drop 1 points))

distanceToSegment :: Point -> Point -> Point -> Double
distanceToSegment point start end
  | lengthSquared <= 1e-18 = distance point start
  | otherwise =
      let projection =
            ((point.pointX - start.pointX) * deltaX + (point.pointY - start.pointY) * deltaY)
              / lengthSquared
          parameter = max 0 (min 1 projection)
          closest = Point (start.pointX + parameter * deltaX) (start.pointY + parameter * deltaY)
       in distance point closest
  where
    deltaX = end.pointX - start.pointX
    deltaY = end.pointY - start.pointY
    lengthSquared = deltaX * deltaX + deltaY * deltaY

distance :: Point -> Point -> Double
distance left right =
  sqrt ((left.pointX - right.pointX) ^ (2 :: Int) + (left.pointY - right.pointY) ^ (2 :: Int))

rectPoints :: Rect -> [Point]
rectPoints rect =
  [ Point rect.rectX rect.rectY
  , Point (rect.rectX + rect.rectWidth) rect.rectY
  , Point (rect.rectX + rect.rectWidth) (rect.rectY + rect.rectHeight)
  , Point rect.rectX (rect.rectY + rect.rectHeight)
  , Point rect.rectX rect.rectY
  ]

ellipsePoints :: Rect -> [Point]
ellipsePoints rect =
  [ Point
      (centerX + radiusX * cos angle)
      (centerY + radiusY * sin angle)
  | index <- [0 .. sampleCount]
  , let angle = 2 * pi * fromIntegral index / fromIntegral sampleCount
  ]
  where
    sampleCount = 48 :: Int
    radiusX = rect.rectWidth / 2
    radiusY = rect.rectHeight / 2
    centerX = rect.rectX + radiusX
    centerY = rect.rectY + radiusY

roundedRectPoints :: Rect -> Double -> Double -> [Point]
roundedRectPoints rect requestedRadiusX requestedRadiusY
  | radiusX <= 0 || radiusY <= 0 = rectPoints rect
  | otherwise =
      concat
        [ arc (right - radiusX) (top + radiusY) (-pi / 2) 0
        , arc (right - radiusX) (bottom - radiusY) 0 (pi / 2)
        , arc (left + radiusX) (bottom - radiusY) (pi / 2) pi
        , arc (left + radiusX) (top + radiusY) pi (3 * pi / 2)
        ]
        <> [Point (right - radiusX) top]
  where
    left = rect.rectX
    right = rect.rectX + rect.rectWidth
    top = rect.rectY
    bottom = rect.rectY + rect.rectHeight
    radiusX = min (max 0 requestedRadiusX) (rect.rectWidth / 2)
    radiusY = min (max 0 requestedRadiusY) (rect.rectHeight / 2)
    arc centerX centerY start end =
      [ Point
          (centerX + radiusX * cos angle)
          (centerY + radiusY * sin angle)
      | index <- [0 .. (8 :: Int)]
      , let angle = start + (end - start) * fromIntegral index / 8
      ]

flattenPath :: Path -> [[Point]]
flattenPath (Path segments) = finish (foldl step initial segments)
  where
    initial = ([], [], Nothing, Nothing)
    step (completed, current, currentPoint, startPoint) segment =
      case segment of
        MoveTo point ->
          (flush completed current, [point], Just point, Just point)
        LineTo point ->
          (completed, appendFrom current point, Just point, startPoint)
        QuadraticTo control end ->
          case currentPoint of
            Nothing -> (completed, current, Nothing, startPoint)
            Just start ->
              let sampled = [quadraticPoint start control end (fromIntegral index / 16) | index <- [1 .. (16 :: Int)]]
               in (completed, current <> sampled, Just end, startPoint)
        CubicTo first second end ->
          case currentPoint of
            Nothing -> (completed, current, Nothing, startPoint)
            Just start ->
              let sampled = [cubicPoint start first second end (fromIntegral index / 24) | index <- [1 .. (24 :: Int)]]
               in (completed, current <> sampled, Just end, startPoint)
        ClosePath ->
          let closed = case (current, startPoint) of
                ([], _) -> []
                (_, Just start) | last current /= start -> current <> [start]
                _ -> current
           in (flush completed closed, [], Nothing, Nothing)
    appendFrom [] point = [point]
    appendFrom points point = points <> [point]
    flush completed [] = completed
    flush completed points = completed <> [points]
    finish (completed, current, _, _) = flush completed current

quadraticPoint :: Point -> Point -> Point -> Double -> Point
quadraticPoint start control end parameter =
  let remaining = 1 - parameter
   in Point
        (remaining * remaining * start.pointX + 2 * remaining * parameter * control.pointX + parameter * parameter * end.pointX)
        (remaining * remaining * start.pointY + 2 * remaining * parameter * control.pointY + parameter * parameter * end.pointY)

cubicPoint :: Point -> Point -> Point -> Point -> Double -> Point
cubicPoint start first second end parameter =
  let remaining = 1 - parameter
   in Point
        ( remaining ^ (3 :: Int) * start.pointX
            + 3 * remaining * remaining * parameter * first.pointX
            + 3 * remaining * parameter * parameter * second.pointX
            + parameter ^ (3 :: Int) * end.pointX
        )
        ( remaining ^ (3 :: Int) * start.pointY
            + 3 * remaining * remaining * parameter * first.pointY
            + 3 * remaining * parameter * parameter * second.pointY
            + parameter ^ (3 :: Int) * end.pointY
        )
