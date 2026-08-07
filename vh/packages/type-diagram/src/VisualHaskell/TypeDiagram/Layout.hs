{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

module VisualHaskell.TypeDiagram.Layout
  ( DiagramMetrics (..)
  , EdgeLayout (..)
  , FamilyLayout (..)
  , FunctionItemLayout (..)
  , LaidOutTypeDiagram (..)
  , NodeLayout (..)
  , defaultDiagramMetrics
  , layoutTypeDiagram
  , rectBottom
  , rectCenter
  , rectRight
  , unionRects
  ) where

import Data.Graph (SCC (..), stronglyConnComp)
import Data.List (sortOn)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (mapMaybe)
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text
import HaskeLUI.Core
import VisualHaskell.TypeDiagram.Scene

-- | Every visual measurement is explicit and replaceable. The defaults are a
-- compact desktop diagram density, never a hidden backend constant.
data DiagramMetrics = DiagramMetrics
  { diagramNodeMinimumWidth :: !Double
  , diagramNodeWidth :: !Double
  , diagramReferenceNodeMinimumWidth :: !Double
  , diagramReferenceNodeWidth :: !Double
  , diagramFunctionNodeWidth :: !Double
  , diagramFunctionEndpointMinimumWidth :: !Double
  , diagramFunctionEndpointMaximumWidth :: !Double
  , diagramFunctionArrowWidth :: !Double
  , diagramFunctionNodeHeight :: !Double
  , diagramOriginBadgeWidth :: !Double
  , diagramEstimatedCharacterWidth :: !Double
  , diagramOverflowPopoverMaximumWidth :: !Double
  , diagramHeaderHeight :: !Double
  , diagramRowHeight :: !Double
  , diagramSecondaryRowHeight :: !Double
  , diagramColumnGap :: !Double
  , diagramNodeGap :: !Double
  , diagramCanvasPadding :: !Double
  , diagramCardCornerRadius :: !Double
  , diagramCardPadding :: !Double
  , diagramFamilyPadding :: !Double
  , diagramMinimumScale :: !Double
  , diagramMaximumScale :: !Double
  }
  deriving stock (Eq, Show)

defaultDiagramMetrics :: DiagramMetrics
defaultDiagramMetrics =
  DiagramMetrics
    { diagramNodeMinimumWidth = 188
    , diagramNodeWidth = 320
    , diagramReferenceNodeMinimumWidth = 188
    , diagramReferenceNodeWidth = 300
    , diagramFunctionNodeWidth = 520
    , diagramFunctionEndpointMinimumWidth = 84
    , diagramFunctionEndpointMaximumWidth = 184
    , diagramFunctionArrowWidth = 38
    , diagramFunctionNodeHeight = 70
    , diagramOriginBadgeWidth = 74
    , diagramEstimatedCharacterWidth = 7.2
    , diagramOverflowPopoverMaximumWidth = 640
    , diagramHeaderHeight = 64
    , diagramRowHeight = 32
    , diagramSecondaryRowHeight = 42
    , diagramColumnGap = 76
    , diagramNodeGap = 20
    , diagramCanvasPadding = 48
    , diagramCardCornerRadius = 12
    , diagramCardPadding = 18
    , diagramFamilyPadding = 34
    , diagramMinimumScale = 0.32
    , diagramMaximumScale = 2.4
    }

data NodeLayout = NodeLayout
  { laidOutNode :: !DiagramNode
  , laidOutNodeRect :: !Rect
  , laidOutHeaderRect :: !Rect
  , laidOutDisclosureRect :: !(Maybe Rect)
  , laidOutRowRects :: !(Map DiagramAnchor Rect)
  , laidOutFunctionItems :: ![FunctionItemLayout]
  }
  deriving stock (Eq, Show)

data FunctionItemLayout
  = FunctionEndpointLayout !Int !DiagramFunctionEndpoint !Rect
  | FunctionEllipsisLayout !Rect
  deriving stock (Eq, Show)

data EdgeLayout = EdgeLayout
  { laidOutEdge :: !DiagramEdge
  , laidOutEdgePath :: !Path
  , laidOutArrowPath :: !Path
  , laidOutEdgeLabelRect :: !Rect
  }
  deriving stock (Eq, Show)

data FamilyLayout = FamilyLayout
  { laidOutFamilyId :: !Text
  , laidOutFamilyRect :: !Rect
  , laidOutFamilyNodes :: !(Set DiagramNodeId)
  }
  deriving stock (Eq, Show)

data LaidOutTypeDiagram = LaidOutTypeDiagram
  { laidOutDiagram :: !TypeDiagram
  , laidOutNodes :: !(Map DiagramNodeId NodeLayout)
  , laidOutEdges :: ![EdgeLayout]
  , laidOutFamilies :: ![FamilyLayout]
  , laidOutContentBounds :: !Rect
  , laidOutViewport :: !Rect
  }
  deriving stock (Eq, Show)

layoutTypeDiagram
  :: DiagramMetrics
  -> Rect
  -> TypeDiagram
  -> TypeDiagramState
  -> LaidOutTypeDiagram
layoutTypeDiagram metrics viewport diagram state =
  LaidOutTypeDiagram
    { laidOutDiagram = diagram
    , laidOutNodes = nodeLayouts
    , laidOutEdges = mapMaybe (layoutEdge nodeLayouts) diagram.typeDiagramEdges
    , laidOutFamilies = familyLayouts metrics components nodeLayouts diagram.typeDiagramEdges
    , laidOutContentBounds = contentBounds nodeLayouts
    , laidOutViewport = viewport
    }
  where
    components = graphComponents diagram
    ranks = componentRanks components diagram.typeDiagramEdges
    componentByNode =
      Map.fromList
        [ (nodeId, componentIndex)
        | (componentIndex, nodeIds) <- Map.toAscList components
        , nodeId <- nodeIds
        ]
    nodesByRank =
      Map.fromListWith (<> )
        [ (Map.findWithDefault 0 componentIndex ranks, [nodeId])
        | nodeId <- Map.keys diagram.typeDiagramNodes
        , let componentIndex = Map.findWithDefault 0 nodeId componentByNode
        ]
    maxWidths =
      Map.map
        ( maximum
            . (0 :)
            . fmap
              (nodeWidth metrics . (diagram.typeDiagramNodes Map.!))
        )
        nodesByRank
    xPositions = rankXPositions metrics maxWidths
    nodeLayouts =
      Map.fromList
        [ (nodeId, layoutNode metrics node position)
        | (rank, nodeIds) <- Map.toAscList nodesByRank
        , (nodeId, autoPosition) <-
            verticalPositions
              metrics
              diagram.typeDiagramNodes
              (Map.findWithDefault metrics.diagramCanvasPadding rank xPositions)
              (sortNodes componentByNode nodeIds)
        , let node = diagram.typeDiagramNodes Map.! nodeId
        , let position = Map.findWithDefault autoPosition nodeId state.typeDiagramPinnedNodes
        ]
    sortNodes componentMap = sortOn (\nodeId -> (Map.lookup nodeId componentMap, nodeId))

graphComponents :: TypeDiagram -> Map Int [DiagramNodeId]
graphComponents diagram =
  Map.fromList (zip [0 ..] (fmap flatten sccs))
  where
    outgoing =
      Map.fromListWith (<> )
        [ (anchorNode edge.diagramEdgeSource, [edge.diagramEdgeTarget])
        | edge <- diagram.typeDiagramEdges
        ]
    triples =
      [ (nodeId, nodeId, Map.findWithDefault [] nodeId outgoing)
      | nodeId <- Map.keys diagram.typeDiagramNodes
      ]
    sccs = stronglyConnComp triples
    flatten (AcyclicSCC nodeId) = [nodeId]
    flatten (CyclicSCC nodeIds) = sortOn id nodeIds

componentRanks :: Map Int [DiagramNodeId] -> [DiagramEdge] -> Map Int Int
componentRanks components edges = go initialQueue indegrees initialRanks
  where
    initialRanks = Map.fromList [(index, 0) | index <- Map.keys components]
    componentByNode =
      Map.fromList
        [ (nodeId, index)
        | (index, nodeIds) <- Map.toList components
        , nodeId <- nodeIds
        ]
    componentEdges =
      Set.toAscList
        ( Set.fromList
            [ (source, target)
            | edge <- edges
            , let source = Map.findWithDefault 0 (anchorNode edge.diagramEdgeSource) componentByNode
            , let target = Map.findWithDefault 0 edge.diagramEdgeTarget componentByNode
            , source /= target
            ]
        )
    adjacency = Map.fromListWith (<>) [(source, [target]) | (source, target) <- componentEdges]
    indegrees =
      foldl'
        (\current (_, target) -> Map.adjust (+ 1) target current)
        (Map.fromList [(index, 0) | index <- Map.keys components])
        componentEdges
    initialQueue =
      Set.fromList
        [ index
        | (index, degree) <- Map.toList indegrees
        , degree == 0
        ]
    go :: Set Int -> Map Int Int -> Map Int Int -> Map Int Int
    go queue currentIndegrees ranks =
      case Set.minView queue of
        Nothing -> ranks
        Just (source, remainingQueue) ->
          let (nextQueue, nextIndegrees, nextRanks) =
                foldl'
                  (advance source)
                  (remainingQueue, currentIndegrees, ranks)
                  (Map.findWithDefault [] source adjacency)
           in go nextQueue nextIndegrees nextRanks
    advance
      :: Int
      -> (Set Int, Map Int Int, Map Int Int)
      -> Int
      -> (Set Int, Map Int Int, Map Int Int)
    advance source (queue, currentIndegrees, ranks) target =
      let nextDegree = Map.findWithDefault 1 target currentIndegrees - 1
          nextIndegrees = Map.insert target nextDegree currentIndegrees
          nextRanks =
            Map.insertWith
              max
              target
              (Map.findWithDefault 0 source ranks + 1)
              ranks
          nextQueue = if nextDegree == 0 then Set.insert target queue else queue
       in (nextQueue, nextIndegrees, nextRanks)

rankXPositions :: DiagramMetrics -> Map Int Double -> Map Int Double
rankXPositions metrics widths = snd (foldl' place (metrics.diagramCanvasPadding, Map.empty) (Map.toAscList widths))
  where
    place (nextX, result) (rank, width) =
      ( nextX + width + metrics.diagramColumnGap
      , Map.insert rank nextX result
      )

verticalPositions
  :: DiagramMetrics
  -> Map DiagramNodeId DiagramNode
  -> Double
  -> [DiagramNodeId]
  -> [(DiagramNodeId, Point)]
verticalPositions metrics nodes x = snd . foldl' place (metrics.diagramCanvasPadding, [])
  where
    place (nextY, result) nodeId =
      let node = nodes Map.! nodeId
          position = Point x nextY
          next = nextY + nodeHeight metrics node + metrics.diagramNodeGap
       in (next, result <> [(nodeId, position)])

layoutNode :: DiagramMetrics -> DiagramNode -> Point -> NodeLayout
layoutNode metrics node position =
  NodeLayout
    { laidOutNode = node
    , laidOutNodeRect = cardRect
    , laidOutHeaderRect = Rect cardRect.rectX cardRect.rectY width metrics.diagramHeaderHeight
    , laidOutDisclosureRect =
        if node.diagramNodeKind == FunctionNodeKind
          || node.diagramNodeEntity == Nothing
          || null node.diagramNodeRows
          then Nothing
          else Just (Rect (cardRect.rectX + width - 38) (cardRect.rectY + 23) 18 18)
    , laidOutRowRects = rowRects
    , laidOutFunctionItems = layoutFunctionItems metrics node cardRect
    }
  where
    width = nodeWidth metrics node
    visibleRows = if node.diagramNodeCollapsed then [] else node.diagramNodeRows
    heights = fmap (rowHeight metrics) visibleRows
    height = nodeHeight metrics node
    cardRect = Rect position.pointX position.pointY width height
    rowRects = snd (foldl' placeRow (position.pointY + metrics.diagramHeaderHeight, Map.empty) (zip visibleRows heights))
    placeRow :: (Double, Map DiagramAnchor Rect) -> (DiagramRow, Double) -> (Double, Map DiagramAnchor Rect)
    placeRow (y, result) (row, height') =
      let rect = Rect position.pointX y width height'
       in (y + height', Map.insert row.diagramRowAnchor rect result)

nodeWidth :: DiagramMetrics -> DiagramNode -> Double
nodeWidth metrics node =
  case node.diagramNodeKind of
    FunctionNodeKind ->
      min metrics.diagramFunctionNodeWidth (functionNaturalWidth metrics node)
    ReferenceNodeKind ->
      clamp
        metrics.diagramReferenceNodeMinimumWidth
        metrics.diagramReferenceNodeWidth
        (contentNaturalWidth metrics node)
    _ ->
      clamp
        metrics.diagramNodeMinimumWidth
        metrics.diagramNodeWidth
        (contentNaturalWidth metrics node)

contentNaturalWidth :: DiagramMetrics -> DiagramNode -> Double
contentNaturalWidth metrics node =
  maximum
    ( titleWidth
        : subtitleWidth
        : fmap rowWidth node.diagramNodeRows
    )
  where
    estimate = estimatedTextWidth metrics
    padding = metrics.diagramCardPadding
    titleWidth =
      estimate node.diagramNodeTitle
        + metrics.diagramOriginBadgeWidth
        + padding * 3
    subtitleWidth =
      maybe 0 estimate node.diagramNodeSubtitle + padding * 2 + 76
    rowWidth :: DiagramRow -> Double
    rowWidth row =
      max (estimate row.diagramRowPrimary) (maybe 0 estimate row.diagramRowSecondary)
        + padding * 2
        + fromIntegral row.diagramRowDepth * 14

functionNaturalWidth :: DiagramMetrics -> DiagramNode -> Double
functionNaturalWidth metrics node =
  max
    metrics.diagramReferenceNodeMinimumWidth
    ( metrics.diagramCardPadding * 2
        + sum (fmap (functionEndpointWidth metrics) node.diagramNodeFunctionEndpoints)
        + metrics.diagramFunctionArrowWidth
            * fromIntegral (max 0 (length node.diagramNodeFunctionEndpoints - 1))
    )

functionEndpointWidth :: DiagramMetrics -> DiagramFunctionEndpoint -> Double
functionEndpointWidth metrics endpoint =
  clamp
    metrics.diagramFunctionEndpointMinimumWidth
    metrics.diagramFunctionEndpointMaximumWidth
    ( max
        (estimatedTextWidth metrics endpoint.diagramFunctionEndpointLabel)
        (maybe 0 (estimatedTextWidth metrics) endpoint.diagramFunctionEndpointDetail)
        + 24
    )

estimatedTextWidth :: DiagramMetrics -> Text -> Double
estimatedTextWidth metrics text =
  fromIntegral (Text.length text) * metrics.diagramEstimatedCharacterWidth

layoutFunctionItems :: DiagramMetrics -> DiagramNode -> Rect -> [FunctionItemLayout]
layoutFunctionItems metrics node rect
  | node.diagramNodeKind /= FunctionNodeKind = []
  | null endpoints = []
  | otherwise = snd (foldl' place (rect.rectX + padding, []) sizedItems)
  where
    endpoints = zip [0 ..] node.diagramNodeFunctionEndpoints
    padding = metrics.diagramCardPadding
    fullNatural = functionNaturalWidth metrics node
    visibleItems
      | fullNatural <= metrics.diagramFunctionNodeWidth || length endpoints <= 3 =
          fmap (Left) endpoints
      | otherwise =
          fmap Left (take 2 endpoints)
            <> [Right ()]
            <> fmap Left (take 1 (reverse endpoints))
    itemCount = length visibleItems
    gapTotal = metrics.diagramFunctionArrowWidth * fromIntegral (max 0 (itemCount - 1))
    ellipsisTotal = sum [32 | Right () <- visibleItems]
    desiredEndpointTotal =
      sum
        [ functionEndpointWidth metrics endpoint
        | Left (_, endpoint) <- visibleItems
        ]
    endpointBudget = max 1 (rect.rectWidth - padding * 2 - gapTotal - ellipsisTotal)
    endpointScale = min 1 (endpointBudget / max 1 desiredEndpointTotal)
    sizedItems =
      [ case item of
          Left (index, endpoint) ->
            Left (index, endpoint, functionEndpointWidth metrics endpoint * endpointScale)
          Right () -> Right 32
      | item <- visibleItems
      ]
    itemHeight = rect.rectHeight - 12
    itemY = rect.rectY + 6
    place (x, result) item =
      let width = either (\(_, _, value) -> value) id item
          itemRect = Rect x itemY width itemHeight
          layout =
            case item of
              Left (index, endpoint, _) -> FunctionEndpointLayout index endpoint itemRect
              Right _ -> FunctionEllipsisLayout itemRect
       in (x + width + metrics.diagramFunctionArrowWidth, result <> [layout])

rowHeight :: DiagramMetrics -> DiagramRow -> Double
rowHeight metrics row =
  case row.diagramRowSecondary of
    Nothing -> metrics.diagramRowHeight
    Just _ -> metrics.diagramSecondaryRowHeight

nodeHeight :: DiagramMetrics -> DiagramNode -> Double
nodeHeight metrics node =
  case node.diagramNodeKind of
    FunctionNodeKind -> metrics.diagramFunctionNodeHeight
    _ ->
      metrics.diagramHeaderHeight
        + if node.diagramNodeCollapsed
          then 0
          else sum (fmap (rowHeight metrics) node.diagramNodeRows)

clamp :: Ord value => value -> value -> value -> value
clamp lower upper = max lower . min upper

layoutEdge :: Map DiagramNodeId NodeLayout -> DiagramEdge -> Maybe EdgeLayout
layoutEdge nodes edge = do
  sourceLayout <- Map.lookup (anchorNode edge.diagramEdgeSource) nodes
  targetLayout <- Map.lookup edge.diagramEdgeTarget nodes
  let sourceRect = Map.findWithDefault sourceLayout.laidOutHeaderRect edge.diagramEdgeSource sourceLayout.laidOutRowRects
      targetRect = targetLayout.laidOutNodeRect
      isSelf = sourceLayout.laidOutNode.diagramNodeId == targetLayout.laidOutNode.diagramNodeId
      (path, arrow, labelRect) =
        if isSelf
          then selfLoop sourceRect targetRect
          else connectingCurve sourceRect targetRect
  pure
    EdgeLayout
      { laidOutEdge = edge
      , laidOutEdgePath = path
      , laidOutArrowPath = arrow
      , laidOutEdgeLabelRect = labelRect
      }

connectingCurve :: Rect -> Rect -> (Path, Path, Rect)
connectingCurve source target
  | target.rectX >= source.rectX =
      curve
        (Point (rectRight source) (middleY source))
        (Point target.rectX (middleY target))
        1
  | otherwise =
      curve
        (Point source.rectX (middleY source))
        (Point (rectRight target) (middleY target))
        (-1)
  where
    curve start end direction =
      let distance = max 46 (abs (end.pointX - start.pointX) * 0.48)
          control1 = Point (start.pointX + direction * distance) start.pointY
          control2 = Point (end.pointX - direction * distance) end.pointY
          arrow = arrowAt end direction
          label = Rect ((start.pointX + end.pointX) / 2 - 24) ((start.pointY + end.pointY) / 2 - 10) 48 20
       in (Path [MoveTo start, CubicTo control1 control2 end], arrow, label)

selfLoop :: Rect -> Rect -> (Path, Path, Rect)
selfLoop source card =
  ( Path
      [ MoveTo start
      , CubicTo
          (Point (rectRight card + 58) start.pointY)
          (Point (rectRight card + 58) (card.rectY - 28))
          end
      ]
  , arrowAt end (-1)
  , Rect (rectRight card + 12) (card.rectY - 23) 38 20
  )
  where
    start = Point (rectRight source) (middleY source)
    end = Point (rectRight card - 18) card.rectY

arrowAt :: Point -> Double -> Path
arrowAt point direction =
  Path
    [ MoveTo point
    , LineTo (Point (point.pointX - direction * 8) (point.pointY - 4.5))
    , LineTo (Point (point.pointX - direction * 8) (point.pointY + 4.5))
    , ClosePath
    ]

familyLayouts
  :: DiagramMetrics
  -> Map Int [DiagramNodeId]
  -> Map DiagramNodeId NodeLayout
  -> [DiagramEdge]
  -> [FamilyLayout]
familyLayouts metrics components nodes edges =
  [ FamilyLayout
      { laidOutFamilyId = "recursive-" <> Text.pack (show componentIndex)
      , laidOutFamilyRect = expandRect metrics.diagramFamilyPadding hull
      , laidOutFamilyNodes = Set.fromList nodeIds
      }
  | (componentIndex, nodeIds) <- Map.toAscList components
  , isRecursiveComponent nodeIds
  , let hull = unionRects [layout.laidOutNodeRect | nodeId <- nodeIds, layout <- maybeToList (Map.lookup nodeId nodes)]
  ]
  where
    isRecursiveComponent nodeIds =
      length nodeIds > 1
        || any
          (\edge -> edge.diagramEdgeRecursive && anchorNode edge.diagramEdgeSource `elem` nodeIds)
          edges
    maybeToList Nothing = []
    maybeToList (Just value) = [value]

contentBounds :: Map DiagramNodeId NodeLayout -> Rect
contentBounds nodes =
  unionRects (fmap (.laidOutNodeRect) (Map.elems nodes))

anchorNode :: DiagramAnchor -> DiagramNodeId
anchorNode anchor =
  case anchor of
    NodeAnchor nodeId -> nodeId
    ConstructorAnchor entityId _ -> EntityNode entityId
    FieldAnchor entityId _ -> EntityNode entityId
    MethodAnchor entityId _ -> EntityNode entityId
    AliasAnchor entityId -> EntityNode entityId

rectRight :: Rect -> Double
rectRight rect = rect.rectX + rect.rectWidth

rectBottom :: Rect -> Double
rectBottom rect = rect.rectY + rect.rectHeight

middleY :: Rect -> Double
middleY rect = rect.rectY + rect.rectHeight / 2

rectCenter :: Rect -> Point
rectCenter rect = Point (rect.rectX + rect.rectWidth / 2) (middleY rect)

unionRects :: [Rect] -> Rect
unionRects [] = Rect 0 0 0 0
unionRects (first : rest) = foldl' union first rest
  where
    union left right =
      let x = min left.rectX right.rectX
          y = min left.rectY right.rectY
          rightEdge = max (rectRight left) (rectRight right)
          bottomEdge = max (rectBottom left) (rectBottom right)
       in Rect x y (rightEdge - x) (bottomEdge - y)

expandRect :: Double -> Rect -> Rect
expandRect amount rect =
  Rect
    (rect.rectX - amount)
    (rect.rectY - amount)
    (rect.rectWidth + amount * 2)
    (rect.rectHeight + amount * 2)
