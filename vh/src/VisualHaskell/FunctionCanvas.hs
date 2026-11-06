{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Pure, source-independent function composition workspace. Connections form
-- one linear chain; GHC checks the entire chain, including polymorphism and
-- constraints. Moving a card changes layout only.
module VisualHaskell.FunctionCanvas where

import Data.List (find)
import qualified Data.Map.Strict as Map
import Data.Map.Strict (Map)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word64)
import HaskeLUI.Core hiding (Path)
import qualified HaskeLUI.Core as UI
import VisualHaskell.Semantic (DeclarationId, FunctionNode (..))

data FunctionCanvas = FunctionCanvas
  { canvasNodes :: ![(Word64, DeclarationId)]
  , canvasEdges :: ![(Word64, Word64)]
  , canvasPositions :: !(Map Word64 Point)
  , canvasNextIdentity :: !Word64
  , canvasPendingOutput :: !(Maybe Word64)
  , canvasDragging :: !(Maybe Word64)
  , canvasSelected :: !(Maybe Word64)
  , canvasOffset :: !Point
  , canvasScale :: !Double
  , canvasRevision :: !Word64
  , canvasNotice :: !Text
  }
  deriving stock (Eq, Show)

emptyFunctionCanvas :: FunctionCanvas
emptyFunctionCanvas = FunctionCanvas [] [] Map.empty 1 Nothing Nothing Nothing (Point 0 0) 1 0 ""

-- A successful source revision may remove declarations. Keep layout for the
-- remaining stable identities, but never leave invisible cards or dangling wires.
retainFunctions :: [DeclarationId] -> FunctionCanvas -> FunctionCanvas
retainFunctions available canvas
  | nodes == canvas.canvasNodes = canvas
  | otherwise = canvas
      { canvasNodes = nodes
      , canvasEdges = filter (\(a,b) -> present a && present b) canvas.canvasEdges
      , canvasPositions = Map.filterWithKey (\key _ -> present key) canvas.canvasPositions
      , canvasPendingOutput = canvas.canvasPendingOutput >>= keep
      , canvasDragging = canvas.canvasDragging >>= keep
      , canvasSelected = canvas.canvasSelected >>= keep
      , canvasNotice = "Removed cards whose declarations are no longer present"
      , canvasRevision = canvas.canvasRevision + 1
      }
  where
    nodes = filter ((`elem` available) . snd) canvas.canvasNodes
    present key = any ((== key) . fst) nodes
    keep key = if present key then Just key else Nothing

addFunction :: DeclarationId -> FunctionCanvas -> FunctionCanvas
addFunction function canvas
  | length canvas.canvasNodes >= 32 = canvas {canvasNotice = "A composition can contain up to 32 functions"}
  | otherwise = canvas
      { canvasNodes = canvas.canvasNodes <> [(canvas.canvasNextIdentity, function)]
      , canvasNextIdentity = canvas.canvasNextIdentity + 1
      , canvasRevision = canvas.canvasRevision + 1
      , canvasNotice = "Connect an output circle to an input circle"
      }

connectFunctions :: Word64 -> Word64 -> FunctionCanvas -> FunctionCanvas
connectFunctions output input canvas
  | (output,input) `elem` canvas.canvasEdges = canvas
  | output == input = rejected "A function cannot connect to itself"
  | not (all (\key -> any ((== key) . fst) canvas.canvasNodes) [output,input]) = rejected "Unknown function node"
  | any ((== output) . fst) canvas.canvasEdges || any ((== input) . snd) canvas.canvasEdges = rejected "Each port accepts one connection"
  | reachable Set.empty input output = rejected "A composition chain cannot contain a cycle"
  | otherwise = canvas
      { canvasEdges = canvas.canvasEdges <> [(output,input)]
      , canvasPendingOutput = Nothing
      , canvasRevision = canvas.canvasRevision + 1
      , canvasNotice = ""
      }
  where
    rejected message = canvas {canvasNotice = message, canvasRevision = canvas.canvasRevision + 1}
    reachable seen current destination
      | current == destination = True
      | Set.member current seen = False
      | otherwise = any (\(_,next) -> reachable (Set.insert current seen) next destination)
          (filter ((== current) . fst) canvas.canvasEdges)

compositionChain :: FunctionCanvas -> Either Text [DeclarationId]
compositionChain canvas
  | null canvas.canvasEdges = Right []
  | [root] <- roots =
      let path = walk Set.empty root
       in if length path == Set.size connected
            then traverse (\key -> maybe (Left "Missing function") Right (lookup key canvas.canvasNodes)) path
            else Left "Join the separate chains to check the complete composition"
  | otherwise = Left "Join the separate chains to check the complete composition"
  where
    connected = Set.fromList (concatMap (\(a,b) -> [a,b]) canvas.canvasEdges)
    roots = [key | key <- Set.toList connected, not (any ((== key) . snd) canvas.canvasEdges)]
    walk seen key
      | Set.member key seen = []
      | otherwise = key : case lookup key canvas.canvasEdges of
          Just next -> walk (Set.insert key seen) next
          Nothing -> []

nodePosition :: FunctionCanvas -> Word64 -> Point
nodePosition canvas key = Map.findWithDefault automatic key canvas.canvasPositions
  where
    index = maybe 0 id (findIndex 0 canvas.canvasNodes)
    findIndex _ [] = Nothing
    findIndex n ((identity,_):rest) = if identity == key then Just n else findIndex (n+1) rest
    automatic = Point (36 + fromIntegral (index `mod` 2) * 350) (28 + fromIntegral (index `div` 2) * 190)

canvasTransform :: FunctionCanvas -> Affine2
canvasTransform canvas = composeAffine (translation canvas.canvasOffset.pointX canvas.canvasOffset.pointY) (scaling canvas.canvasScale canvas.canvasScale)

functionCanvasSurface :: ElementKey -> ColorScheme -> [FunctionNode range] -> Maybe Bool -> FunctionCanvas -> Control
functionCanvasSurface key scheme functions compatible canvas = DrawingSurface DrawingSurfaceSpec
  { drawingSurfaceKey = key
  , drawingSurfaceFrame = viewport
  -- Compatibility is asynchronous presentation state, independent of layout
  -- interactions. It must participate in the retained drawing cache key.
  , drawingSurfaceRevision = DrawingRevision (canvas.canvasRevision * 4 + compatibilityRevision)
  , drawingSurfaceDrawing = Group
      [Fill NonZero (Solid background) (Rectangle viewport), Clip NonZero (Rectangle viewport)
        (Transform transform (Group (fmap drawEdge visibleEdges <> fmap drawNode visible)))]
  , drawingSurfaceIntrinsicMetrics = IntrinsicMetrics (Size 200 200) (Size 520 600) (Size 4096 4096) Nothing Nothing
  , drawingSurfaceAccessibleLabel = "Function composition canvas. " <> Text.pack (show (length visible)) <> " functions. "
      <> "Choose functions from the list, add cards, and connect output to input. " <> canvas.canvasNotice
  , drawingSurfaceInputMode = DrawingInputEnabled
  , drawingSurfaceHitTest = DrawingHitClip NonZero (Rectangle viewport) (DrawingHitTransform transform (DrawingHitGroup (concatMap hitNode visible)))
  , drawingSurfaceCursor = maybe OpenHandCursor (const ClosedHandCursor) canvas.canvasDragging
  }
  where
    viewport = Rect 0 0 1600 1800
    compatibilityRevision = case compatible of Nothing -> 0; Just True -> 1; Just False -> 2
    transform = canvasTransform canvas
    dark = scheme == DarkColorScheme
    background = if dark then RGBA 0.12 0.13 0.15 1 else RGBA 0.97 0.98 0.99 1
    cardColor = if dark then RGBA 0.19 0.21 0.24 1 else RGBA 1 1 1 1
    foreground = if dark then RGBA 0.93 0.95 0.98 1 else RGBA 0.12 0.15 0.19 1
    accent = RGBA 0.16 0.55 0.95 1
    edgeColor = case compatible of
      Just True -> RGBA 0.12 0.66 0.36 1
      Just False -> RGBA 0.9 0.25 0.3 1
      Nothing -> RGBA 0.5 0.53 0.58 1
    visible = [(identity,node) | (identity,identifier) <- canvas.canvasNodes, Just node <- [find ((==identifier) . (.functionIdentity)) functions]]
    visibleEdges = [(a,b) | (a,b) <- canvas.canvasEdges, all (\key -> any ((==key) . fst) visible) [a,b]]
    nodeRect identity = let point = nodePosition canvas identity in Rect point.pointX point.pointY 300 142
    portRect identity output =
      let rect = nodeRect identity
       in Rect (rect.rectX + if output then 292 else -8) (rect.rectY + 91) 16 16
    drawText value rect size = DrawText (TextDraw value rect
      (mempty {textForeground = Just foreground, textFontFamily = Just MonospaceFont, textFontSize = Just size}) TextStart TextTop WordWrap)
    drawNode :: (Word64, FunctionNode a) -> Drawing
    drawNode (identity,node) =
      let rect = nodeRect identity
          at x y w h = Rect (rect.rectX+x) (rect.rectY+y) w h
       in Group
          [ Fill NonZero (Solid cardColor) (RoundedRectangle rect 9 9)
          , Stroke (defaultStrokeStyle {strokeWidth = 1.5}) (Solid accent) (RoundedRectangle rect 9 9)
          , drawText node.functionName (at 14 12 272 24) 15
          , drawText ("in: " <> compact node.functionInput) (at 14 45 272 36) 11
          , drawText ("out: " <> compact node.functionOutput) (at 14 88 272 42) 11
          , Fill NonZero (Solid accent) (Ellipse (portRect identity False))
          , Fill NonZero (Solid (if canvas.canvasPendingOutput == Just identity then RGBA 1 0.65 0.12 1 else accent)) (Ellipse (portRect identity True))
          ]
    compact value = Text.unwords (Text.words value)
    hitNode (identity,_) =
      [DrawingHitRegion (DrawingHitRegionKey (identity*3)) ClosedHandCursor (HitFill NonZero (Rectangle (nodeRect identity))),
       DrawingHitRegion (DrawingHitRegionKey (identity*3+1)) CrosshairCursor (HitFill NonZero (Ellipse (portRect identity False))),
       DrawingHitRegion (DrawingHitRegionKey (identity*3+2)) CrosshairCursor (HitFill NonZero (Ellipse (portRect identity True)))]
    drawEdge (source,destination) =
      let a = portRect source True
          b = portRect destination False
          start = Point (a.rectX+8) (a.rectY+8)
          end = Point (b.rectX+8) (b.rectY+8)
          path = UI.Path [MoveTo start, CubicTo (Point (start.pointX+80) start.pointY) (Point (end.pointX-80) end.pointY) end]
       in Stroke (defaultStrokeStyle {strokeWidth = 3}) (Solid edgeColor) (PathGeometry path)

handleFunctionCanvasInput :: DrawingInput -> FunctionCanvas -> (FunctionCanvas, Maybe DeclarationId)
handleFunctionCanvasInput input canvas = case input of
  DrawingScrollInput event ->
    let delta = event.drawingScrollDelta
        zoom = event.drawingScrollModifiers.drawingMetaPressed || event.drawingScrollModifiers.drawingControlPressed
        updated = if zoom
          then canvas {canvasScale = max 0.4 (min 2.5 (canvas.canvasScale * exp (negate delta.pointY * 0.01)))}
          else canvas {canvasOffset = Point (canvas.canvasOffset.pointX-delta.pointX) (canvas.canvasOffset.pointY-delta.pointY)}
     in (changed updated, Nothing)
  DrawingPointerInput event ->
    let point = maybe event.drawingPointerPosition (`applyAffine` event.drawingPointerPosition) (invertAffine (canvasTransform canvas))
        hit = find (\(identity,_) -> inRect point (rect identity)) (reverse canvas.canvasNodes)
        portHit = find (\(identity,output) -> inRect point (port identity output))
          [(identity,output) | (identity,_) <- canvas.canvasNodes, output <- [False,True]]
        activated = case hit of
          Just (_,identifier) | event.drawingPointerClickCount >= 2 && event.drawingPointerPhase == DrawingPointerDown -> Just identifier
          _ -> Nothing
        updated = case event.drawingPointerPhase of
          DrawingPointerDown -> case portHit of
            Just (identity,True) -> canvas {canvasPendingOutput = Just identity, canvasDragging = Nothing}
            Just (identity,False) | Just output <- canvas.canvasPendingOutput -> connectFunctions output identity canvas
            _ -> canvas {canvasDragging = fmap fst hit, canvasSelected = fmap fst hit}
          DrawingPointerMoved | Just identity <- canvas.canvasDragging ->
            let current = nodePosition canvas identity
                delta = event.drawingPointerDelta
             in canvas {canvasPositions = Map.insert identity (Point (current.pointX+delta.pointX/canvas.canvasScale) (current.pointY+delta.pointY/canvas.canvasScale)) canvas.canvasPositions}
          DrawingPointerUp -> case portHit of
            Just (identity,False) | Just output <- canvas.canvasPendingOutput -> (connectFunctions output identity canvas) {canvasDragging = Nothing}
            _ -> canvas {canvasDragging = Nothing}
          DrawingPointerCancelled -> canvas {canvasDragging = Nothing, canvasPendingOutput = Nothing}
          _ -> canvas
     in (if updated == canvas then canvas else changed updated, activated)
  where
    changed value = value {canvasRevision = canvas.canvasRevision + 1}
    rect identity = let p = nodePosition canvas identity in Rect p.pointX p.pointY 300 142
    port identity output = let r = rect identity in Rect (r.rectX + if output then 290 else -10) (r.rectY+89) 20 20
    inRect :: Point -> Rect -> Bool
    inRect p r = p.pointX >= r.rectX && p.pointX <= r.rectX+r.rectWidth && p.pointY >= r.rectY && p.pointY <= r.rectY+r.rectHeight
