{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

module VisualHaskell.TypeDiagram.Render
  ( DiagramTheme (..)
  , TypeDiagramPresentation (..)
  , diagramPartForHit
  , diagramTheme
  , renderTypeDiagram
  ) where

import Data.Bits (xor)
import Data.Char (ord)
import Data.List (find, sort)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word64)
import HaskeLUI.Core
import VisualHaskell.Semantic
import VisualHaskell.TypeDiagram.Layout
import VisualHaskell.TypeDiagram.Scene

data DiagramTheme = DiagramTheme
  { themeCanvas :: !Color
  , themeCard :: !Color
  , themeCardElevated :: !Color
  , themeBorder :: !Color
  , themeText :: !Color
  , themeMutedText :: !Color
  , themeRowSeparator :: !Color
  , themeSelection :: !Color
  , themeHover :: !Color
  , themeCurrentAccent :: !Color
  , themeWorkspaceAccent :: !Color
  , themePackageAccent :: !Color
  , themeBuiltinAccent :: !Color
  , themeUnknownAccent :: !Color
  , themeRelation :: !Color
  , themeConstraint :: !Color
  , themeRecursive :: !Color
  , themeFamilyFill :: !Color
  }
  deriving stock (Eq, Show)

data TypeDiagramPresentation = TypeDiagramPresentation
  { diagramPresentationDrawing :: !Drawing
  , diagramPresentationHitTest :: !DrawingHitTest
  , diagramPresentationParts :: !(Map DrawingHitRegionKey DiagramPart)
  , diagramPresentationRegions :: !(Map DiagramPart DrawingHitRegionKey)
  , diagramPresentationLayout :: !LaidOutTypeDiagram
  , diagramPresentationRevision :: !DrawingRevision
  , diagramPresentationCursor :: !DrawingCursor
  , diagramPresentationAccessibleLabel :: !Text
  , diagramPresentationIntrinsicMetrics :: !IntrinsicMetrics
  }
  deriving stock (Eq, Show)

diagramTheme :: ColorScheme -> DiagramTheme
diagramTheme scheme =
  case scheme of
    LightColorScheme ->
      DiagramTheme
        (rgb 0.972 0.976 0.984)
        (rgb 1 1 1)
        (rgb 0.955 0.963 0.978)
        (rgb 0.68 0.70 0.74)
        (rgb 0.10 0.11 0.14)
        (rgb 0.39 0.42 0.47)
        (rgb 0.79 0.81 0.84)
        (rgb 0.05 0.45 0.95)
        (rgba 0.05 0.45 0.95 0.12)
        (rgb 0.12 0.52 0.82)
        (rgb 0.31 0.55 0.37)
        (rgb 0.58 0.34 0.76)
        (rgb 0.83 0.50 0.14)
        (rgb 0.46 0.48 0.52)
        (rgb 0.38 0.43 0.51)
        (rgb 0.70 0.39 0.10)
        (rgb 0.79 0.18 0.35)
        (rgba 0.79 0.18 0.35 0.045)
    DarkColorScheme ->
      DiagramTheme
        (rgb 0.115 0.12 0.135)
        (rgb 0.17 0.18 0.20)
        (rgb 0.20 0.215 0.24)
        (rgb 0.38 0.40 0.44)
        (rgb 0.93 0.94 0.96)
        (rgb 0.67 0.69 0.73)
        (rgb 0.34 0.36 0.40)
        (rgb 0.24 0.60 1.0)
        (rgba 0.24 0.60 1.0 0.16)
        (rgb 0.30 0.68 0.96)
        (rgb 0.43 0.72 0.48)
        (rgb 0.72 0.50 0.91)
        (rgb 0.95 0.65 0.25)
        (rgb 0.58 0.60 0.65)
        (rgb 0.63 0.67 0.75)
        (rgb 0.92 0.66 0.27)
        (rgb 1.0 0.38 0.55)
        (rgba 1.0 0.38 0.55 0.07)

renderTypeDiagram
  :: DiagramMetrics
  -> DiagramTheme
  -> Rect
  -> TypeDiagram
  -> TypeDiagramState
  -> TypeDiagramPresentation
renderTypeDiagram metrics theme viewport diagram state =
  TypeDiagramPresentation
    { diagramPresentationDrawing = drawing
    , diagramPresentationHitTest = hitTest
    , diagramPresentationParts = partsByKey
    , diagramPresentationRegions = regionsByPart
    , diagramPresentationLayout = layout
    , diagramPresentationRevision = DrawingRevision revision
    , diagramPresentationCursor = cursorFor state
    , diagramPresentationAccessibleLabel = accessibleLabel diagram
    , diagramPresentationIntrinsicMetrics =
        IntrinsicMetrics
          (Size 160 180)
          (Size 520 760)
          (Size 4096 4096)
          Nothing
          Nothing
    }
  where
    layout = layoutTypeDiagram metrics viewport diagram state
    parts = allDiagramParts layout
    (partsByKey, regionsByPart) = allocateRegions parts
    viewTransform = viewportTransform state
    canvas = Rectangle viewport
    drawing =
      Group
        [ Fill NonZero (Solid theme.themeCanvas) canvas
        , Clip
            NonZero
            canvas
            ( Transform
                viewTransform
                ( Group
                    ( fmap (drawFamily metrics theme state) layout.laidOutFamilies
                        <> fmap (drawEdge theme state) layout.laidOutEdges
                        <> fmap (drawNode metrics theme state) (Map.elems layout.laidOutNodes)
                        <> drawEmptyState theme viewport diagram.typeDiagramEmptyMessage
                        <> [drawHoverPopover metrics theme state layout]
                    )
                )
            )
        ]
    hitTest =
      DrawingHitClip
        NonZero
        canvas
        ( DrawingHitTransform
            viewTransform
            ( DrawingHitGroup
                ( fmap (familyHit regionsByPart) layout.laidOutFamilies
                    <> fmap (edgeHit regionsByPart) layout.laidOutEdges
                    <> concatMap (nodeHits regionsByPart) (Map.elems layout.laidOutNodes)
                )
            )
        )
    revision =
      hashText
        ( Text.pack (show diagram)
            <> Text.pack (show state.typeDiagramRevision)
            <> Text.pack (show theme)
            <> Text.pack (show viewport)
        )

diagramPartForHit :: TypeDiagramPresentation -> DrawingHitResult -> Maybe DiagramPart
diagramPartForHit presentation result =
  Map.lookup result.drawingHitResultKey presentation.diagramPresentationParts

viewportTransform :: TypeDiagramState -> Affine2
viewportTransform state =
  let viewport = state.typeDiagramViewport
      Point x y = viewport.diagramViewportOffset
      scale = viewport.diagramViewportScale
   in composeAffine (translation x y) (scaling scale scale)

allDiagramParts :: LaidOutTypeDiagram -> [DiagramPart]
allDiagramParts layout =
  sort
    ( [EdgePart edge.laidOutEdge.diagramEdgeId | edge <- layout.laidOutEdges]
        <> [FamilyPart family.laidOutFamilyId | family <- layout.laidOutFamilies]
        <> concatMap nodeParts (Map.elems layout.laidOutNodes)
    )
  where
    nodeParts :: NodeLayout -> [DiagramPart]
    nodeParts nodeLayout =
      let node = nodeLayout.laidOutNode
       in [AnchorPart (NodeAnchor node.diagramNodeId)]
            <> fmap AnchorPart (Map.keys nodeLayout.laidOutRowRects)
            <> [ FunctionEndpointPart node.diagramNodeId index
               | FunctionEndpointLayout index _ _ <- nodeLayout.laidOutFunctionItems
               ]
            <> [ FunctionOverflowPart node.diagramNodeId
               | FunctionEllipsisLayout _ <- nodeLayout.laidOutFunctionItems
               ]
            <> [DisclosurePart entityId | entityId <- maybeToList node.diagramNodeEntity, nodeLayout.laidOutDisclosureRect /= Nothing]
    maybeToList Nothing = []
    maybeToList (Just value) = [value]

allocateRegions
  :: [DiagramPart]
  -> (Map DrawingHitRegionKey DiagramPart, Map DiagramPart DrawingHitRegionKey)
allocateRegions = foldl' allocate (Map.empty, Map.empty)
  where
    allocate (byKey, byPart) part =
      let key = firstAvailable byKey (hashText (Text.pack (show part)))
       in (Map.insert key part byKey, Map.insert part key byPart)
    firstAvailable existing candidate =
      let key = DrawingHitRegionKey candidate
       in if Map.member key existing
            then firstAvailable existing (candidate + 1)
            else key

drawFamily :: DiagramMetrics -> DiagramTheme -> TypeDiagramState -> FamilyLayout -> Drawing
drawFamily metrics theme state family =
  Group
    [ Fill NonZero (Solid theme.themeFamilyFill) (RoundedRectangle rect 16 16)
    , Stroke
        (dashedStroke 1.5 [6, 5])
        (Solid theme.themeRecursive)
        (RoundedRectangle rect 16 16)
    , drawText
        "RECURSIVE FAMILY"
        ( Rect
            (rect.rectX + metrics.diagramCardPadding)
            (rect.rectY + 3)
            (rect.rectWidth - metrics.diagramCardPadding * 2)
            (metrics.diagramFamilyPadding - 8)
        )
        (textStyle theme.themeRecursive 10 SemiBold MonospaceFont)
        TextStart
    , selectedOverlay (FamilyPart family.laidOutFamilyId) state rect theme
    ]
  where
    rect = family.laidOutFamilyRect

drawEdge :: DiagramTheme -> TypeDiagramState -> EdgeLayout -> Drawing
drawEdge theme state edgeLayout =
  Group
    [ Stroke style (Solid color) (PathGeometry edgeLayout.laidOutEdgePath)
    , Fill NonZero (Solid color) (PathGeometry edgeLayout.laidOutArrowPath)
    , drawText
        label
        edgeLayout.laidOutEdgeLabelRect
        (textStyle color 10 SemiBold MonospaceFont)
        TextCenter
    ]
  where
    edge = edgeLayout.laidOutEdge
    part = EdgePart edge.diagramEdgeId
    color
      | state.typeDiagramSelected == Just part = theme.themeSelection
      | edge.diagramEdgeRecursive = theme.themeRecursive
      | edge.diagramEdgeKind == ConstrainsType || edge.diagramEdgeKind == ExtendsType = theme.themeConstraint
      | otherwise = theme.themeRelation
    style = case edge.diagramEdgeKind of
      AliasOfType -> dashedStroke 1.6 [7, 4]
      ConstrainsType -> dashedStroke 1.5 [2, 4]
      ExtendsType -> dashedStroke 1.7 [2, 4]
      RecursiveTypeReference -> dashedStroke 2 [7, 4]
      ReferencesType -> solidStroke 1.5
    label = case edge.diagramEdgeKind of
      AliasOfType -> "="
      ConstrainsType -> "=>"
      ExtendsType -> "extends"
      RecursiveTypeReference -> "loop"
      ReferencesType -> "uses"

drawNode :: DiagramMetrics -> DiagramTheme -> TypeDiagramState -> NodeLayout -> Drawing
drawNode metrics theme state nodeLayout
  | nodeLayout.laidOutNode.diagramNodeKind == FunctionNodeKind =
      drawFunctionNode metrics theme state nodeLayout
drawNode metrics theme state nodeLayout =
  Group
    [ hoverOverlay
    , Fill NonZero (Solid fillColor) cardGeometry
    , Clip
        NonZero
        cardGeometry
        (Fill NonZero (Solid (originAccent theme node.diagramNodeOrigin)) accentGeometry)
    , Stroke borderStyle (Solid borderColor) cardGeometry
    , kindDecoration
    , drawText
        (ellipsizeText metrics titleRect node.diagramNodeTitle)
        titleRect
        (textStyle theme.themeText 14 SemiBold SystemFont)
        TextStart
    , drawText
        (originLabel node.diagramNodeOrigin)
        badgeRect
        (textStyle (originAccent theme node.diagramNodeOrigin) 8 SemiBold MonospaceFont)
        TextEnd
    , drawHeaderDetail
    , maybe Empty drawDisclosure nodeLayout.laidOutDisclosureRect
    , Group (fmap drawRow visibleRows)
    , selectedOverlay (AnchorPart (NodeAnchor node.diagramNodeId)) state rect theme
    ]
  where
    node = nodeLayout.laidOutNode
    rect = nodeLayout.laidOutNodeRect
    cardGeometry = RoundedRectangle rect metrics.diagramCardCornerRadius metrics.diagramCardCornerRadius
    fillColor = case node.diagramNodeKind of
      ReferenceNodeKind -> theme.themeCardElevated
      _ -> theme.themeCard
    borderColor
      | state.typeDiagramSelected == Just (AnchorPart (NodeAnchor node.diagramNodeId)) = theme.themeSelection
      | otherwise = theme.themeBorder
    borderStyle = case node.diagramNodeKind of
      AliasNode -> dashedStroke 1.4 [6, 4]
      ClassNode -> solidStroke 1.8
      FamilyNode -> dashedStroke 1.5 [2, 3]
      UnresolvedNode -> dashedStroke 1.4 [1, 4]
      ReferenceNodeKind -> dashedStroke 1.2 [4, 4]
      FunctionNodeKind -> dashedStroke 1.2 [4, 4]
      _ -> solidStroke 1.2
    accentGeometry = Rectangle (Rect rect.rectX rect.rectY 5 rect.rectHeight)
    titleRect =
      Rect
        (rect.rectX + metrics.diagramCardPadding)
        (rect.rectY + 14)
        ( rect.rectWidth
            - metrics.diagramCardPadding * 2
            - metrics.diagramOriginBadgeWidth
        )
        22
    badgeRect =
      Rect
        (rectRight rect - metrics.diagramCardPadding - metrics.diagramOriginBadgeWidth)
        (rect.rectY + 15)
        metrics.diagramOriginBadgeWidth
        18
    hoverOverlay =
      if state.typeDiagramHovered == Just (AnchorPart (NodeAnchor node.diagramNodeId))
        then Fill NonZero (Solid theme.themeHover) cardGeometry
        else Empty
    kindDecoration = case node.diagramNodeKind of
      NewtypeNode ->
        Stroke
          (solidStroke 1)
          (Solid theme.themeBorder)
          (RoundedRectangle (insetRect 4 rect) (metrics.diagramCardCornerRadius - 3) (metrics.diagramCardCornerRadius - 3))
      _ -> Empty
    drawHeaderDetail =
      drawText
        (ellipsizeText metrics detailRect detailText)
        detailRect
        (textStyle theme.themeMutedText 10 Regular MonospaceFont)
        TextStart
      where
        detailText = kindLabel node.diagramNodeKind <> foldMap (" · " <>) node.diagramNodeSubtitle
        detailRect =
          Rect
            (rect.rectX + metrics.diagramCardPadding)
            (rect.rectY + 40)
            (rect.rectWidth - metrics.diagramCardPadding * 2)
            16
    drawDisclosure disclosureRect =
      Fill NonZero (Solid theme.themeMutedText) (PathGeometry (disclosurePath node.diagramNodeCollapsed disclosureRect))
    visibleRows =
      [ row
      | row <- node.diagramNodeRows
      , Map.member row.diagramRowAnchor nodeLayout.laidOutRowRects
      ]
    drawRow :: DiagramRow -> Drawing
    drawRow row =
      let rowRect = nodeLayout.laidOutRowRects Map.! row.diagramRowAnchor
          indent = metrics.diagramCardPadding + fromIntegral row.diagramRowDepth * 14
          part = AnchorPart row.diagramRowAnchor
          selected = state.typeDiagramSelected == Just part
          hovered = state.typeDiagramHovered == Just part
          primaryTop = if row.diagramRowSecondary == Nothing then (rowRect.rectHeight - 18) / 2 else 7
          primaryRect = Rect (rowRect.rectX + indent) (rowRect.rectY + primaryTop) (rowRect.rectWidth - indent - metrics.diagramCardPadding) 18
          secondaryRect = Rect (rowRect.rectX + indent) (rowRect.rectY + 23) (rowRect.rectWidth - indent - metrics.diagramCardPadding) 16
       in Group
            [ Stroke (solidStroke 0.8) (Solid theme.themeRowSeparator) (PathGeometry (Path [MoveTo (Point rowRect.rectX (rowRect.rectY + 1)), LineTo (Point (rectRight rowRect) (rowRect.rectY + 1))]))
            , if selected || hovered
                then Fill NonZero (Solid (if selected then withAlpha 0.14 theme.themeSelection else theme.themeHover)) (Rectangle rowRect)
                else Empty
            , drawText (ellipsizeText metrics primaryRect row.diagramRowPrimary) primaryRect (textStyle theme.themeText 11 (rowWeight row.diagramRowKind) (rowFont row.diagramRowKind)) TextStart
            , maybe Empty (\secondary -> drawText (ellipsizeText metrics secondaryRect secondary) secondaryRect (textStyle theme.themeMutedText 9 Regular MonospaceFont) TextStart) row.diagramRowSecondary
            ]
    -- Keep row ordering paired with the semantic list even though their map is
    -- used for direct anchor lookup.
    _rowCountInvariant = length visibleRows

drawFunctionNode :: DiagramMetrics -> DiagramTheme -> TypeDiagramState -> NodeLayout -> Drawing
drawFunctionNode metrics theme state nodeLayout =
  Group
    ( fmap drawConnector (zip items (drop 1 items))
        <> fmap drawItem items
        <> [selectedOverlay (AnchorPart (NodeAnchor node.diagramNodeId)) state rect theme]
    )
  where
    node = nodeLayout.laidOutNode
    rect = nodeLayout.laidOutNodeRect
    items = nodeLayout.laidOutFunctionItems
    itemRect item = case item of
      FunctionEndpointLayout _ _ itemBounds -> itemBounds
      FunctionEllipsisLayout itemBounds -> itemBounds
    drawConnector (left, right) =
      let start = Point (rectRight (itemRect left)) (rectCenter (itemRect left)).pointY
          end = Point (itemRect right).rectX (rectCenter (itemRect right)).pointY
          arrowHead =
            Path
              [ MoveTo end
              , LineTo (Point (end.pointX - 9) (end.pointY - 5))
              , LineTo (Point (end.pointX - 9) (end.pointY + 5))
              , ClosePath
              ]
       in Group
            [ Stroke (solidStroke 2.8) (Solid theme.themeRelation) (PathGeometry (Path [MoveTo start, LineTo end]))
            , Fill NonZero (Solid theme.themeRelation) (PathGeometry arrowHead)
            ]
    drawItem item = case item of
      FunctionEndpointLayout index endpoint itemBounds ->
        let part = FunctionEndpointPart node.diagramNodeId index
            active = state.typeDiagramSelected == Just part
            hovered = state.typeDiagramHovered == Just part
            labelRect = insetTopRect 7 12 22 itemBounds
            detailRect = insetTopRect 29 12 16 itemBounds
            shape = RoundedRectangle itemBounds 10 10
         in Group
              [ Fill
                  NonZero
                  (Solid (if active then withAlpha 0.16 theme.themeSelection else if hovered then theme.themeHover else theme.themeCardElevated))
                  shape
              , Fill NonZero (Solid theme.themePackageAccent) (RoundedRectangle (Rect itemBounds.rectX itemBounds.rectY 5 itemBounds.rectHeight) 5 5)
              , Stroke (dashedStroke 1.2 [4, 4]) (Solid (if active then theme.themeSelection else theme.themeBorder)) shape
              , drawText
                  (ellipsizeText metrics labelRect endpoint.diagramFunctionEndpointLabel)
                  labelRect
                  (textStyle theme.themeText 12 SemiBold MonospaceFont)
                  TextStart
              , maybe
                  Empty
                  (\detail ->
                    drawText
                      (ellipsizeText metrics detailRect detail)
                      detailRect
                      (textStyle theme.themeMutedText 9 Regular MonospaceFont)
                      TextStart
                  )
                  endpoint.diagramFunctionEndpointDetail
              ]
      FunctionEllipsisLayout itemBounds ->
        let part = FunctionOverflowPart node.diagramNodeId
            active = state.typeDiagramSelected == Just part
            hovered = state.typeDiagramHovered == Just part
            shape = RoundedRectangle itemBounds 10 10
         in Group
              [ Fill NonZero (Solid (if active then withAlpha 0.16 theme.themeSelection else if hovered then theme.themeHover else theme.themeCardElevated)) shape
              , Stroke (dashedStroke 1.2 [4, 4]) (Solid (if active then theme.themeSelection else theme.themeBorder)) shape
              , drawText "…" itemBounds (textStyle theme.themeText 16 SemiBold MonospaceFont) TextCenter
              ]
    insetTopRect :: Double -> Double -> Double -> Rect -> Rect
    insetTopRect top horizontal height bounds =
      Rect
        (bounds.rectX + horizontal)
        (bounds.rectY + top)
        (bounds.rectWidth - horizontal * 2)
        height

rowWeight :: DiagramRowKind -> FontWeight
rowWeight ConstructorRow = SemiBold
rowWeight MethodRow = Medium
rowWeight _ = Regular

rowFont :: DiagramRowKind -> FontFamily
rowFont MessageRow = SystemFont
rowFont _ = MonospaceFont

kindLabel :: DiagramNodeKind -> Text
kindLabel = \case
  AlgebraicNode -> "ADT"
  NewtypeNode -> "NEWTYPE"
  AliasNode -> "ALIAS"
  ClassNode -> "CLASS"
  FamilyNode -> "FAMILY"
  UnresolvedNode -> "UNRESOLVED"
  ReferenceNodeKind -> "REFERENCE"
  FunctionNodeKind -> "FUNCTION"

selectedOverlay :: DiagramPart -> TypeDiagramState -> Rect -> DiagramTheme -> Drawing
selectedOverlay part state rect theme
  | state.typeDiagramSelected == Just part =
      Stroke (solidStroke 2.5) (Solid theme.themeSelection) (RoundedRectangle (expandRect 3 rect) 14 14)
  | otherwise = Empty

drawEmptyState :: DiagramTheme -> Rect -> Maybe Text -> [Drawing]
drawEmptyState _ _ Nothing = []
drawEmptyState theme viewport (Just message) =
  [ drawText
      "TYPE UNIVERSE"
      (Rect (viewport.rectX + 28) (viewport.rectY + 38) (viewport.rectWidth - 56) 24)
      (textStyle theme.themeMutedText 12 SemiBold MonospaceFont)
      TextStart
  , drawText
      message
      (Rect (viewport.rectX + 28) (viewport.rectY + 70) (viewport.rectWidth - 56) 80)
      (textStyle theme.themeMutedText 13 Regular SystemFont)
      TextStart
  ]

drawHoverPopover
  :: DiagramMetrics
  -> DiagramTheme
  -> TypeDiagramState
  -> LaidOutTypeDiagram
  -> Drawing
drawHoverPopover metrics theme state layout =
  case state.typeDiagramHovered >>= overflowForPart of
    Nothing -> Empty
    Just (anchor, content) ->
      let longestLine = maximum (0 : fmap Text.length (Text.lines content))
          naturalWidth = fromIntegral longestLine * metrics.diagramEstimatedCharacterWidth + 28
          width = clamp 180 metrics.diagramOverflowPopoverMaximumWidth naturalWidth
          charactersPerLine :: Int
          charactersPerLine = max 1 (floor ((width - 24) / metrics.diagramEstimatedCharacterWidth))
          visualLines :: Int
          visualLines =
            sum
              [ max 1 (ceiling (fromIntegral (Text.length line) / fromIntegral charactersPerLine :: Double))
              | line <- Text.lines content
              ]
          height = fromIntegral visualLines * 17 + 22
          popoverRect = Rect anchor.rectX (rectBottom anchor + 8) width height
          textRect = insetRect 12 popoverRect
       in Group
            [ Fill NonZero (Solid theme.themeCard) (RoundedRectangle popoverRect 10 10)
            , Stroke (solidStroke 1.2) (Solid theme.themeBorder) (RoundedRectangle popoverRect 10 10)
            , DrawText
                TextDraw
                  { drawnText = content
                  , drawnTextRect = textRect
                  , drawnTextStyle = textStyle theme.themeText 11 Regular MonospaceFont
                  , drawnTextHorizontalAlignment = TextStart
                  , drawnTextVerticalAlignment = TextMiddle
                  , drawnTextWrapping = WordWrap
                  }
            ]
  where
    overflowForPart part =
      case part of
        AnchorPart (NodeAnchor nodeId) -> do
          nodeLayout <- Map.lookup nodeId layout.laidOutNodes
          let node = nodeLayout.laidOutNode
              rect = nodeLayout.laidOutNodeRect
              titleRect =
                Rect
                  (rect.rectX + metrics.diagramCardPadding)
                  (rect.rectY + 14)
                  (rect.rectWidth - metrics.diagramCardPadding * 2 - metrics.diagramOriginBadgeWidth)
                  22
              detail = kindLabel node.diagramNodeKind <> foldMap (" · " <>) node.diagramNodeSubtitle
              detailRect = Rect (rect.rectX + metrics.diagramCardPadding) (rect.rectY + 40) (rect.rectWidth - metrics.diagramCardPadding * 2) 16
          overflowContent
            [ (titleRect, node.diagramNodeTitle)
            , (detailRect, detail)
            ]
            rect
        AnchorPart anchor -> do
          nodeLayout <- find (Map.member anchor . (.laidOutRowRects)) (Map.elems layout.laidOutNodes)
          rowRect <- Map.lookup anchor nodeLayout.laidOutRowRects
          row <- find ((== anchor) . (.diagramRowAnchor)) nodeLayout.laidOutNode.diagramNodeRows
          let indent = metrics.diagramCardPadding + fromIntegral row.diagramRowDepth * 14
              primaryTop = if row.diagramRowSecondary == Nothing then (rowRect.rectHeight - 18) / 2 else 7
              primaryRect = Rect (rowRect.rectX + indent) (rowRect.rectY + primaryTop) (rowRect.rectWidth - indent - metrics.diagramCardPadding) 18
              secondaryRect = Rect (rowRect.rectX + indent) (rowRect.rectY + 23) (rowRect.rectWidth - indent - metrics.diagramCardPadding) 16
          overflowContent
            ((primaryRect, row.diagramRowPrimary) : maybe [] (\text -> [(secondaryRect, text)]) row.diagramRowSecondary)
            rowRect
        FunctionEndpointPart nodeId index -> do
          nodeLayout <- Map.lookup nodeId layout.laidOutNodes
          FunctionEndpointLayout _ endpoint endpointRect <-
            find
              (\case FunctionEndpointLayout candidate _ _ -> candidate == index; _ -> False)
              nodeLayout.laidOutFunctionItems
          let labelRect = Rect (endpointRect.rectX + 12) (endpointRect.rectY + 7) (endpointRect.rectWidth - 24) 22
              detailRect = Rect (endpointRect.rectX + 12) (endpointRect.rectY + 29) (endpointRect.rectWidth - 24) 16
          overflowContent
            ((labelRect, endpoint.diagramFunctionEndpointLabel) : maybe [] (\text -> [(detailRect, text)]) endpoint.diagramFunctionEndpointDetail)
            endpointRect
        FunctionOverflowPart nodeId -> do
          nodeLayout <- Map.lookup nodeId layout.laidOutNodes
          pure
            ( nodeLayout.laidOutNodeRect
            , Text.intercalate
                " → "
                (fmap (.diagramFunctionEndpointLabel) nodeLayout.laidOutNode.diagramNodeFunctionEndpoints)
            )
        _ -> Nothing
    overflowContent candidates anchor =
      case [text | (rect, text) <- candidates, textRequiresTruncation metrics rect text] of
        [] -> Nothing
        values -> Just (anchor, Text.intercalate "\n" values)

textRequiresTruncation :: DiagramMetrics -> Rect -> Text -> Bool
textRequiresTruncation metrics rect text =
  fromIntegral (Text.length text) * metrics.diagramEstimatedCharacterWidth > rect.rectWidth

ellipsizeText :: DiagramMetrics -> Rect -> Text -> Text
ellipsizeText metrics rect text
  | not (textRequiresTruncation metrics rect text) = text
  | available <= 1 = "…"
  | otherwise = Text.take (available - 1) text <> "…"
  where
    available = max 1 (floor (rect.rectWidth / metrics.diagramEstimatedCharacterWidth))

clamp :: Ord value => value -> value -> value -> value
clamp lower upper = max lower . min upper

nodeHits :: Map DiagramPart DrawingHitRegionKey -> NodeLayout -> [DrawingHitTest]
nodeHits regions nodeLayout =
  [ region
      (AnchorPart (NodeAnchor node.diagramNodeId))
      OpenHandCursor
      (HitFill NonZero (RoundedRectangle nodeLayout.laidOutNodeRect 12 12))
  ]
    <> [ region (AnchorPart anchor) PointingHandCursor (HitFill NonZero (Rectangle rect))
       | (anchor, rect) <- Map.toAscList nodeLayout.laidOutRowRects
       ]
    <> [ region
           (FunctionEndpointPart node.diagramNodeId index)
           PointingHandCursor
           (HitFill NonZero (RoundedRectangle rect 10 10))
       | FunctionEndpointLayout index _ rect <- nodeLayout.laidOutFunctionItems
       ]
    <> [ region
           (FunctionOverflowPart node.diagramNodeId)
           PointingHandCursor
           (HitFill NonZero (RoundedRectangle rect 10 10))
       | FunctionEllipsisLayout rect <- nodeLayout.laidOutFunctionItems
       ]
    <> [ region (DisclosurePart entityId) PointingHandCursor (HitFill NonZero (Rectangle rect))
       | entityId <- maybeToList node.diagramNodeEntity
       , rect <- maybeToList nodeLayout.laidOutDisclosureRect
       ]
  where
    node = nodeLayout.laidOutNode
    region part cursor shape =
      DrawingHitRegion (regions Map.! part) cursor shape
    maybeToList Nothing = []
    maybeToList (Just value) = [value]

edgeHit :: Map DiagramPart DrawingHitRegionKey -> EdgeLayout -> DrawingHitTest
edgeHit regions edge =
  DrawingHitRegion
    (regions Map.! EdgePart edge.laidOutEdge.diagramEdgeId)
    PointingHandCursor
    (HitStroke (solidStroke 12) (PathGeometry edge.laidOutEdgePath))

familyHit :: Map DiagramPart DrawingHitRegionKey -> FamilyLayout -> DrawingHitTest
familyHit regions family =
  DrawingHitRegion
    (regions Map.! FamilyPart family.laidOutFamilyId)
    DefaultCursor
    (HitFill NonZero (RoundedRectangle family.laidOutFamilyRect 16 16))

disclosurePath :: Bool -> Rect -> Path
disclosurePath collapsed rect
  | collapsed =
      Path
        [ MoveTo (Point (rect.rectX + 5) (rect.rectY + 3))
        , LineTo (Point (rect.rectX + 13) (rect.rectY + 9))
        , LineTo (Point (rect.rectX + 5) (rect.rectY + 15))
        , ClosePath
        ]
  | otherwise =
      Path
        [ MoveTo (Point (rect.rectX + 3) (rect.rectY + 5))
        , LineTo (Point (rect.rectX + 9) (rect.rectY + 13))
        , LineTo (Point (rect.rectX + 15) (rect.rectY + 5))
        , ClosePath
        ]

cursorFor :: TypeDiagramState -> DrawingCursor
cursorFor state =
  case state.typeDiagramDrag of
    Just PanningDiagram -> ClosedHandCursor
    Just (DraggingNode _) -> ClosedHandCursor
    Nothing -> DefaultCursor

accessibleLabel :: TypeDiagram -> Text
accessibleLabel diagram =
  "Type universe diagram with "
    <> Text.pack (show (Map.size diagram.typeDiagramNodes))
    <> " types and "
    <> Text.pack (show (length diagram.typeDiagramEdges))
    <> " relationships"

originAccent :: DiagramTheme -> DiagramNodeOrigin -> Color
originAccent theme = \case
  CurrentDocumentNode -> theme.themeCurrentAccent
  WorkspaceNode -> theme.themeWorkspaceAccent
  PackageNode -> theme.themePackageAccent
  BuiltinNode -> theme.themeBuiltinAccent
  UnknownNode -> theme.themeUnknownAccent
  ExternalReferenceNode -> theme.themePackageAccent

originLabel :: DiagramNodeOrigin -> Text
originLabel = \case
  CurrentDocumentNode -> "LOCAL"
  WorkspaceNode -> "PROJECT"
  PackageNode -> "PACKAGE"
  BuiltinNode -> "BUILTIN"
  UnknownNode -> "UNKNOWN"
  ExternalReferenceNode -> "EXTERNAL"

drawText :: Text -> Rect -> TextStyle -> HorizontalTextAlignment -> Drawing
drawText text rect style horizontal =
  DrawText
    TextDraw
      { drawnText = text
      , drawnTextRect = rect
      , drawnTextStyle = style
      , drawnTextHorizontalAlignment = horizontal
      , drawnTextVerticalAlignment = TextMiddle
      , drawnTextWrapping = NoWrap
      }

textStyle :: Color -> Double -> FontWeight -> FontFamily -> TextStyle
textStyle foreground size weight family =
  mempty
    { textForeground = Just foreground
    , textFontSize = Just size
    , textFontWeight = Just weight
    , textFontFamily = Just family
    }

solidStroke :: Double -> StrokeStyle
solidStroke width = defaultStrokeStyle {strokeWidth = width, strokeLineCap = RoundCap, strokeLineJoin = RoundJoin}

dashedStroke :: Double -> [Double] -> StrokeStyle
dashedStroke width pattern = (solidStroke width) {strokeDashPattern = pattern}

rgb :: Double -> Double -> Double -> Color
rgb red green blue = RGBA red green blue 1

rgba :: Double -> Double -> Double -> Double -> Color
rgba = RGBA

withAlpha :: Double -> Color -> Color
withAlpha alpha color = color {colorAlpha = alpha}

insetRect :: Double -> Rect -> Rect
insetRect amount rect =
  Rect
    (rect.rectX + amount)
    (rect.rectY + amount)
    (max 0 (rect.rectWidth - amount * 2))
    (max 0 (rect.rectHeight - amount * 2))

expandRect :: Double -> Rect -> Rect
expandRect amount rect =
  Rect
    (rect.rectX - amount)
    (rect.rectY - amount)
    (rect.rectWidth + amount * 2)
    (rect.rectHeight + amount * 2)

hashText :: Text -> Word64
hashText =
  Text.foldl'
    (\hash character -> (hash `xor` fromIntegral (ord character)) * 1099511628211)
    14695981039346656037
