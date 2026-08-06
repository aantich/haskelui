{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | A backend-neutral, deterministic layout engine.
--
-- Parents constrain children, children report a legal size, and parents place
-- those children.  The engine never calls native APIs: a backend supplies a
-- pure measurement table (normally populated from a cached, batched native
-- measurement phase) and consumes the resulting 'LayoutPlan'.
module HaskeLUI.Layout
  ( Dp (..)
  , Size (..)
  , LayoutRect (..)
  , Limit (..)
  , Constraints (..)
  , LayoutDirection (..)
  , LayoutEnvironment (..)
  , defaultLayoutEnvironment
  , MeasureMode (..)
  , Measurement (..)
  , IntrinsicMetrics (..)
  , Measurer
  , metricsMeasurer
  , Insets (..)
  , noInsets
  , uniformInsets
  , AxisBounds (..)
  , unconstrainedAxis
  , exactAxis
  , BoxAlignment (..)
  , AspectMode (..)
  , Overflow (..)
  , Visibility (..)
  , BoxSpec (..)
  , defaultBoxSpec
  , LayoutAxis (..)
  , MainAlignment (..)
  , CrossAlignment (..)
  , FlowSpec (..)
  , defaultRow
  , defaultColumn
  , FlexBasis (..)
  , FlowItemSpec (..)
  , defaultFlowItem
  , FlowItem (..)
  , WrapSpec (..)
  , defaultWrap
  , Track (..)
  , GridSpec (..)
  , defaultGrid
  , GridItem (..)
  , AxisAnchor (..)
  , Anchor (..)
  , OverlaySpec (..)
  , defaultOverlay
  , OverlayItem (..)
  , CanvasSpec (..)
  , defaultCanvas
  , CanvasItem (..)
  , SplitSpec (..)
  , defaultSplit
  , SplitItem (..)
  , AdaptiveCase (..)
  , Layout (..)
  , DiagnosticSeverity (..)
  , LayoutDiagnostic (..)
  , LayoutPlan (..)
  , solveLayout
  , measureLayout
  , validateLayout
  , layoutLeafKeys
  ) where

import Data.List (mapAccumL, sort, sortOn)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe, mapMaybe)
import qualified Data.Set as Set
import Data.Text (Text)

newtype Dp = Dp {unDp :: Double}
  deriving stock (Eq, Ord, Show)
  deriving newtype (Num, Fractional, Real, RealFrac)

data Size = Size
  { sizeWidth :: !Dp
  , sizeHeight :: !Dp
  }
  deriving stock (Eq, Show)

data LayoutRect = LayoutRect
  { layoutX :: !Dp
  , layoutY :: !Dp
  , layoutWidth :: !Dp
  , layoutHeight :: !Dp
  }
  deriving stock (Eq, Show)

data Limit
  = Finite !Dp
  | Unbounded
  deriving stock (Eq, Show)

data Constraints = Constraints
  { minimumWidth :: !Dp
  , maximumWidth :: !Limit
  , minimumHeight :: !Dp
  , maximumHeight :: !Limit
  }
  deriving stock (Eq, Show)

data LayoutDirection
  = LeftToRight
  | RightToLeft
  deriving stock (Eq, Ord, Show)

data LayoutEnvironment = LayoutEnvironment
  { environmentDirection :: !LayoutDirection
  , environmentScale :: !Double
  }
  deriving stock (Eq, Show)

defaultLayoutEnvironment :: LayoutEnvironment
defaultLayoutEnvironment = LayoutEnvironment LeftToRight 1

data MeasureMode
  = MinimumContent
  | IdealContent
  | MaximumContent
  | ConstrainedContent
  deriving stock (Eq, Ord, Show)

data Measurement = Measurement
  { measuredSize :: !Size
  , measuredFirstBaseline :: !(Maybe Dp)
  , measuredLastBaseline :: !(Maybe Dp)
  }
  deriving stock (Eq, Show)

data IntrinsicMetrics = IntrinsicMetrics
  { intrinsicMinimum :: !Size
  , intrinsicIdeal :: !Size
  , intrinsicMaximum :: !Size
  , intrinsicFirstBaseline :: !(Maybe Dp)
  , intrinsicLastBaseline :: !(Maybe Dp)
  }
  deriving stock (Eq, Show)

type Measurer key = key -> MeasureMode -> Constraints -> Measurement

metricsMeasurer :: Ord key => Map key IntrinsicMetrics -> Measurer key
metricsMeasurer metrics key mode constraints =
  let fallback = IntrinsicMetrics zeroSize zeroSize zeroSize Nothing Nothing
      value = Map.findWithDefault fallback key metrics
      preferred =
        case mode of
          MinimumContent -> value.intrinsicMinimum
          IdealContent -> value.intrinsicIdeal
          MaximumContent -> value.intrinsicMaximum
          ConstrainedContent -> value.intrinsicIdeal
   in Measurement
        (constrainSize constraints preferred)
        value.intrinsicFirstBaseline
        value.intrinsicLastBaseline

data Insets = Insets
  { insetTop :: !Dp
  , insetEnd :: !Dp
  , insetBottom :: !Dp
  , insetStart :: !Dp
  }
  deriving stock (Eq, Show)

noInsets :: Insets
noInsets = Insets 0 0 0 0

uniformInsets :: Dp -> Insets
uniformInsets value = Insets value value value value

data AxisBounds = AxisBounds
  { axisMinimum :: !(Maybe Dp)
  , axisIdeal :: !(Maybe Dp)
  , axisMaximum :: !(Maybe Dp)
  }
  deriving stock (Eq, Show)

unconstrainedAxis :: AxisBounds
unconstrainedAxis = AxisBounds Nothing Nothing Nothing

exactAxis :: Dp -> AxisBounds
exactAxis value = AxisBounds (Just value) (Just value) (Just value)

data BoxAlignment
  = BoxStart
  | BoxCenter
  | BoxEnd
  | BoxStretch
  deriving stock (Eq, Ord, Show)

data AspectMode
  = AspectFit
  | AspectFill
  deriving stock (Eq, Ord, Show)

data Overflow
  = OverflowVisible
  | OverflowClip
  deriving stock (Eq, Ord, Show)

data Visibility
  = Visible
  | Invisible
  | Collapsed
  deriving stock (Eq, Ord, Show)

data BoxSpec = BoxSpec
  { boxWidth :: !AxisBounds
  , boxHeight :: !AxisBounds
  , boxPadding :: !Insets
  , boxInlineAlignment :: !BoxAlignment
  , boxBlockAlignment :: !BoxAlignment
  , boxAspectRatio :: !(Maybe (Double, AspectMode))
  , boxOverflow :: !Overflow
  , boxVisibility :: !Visibility
  }
  deriving stock (Eq, Show)

defaultBoxSpec :: BoxSpec
defaultBoxSpec =
  BoxSpec
    unconstrainedAxis
    unconstrainedAxis
    noInsets
    BoxStretch
    BoxStretch
    Nothing
    OverflowVisible
    Visible

data LayoutAxis
  = InlineAxis
  | BlockAxis
  deriving stock (Eq, Ord, Show)

data MainAlignment
  = MainStart
  | MainCenter
  | MainEnd
  | SpaceBetween
  | SpaceAround
  | SpaceEvenly
  deriving stock (Eq, Ord, Enum, Bounded, Show)

data CrossAlignment
  = CrossStart
  | CrossCenter
  | CrossEnd
  | CrossStretch
  | CrossBaseline
  deriving stock (Eq, Ord, Enum, Bounded, Show)

data FlowSpec = FlowSpec
  { flowAxis :: !LayoutAxis
  , flowGap :: !Dp
  , flowMainAlignment :: !MainAlignment
  , flowCrossAlignment :: !CrossAlignment
  , flowReverse :: !Bool
  }
  deriving stock (Eq, Show)

defaultRow :: FlowSpec
defaultRow = FlowSpec InlineAxis 0 MainStart CrossStretch False

defaultColumn :: FlowSpec
defaultColumn = FlowSpec BlockAxis 0 MainStart CrossStretch False

data FlexBasis
  = IntrinsicBasis
  | FixedBasis !Dp
  deriving stock (Eq, Show)

data FlowItemSpec = FlowItemSpec
  { itemGrow :: !Double
  , itemShrink :: !Double
  , itemBasis :: !FlexBasis
  , itemMinimumMain :: !(Maybe Dp)
  , itemMaximumMain :: !(Maybe Dp)
  , itemCrossAlignment :: !(Maybe CrossAlignment)
  }
  deriving stock (Eq, Show)

defaultFlowItem :: FlowItemSpec
defaultFlowItem = FlowItemSpec 0 1 IntrinsicBasis Nothing Nothing Nothing

data FlowItem key = FlowItem
  { flowItemSpec :: !FlowItemSpec
  , flowItemLayout :: !(Layout key)
  }
  deriving stock (Eq, Show)

data WrapSpec = WrapSpec
  { wrapFlow :: !FlowSpec
  , wrapLineGap :: !Dp
  , wrapLineAlignment :: !MainAlignment
  }
  deriving stock (Eq, Show)

defaultWrap :: WrapSpec
defaultWrap = WrapSpec defaultRow 0 MainStart

data Track
  = FixedTrack !Dp
  | AutoTrack
  | MinContentTrack
  | MaxContentTrack
  | FitContentTrack !Dp
  | FractionTrack !Double
  | MinMaxTrack !Track !Track
  deriving stock (Eq, Show)

data GridSpec = GridSpec
  { gridColumns :: ![Track]
  , gridRows :: ![Track]
  , gridColumnGap :: !Dp
  , gridRowGap :: !Dp
  , gridInlineAlignment :: !BoxAlignment
  , gridBlockAlignment :: !BoxAlignment
  }
  deriving stock (Eq, Show)

defaultGrid :: GridSpec
defaultGrid = GridSpec [FractionTrack 1] [FractionTrack 1] 0 0 BoxStretch BoxStretch

data GridItem key = GridItem
  { gridItemColumn :: !Int
  , gridItemRow :: !Int
  , gridItemColumnSpan :: !Int
  , gridItemRowSpan :: !Int
  , gridItemInlineAlignment :: !(Maybe BoxAlignment)
  , gridItemBlockAlignment :: !(Maybe BoxAlignment)
  , gridItemLayout :: !(Layout key)
  }
  deriving stock (Eq, Show)

data AxisAnchor
  = AnchorStart
  | AnchorCenter
  | AnchorEnd
  | AnchorStretch
  deriving stock (Eq, Ord, Enum, Bounded, Show)

data Anchor = Anchor
  { anchorInline :: !AxisAnchor
  , anchorBlock :: !AxisAnchor
  }
  deriving stock (Eq, Show)

data OverlaySpec = OverlaySpec
  { overlayClip :: !Bool
  }
  deriving stock (Eq, Show)

defaultOverlay :: OverlaySpec
defaultOverlay = OverlaySpec False

data OverlayItem key = OverlayItem
  { overlayItemAnchor :: !Anchor
  , overlayItemInsets :: !Insets
  , overlayItemOffsetX :: !Dp
  , overlayItemOffsetY :: !Dp
  , overlayItemLayout :: !(Layout key)
  }
  deriving stock (Eq, Show)

data CanvasSpec = CanvasSpec
  { canvasContentSize :: !(Maybe Size)
  , canvasClip :: !Bool
  }
  deriving stock (Eq, Show)

defaultCanvas :: CanvasSpec
defaultCanvas = CanvasSpec Nothing False

data CanvasItem key = CanvasItem
  { canvasItemX :: !Dp
  , canvasItemY :: !Dp
  , canvasItemWidth :: !(Maybe Dp)
  , canvasItemHeight :: !(Maybe Dp)
  , canvasItemZIndex :: !Int
  , canvasItemLayout :: !(Layout key)
  }
  deriving stock (Eq, Show)

data SplitSpec = SplitSpec
  { splitAxis :: !LayoutAxis
  , splitDivider :: !Dp
  }
  deriving stock (Eq, Show)

defaultSplit :: SplitSpec
defaultSplit = SplitSpec InlineAxis 1

data SplitItem key = SplitItem
  { splitItemMinimum :: !Dp
  , splitItemPreferred :: !Dp
  , splitItemMaximum :: !(Maybe Dp)
  , splitItemStretch :: !Double
  , splitItemLayout :: !(Layout key)
  }
  deriving stock (Eq, Show)

data AdaptiveCase key = AdaptiveCase
  { adaptiveMinimumInline :: !(Maybe Dp)
  , adaptiveMaximumInline :: !(Maybe Dp)
  , adaptiveLayout :: !(Layout key)
  }
  deriving stock (Eq, Show)

data Layout key
  = LayoutEmpty
  | LayoutLeaf !key
  | LayoutBox !BoxSpec !(Layout key)
  | LayoutFlow !FlowSpec ![FlowItem key]
  | LayoutWrap !WrapSpec ![FlowItem key]
  | LayoutGrid !GridSpec ![GridItem key]
  | LayoutOverlay !OverlaySpec ![OverlayItem key]
  | LayoutCanvas !CanvasSpec ![CanvasItem key]
  | LayoutSplit !SplitSpec ![SplitItem key]
  | LayoutAdaptive ![AdaptiveCase key] !(Layout key)
  deriving stock (Eq, Show)

data DiagnosticSeverity
  = DiagnosticWarning
  | DiagnosticError
  deriving stock (Eq, Ord, Show)

data LayoutDiagnostic key = LayoutDiagnostic
  { diagnosticSeverity :: !DiagnosticSeverity
  , diagnosticKey :: !(Maybe key)
  , diagnosticMessage :: !Text
  }
  deriving stock (Eq, Show)

data LayoutPlan key = LayoutPlan
  { layoutFrames :: !(Map key LayoutRect)
  , layoutVisibility :: !(Map key Visibility)
  , layoutPaintOrder :: ![key]
  , layoutDiagnostics :: ![LayoutDiagnostic key]
  }
  deriving stock (Eq, Show)

data Placed key = Placed
  { placedFrames :: !(Map key LayoutRect)
  , placedVisibility :: !(Map key Visibility)
  , placedOrder :: ![key]
  , placedDiagnostics :: ![LayoutDiagnostic key]
  }

emptyPlaced :: Placed key
emptyPlaced = Placed Map.empty Map.empty [] []

appendPlaced :: Ord key => Placed key -> Placed key -> Placed key
appendPlaced left right =
  Placed
    (Map.union right.placedFrames left.placedFrames)
    (Map.union right.placedVisibility left.placedVisibility)
    (left.placedOrder <> right.placedOrder)
    (left.placedDiagnostics <> right.placedDiagnostics)

solveLayout
  :: Ord key
  => LayoutEnvironment
  -> Measurer key
  -> LayoutRect
  -> Layout key
  -> LayoutPlan key
solveLayout environment measurer bounds layout =
  let placed = arrangeLayout environment measurer bounds Visible layout
   in LayoutPlan
        placed.placedFrames
        placed.placedVisibility
        placed.placedOrder
        (validateLayout layout <> placed.placedDiagnostics)

measureLayout
  :: Ord key
  => LayoutEnvironment
  -> Measurer key
  -> MeasureMode
  -> Constraints
  -> Layout key
  -> Measurement
measureLayout environment measurer mode constraints = \case
  LayoutEmpty -> zeroMeasurement
  LayoutLeaf key -> measurer key mode constraints
  LayoutBox spec child
    | spec.boxVisibility == Collapsed -> zeroMeasurement
    | otherwise -> measureBox environment measurer mode constraints spec child
  LayoutFlow spec items -> measureFlow environment measurer mode constraints spec items
  LayoutWrap spec items -> measureWrap environment measurer mode constraints spec items
  LayoutGrid spec items -> measureGrid environment measurer mode constraints spec items
  LayoutOverlay _ items ->
    let measurements =
          [ measureLayout environment measurer mode constraints item.overlayItemLayout
          | item <- items
          ]
     in Measurement
          (constrainSize constraints (maximumSize (fmap measuredSize measurements)))
          (firstPresent (fmap measuredFirstBaseline measurements))
          (firstPresent (fmap measuredLastBaseline measurements))
  LayoutCanvas spec items ->
    let natural = fromMaybe (canvasNaturalSize environment measurer mode items) spec.canvasContentSize
     in Measurement (constrainSize constraints natural) Nothing Nothing
  LayoutSplit spec items -> measureSplit environment measurer mode constraints spec items
  LayoutAdaptive cases fallback ->
    measureLayout environment measurer mode constraints (selectAdaptive constraints cases fallback)

measureBox
  :: Ord key
  => LayoutEnvironment
  -> Measurer key
  -> MeasureMode
  -> Constraints
  -> BoxSpec
  -> Layout key
  -> Measurement
measureBox environment measurer mode constraints spec child =
  let padding = normalizeInsets spec.boxPadding
      innerConstraints = insetConstraints padding constraints
      childMeasurement = measureLayout environment measurer mode innerConstraints child
      padded = addInsets padding childMeasurement.measuredSize
      bounded = applyBoxBounds spec.boxWidth spec.boxHeight padded
      aspected = applyAspect spec.boxAspectRatio bounded constraints
      finalSize = constrainSize constraints (clampBoxLimits spec.boxWidth spec.boxHeight aspected)
      top = padding.insetTop
   in Measurement
        finalSize
        ((+ top) <$> childMeasurement.measuredFirstBaseline)
        ((+ top) <$> childMeasurement.measuredLastBaseline)

measureFlow
  :: Ord key
  => LayoutEnvironment
  -> Measurer key
  -> MeasureMode
  -> Constraints
  -> FlowSpec
  -> [FlowItem key]
  -> Measurement
measureFlow environment measurer mode constraints spec items =
  let measurements =
        [ measureLayout environment measurer mode (looseForAxis spec.flowAxis constraints) item.flowItemLayout
        | item <- items
        ]
      mains = zipWith (flowBasis spec.flowAxis) items measurements
      crosses = fmap (sizeCross spec.flowAxis . measuredSize) measurements
      natural =
        sizeFromAxes
          spec.flowAxis
          (sum mains + gapsTotal spec.flowGap (length items))
          (maximumOrZero crosses)
      baselines = fmap measuredFirstBaseline measurements
   in Measurement
        (constrainSize constraints natural)
        (maximumMaybe baselines)
        (maximumMaybe (fmap measuredLastBaseline measurements))

measureWrap
  :: Ord key
  => LayoutEnvironment
  -> Measurer key
  -> MeasureMode
  -> Constraints
  -> WrapSpec
  -> [FlowItem key]
  -> Measurement
measureWrap environment measurer mode constraints spec items =
  let axis = spec.wrapFlow.flowAxis
      available = limitValue (axisConstraintMaximum axis constraints)
      measured = measureFlowItems environment measurer mode axis constraints items
      lines' = buildLines available spec.wrapFlow.flowGap measured
      lineMain = maximumOrZero [sum (fmap itemNaturalMain line) + gapsTotal spec.wrapFlow.flowGap (length line) | line <- lines']
      lineCrosses = fmap (maximumOrZero . fmap itemNaturalCross) lines'
      natural = sizeFromAxes axis lineMain (sum lineCrosses + gapsTotal spec.wrapLineGap (length lines'))
   in Measurement (constrainSize constraints natural) Nothing Nothing

measureGrid
  :: Ord key
  => LayoutEnvironment
  -> Measurer key
  -> MeasureMode
  -> Constraints
  -> GridSpec
  -> [GridItem key]
  -> Measurement
measureGrid environment measurer mode constraints spec items =
  let availableWidth = fromMaybe 0 (limitValue specWidth)
      columnSizes = resolveGridAxis environment measurer mode InlineAxis availableWidth spec.gridColumnGap spec.gridColumns items Nothing
      width = sum columnSizes + gapsTotal spec.gridColumnGap (length columnSizes)
      rowSizes = resolveGridAxis environment measurer mode BlockAxis (fromMaybe 0 (limitValue specHeight)) spec.gridRowGap spec.gridRows items (Just columnSizes)
      height = sum rowSizes + gapsTotal spec.gridRowGap (length rowSizes)
   in Measurement (constrainSize constraints (Size width height)) Nothing Nothing
  where
    specWidth = constraints.maximumWidth
    specHeight = constraints.maximumHeight

measureSplit
  :: Ord key
  => LayoutEnvironment
  -> Measurer key
  -> MeasureMode
  -> Constraints
  -> SplitSpec
  -> [SplitItem key]
  -> Measurement
measureSplit environment measurer mode constraints spec items =
  let measured =
        [ measureLayout environment measurer mode (looseForAxis spec.splitAxis constraints) item.splitItemLayout
        | item <- items
        ]
      main = sum (fmap splitItemPreferred items) + gapsTotal spec.splitDivider (length items)
      cross = maximumOrZero (fmap (sizeCross spec.splitAxis . measuredSize) measured)
   in Measurement (constrainSize constraints (sizeFromAxes spec.splitAxis main cross)) Nothing Nothing

arrangeLayout
  :: Ord key
  => LayoutEnvironment
  -> Measurer key
  -> LayoutRect
  -> Visibility
  -> Layout key
  -> Placed key
arrangeLayout environment measurer bounds inheritedVisibility = \case
  LayoutEmpty -> emptyPlaced
  LayoutLeaf key ->
    Placed
      (Map.singleton key bounds)
      (Map.singleton key inheritedVisibility)
      [key]
      []
  LayoutBox spec child
    | spec.boxVisibility == Collapsed -> markVisibility Collapsed child
    | otherwise ->
        let ownVisibility = combineVisibility inheritedVisibility spec.boxVisibility
            padding = normalizeInsets spec.boxPadding
            content = insetRect environment.environmentDirection padding bounds
            constraints =
              Constraints
                (if spec.boxInlineAlignment == BoxStretch then content.layoutWidth else 0)
                (Finite content.layoutWidth)
                (if spec.boxBlockAlignment == BoxStretch then content.layoutHeight else 0)
                (Finite content.layoutHeight)
            measured = measureLayout environment measurer ConstrainedContent constraints child
            desired = measured.measuredSize
            childWidth = alignedExtent spec.boxInlineAlignment content.layoutWidth desired.sizeWidth
            childHeight = alignedExtent spec.boxBlockAlignment content.layoutHeight desired.sizeHeight
            childRect =
              LayoutRect
                (alignedOrigin environment.environmentDirection spec.boxInlineAlignment content.layoutX content.layoutWidth childWidth)
                (alignedBlockOrigin spec.boxBlockAlignment content.layoutY content.layoutHeight childHeight)
                childWidth
                childHeight
            placed = arrangeLayout environment measurer childRect ownVisibility child
            overflowed = childWidth > content.layoutWidth + epsilon || childHeight > content.layoutHeight + epsilon
            diagnostic =
              [ LayoutDiagnostic DiagnosticWarning Nothing "Box content exceeds its allocated bounds"
              | overflowed && spec.boxOverflow == OverflowVisible
              ]
         in placed {placedDiagnostics = placed.placedDiagnostics <> diagnostic}
  LayoutFlow spec items -> arrangeFlow environment measurer bounds inheritedVisibility spec items
  LayoutWrap spec items -> arrangeWrap environment measurer bounds inheritedVisibility spec items
  LayoutGrid spec items -> arrangeGrid environment measurer bounds inheritedVisibility spec items
  LayoutOverlay _ items ->
    foldl'
      appendPlaced
      emptyPlaced
      [ arrangeOverlayItem environment measurer bounds inheritedVisibility item
      | item <- items
      ]
  LayoutCanvas _ items ->
    foldl'
      appendPlaced
      emptyPlaced
      [ let measured = measureLayout environment measurer IdealContent unboundedConstraints item.canvasItemLayout
            size = measured.measuredSize
            child =
              LayoutRect
                (bounds.layoutX + item.canvasItemX)
                (bounds.layoutY + item.canvasItemY)
                (fromMaybe size.sizeWidth item.canvasItemWidth)
                (fromMaybe size.sizeHeight item.canvasItemHeight)
         in arrangeLayout environment measurer child inheritedVisibility item.canvasItemLayout
      | item <- sortOn canvasItemZIndex items
      ]
  LayoutSplit spec items -> arrangeSplit environment measurer bounds inheritedVisibility spec items
  LayoutAdaptive cases fallback ->
    arrangeLayout environment measurer bounds inheritedVisibility (selectAdaptive (tightRectConstraints bounds) cases fallback)

arrangeFlow
  :: Ord key
  => LayoutEnvironment
  -> Measurer key
  -> LayoutRect
  -> Visibility
  -> FlowSpec
  -> [FlowItem key]
  -> Placed key
arrangeFlow environment measurer bounds inheritedVisibility spec originalItems =
  arrangeFlowItems environment measurer bounds inheritedVisibility spec items
  where
    items = if spec.flowReverse then reverse originalItems else originalItems

arrangeFlowItems
  :: Ord key
  => LayoutEnvironment
  -> Measurer key
  -> LayoutRect
  -> Visibility
  -> FlowSpec
  -> [FlowItem key]
  -> Placed key
arrangeFlowItems environment measurer bounds inheritedVisibility spec items =
  let count = length items
      availableMain = rectMain spec.flowAxis bounds
      availableCross = rectCross spec.flowAxis bounds
      natural = measureFlowItems environment measurer IdealContent spec.flowAxis (tightRectConstraints bounds) items
      bases = fmap itemNaturalMain natural
      minimums = zipWith normalizedItemMinimum items bases
      maximums = zipWith normalizedItemMaximum items bases
      grows = fmap (max 0 . itemGrow . flowItemSpec) items
      shrinks = zipWith (\item base -> max 0 item.flowItemSpec.itemShrink * unDp (max epsilon base)) items bases
      usable = max 0 (availableMain - gapsTotal spec.flowGap count)
      allocated
        | sum bases < usable = distributeUp usable bases grows maximums
        | sum bases > usable = distributeDown usable bases shrinks minimums
        | otherwise = bases
      remaining = max 0 (availableMain - sum allocated - gapsTotal spec.flowGap count)
      (leading, extraGap) = alignmentSpacing spec.flowMainAlignment remaining count
      origins = itemOrigins (rectMainOrigin spec.flowAxis bounds + leading) spec.flowGap extraGap allocated
      baselines = fmap itemBaseline natural
      lineBaseline = maximumMaybe baselines
      placed =
        [ let itemSpec = item.flowItemSpec
              crossAlignment = fromMaybe spec.flowCrossAlignment itemSpec.itemCrossAlignment
              assignedMain = allocated !! index
              remeasureConstraints = constraintsFromAxes spec.flowAxis assignedMain availableCross
              remeasured = measureLayout environment measurer ConstrainedContent remeasureConstraints item.flowItemLayout
              desiredCross = sizeCross spec.flowAxis remeasured.measuredSize
              assignedCross =
                case crossAlignment of
                  CrossStretch -> availableCross
                  _ -> min availableCross desiredCross
              crossOrigin =
                crossAlignedOrigin
                  crossAlignment
                  lineBaseline
                  remeasured.measuredFirstBaseline
                  (rectCrossOrigin spec.flowAxis bounds)
                  availableCross
                  assignedCross
              rawRect = rectFromAxes spec.flowAxis (origins !! index) crossOrigin assignedMain assignedCross
              directedRect = applyFlowDirection environment spec.flowAxis bounds rawRect
           in arrangeLayout environment measurer directedRect inheritedVisibility item.flowItemLayout
        | (index, item) <- zip [0 ..] items
        ]
      overflow = sum minimums + gapsTotal spec.flowGap count > availableMain + epsilon
      diagnostics =
        [LayoutDiagnostic DiagnosticWarning Nothing "Flow minimum sizes overflow the available main axis" | overflow]
   in (foldl' appendPlaced emptyPlaced placed) {placedDiagnostics = foldMap placedDiagnostics placed <> diagnostics}

data MeasuredFlowItem key = MeasuredFlowItem
  { measuredFlowItem :: !(FlowItem key)
  , itemNaturalMain :: !Dp
  , itemNaturalCross :: !Dp
  , itemBaseline :: !(Maybe Dp)
  }

measureFlowItems
  :: Ord key
  => LayoutEnvironment
  -> Measurer key
  -> MeasureMode
  -> LayoutAxis
  -> Constraints
  -> [FlowItem key]
  -> [MeasuredFlowItem key]
measureFlowItems environment measurer mode axis constraints items =
  [ let measured = measureLayout environment measurer mode (looseForAxis axis constraints) item.flowItemLayout
     in MeasuredFlowItem
          item
          (flowBasis axis item measured)
          (sizeCross axis measured.measuredSize)
          measured.measuredFirstBaseline
  | item <- items
  ]

arrangeWrap
  :: Ord key
  => LayoutEnvironment
  -> Measurer key
  -> LayoutRect
  -> Visibility
  -> WrapSpec
  -> [FlowItem key]
  -> Placed key
arrangeWrap environment measurer bounds inheritedVisibility spec items =
  let axis = spec.wrapFlow.flowAxis
      measured = measureFlowItems environment measurer IdealContent axis (tightRectConstraints bounds) items
      lines' = buildLines (Just (rectMain axis bounds)) spec.wrapFlow.flowGap measured
      lineCrosses = fmap (maximumOrZero . fmap itemNaturalCross) lines'
      totalCross = sum lineCrosses + gapsTotal spec.wrapLineGap (length lines')
      freeCross = max 0 (rectCross axis bounds - totalCross)
      (leading, extraGap) = alignmentSpacing spec.wrapLineAlignment freeCross (length lines')
      origins = itemOrigins (rectCrossOrigin axis bounds + leading) spec.wrapLineGap extraGap lineCrosses
      linePlaced =
        [ let lineRect = rectFromAxes axis (rectMainOrigin axis bounds) (origins !! index) (rectMain axis bounds) (lineCrosses !! index)
              lineItems = fmap measuredFlowItem line
           in arrangeFlowItems environment measurer lineRect inheritedVisibility spec.wrapFlow lineItems
        | (index, line) <- zip [0 ..] lines'
        ]
   in foldl' appendPlaced emptyPlaced linePlaced

buildLines :: Maybe Dp -> Dp -> [MeasuredFlowItem key] -> [[MeasuredFlowItem key]]
buildLines available gap items =
  reverse (finish (foldl' step ([], [], 0) items))
  where
    limit = fromMaybe (Dp (1 / 0)) available
    step
      :: ([[MeasuredFlowItem itemKey]], [MeasuredFlowItem itemKey], Dp)
      -> MeasuredFlowItem itemKey
      -> ([[MeasuredFlowItem itemKey]], [MeasuredFlowItem itemKey], Dp)
    step (completed, current, used) item =
      let required = item.itemNaturalMain + if null current then 0 else gap
       in if not (null current) && used + required > limit
            then (reverse current : completed, [item], item.itemNaturalMain)
            else (completed, item : current, used + required)
    finish (completed, current, _)
      | null current = completed
      | otherwise = reverse current : completed

arrangeGrid
  :: forall key. Ord key
  => LayoutEnvironment
  -> Measurer key
  -> LayoutRect
  -> Visibility
  -> GridSpec
  -> [GridItem key]
  -> Placed key
arrangeGrid environment measurer bounds inheritedVisibility spec items =
  if null spec.gridColumns || null spec.gridRows
    then
      emptyPlaced
        { placedDiagnostics =
            [LayoutDiagnostic DiagnosticError Nothing "Grid requires at least one column and row"]
        }
    else
      let columns = resolveGridAxis environment measurer IdealContent InlineAxis bounds.layoutWidth spec.gridColumnGap spec.gridColumns items Nothing
          rows = resolveGridAxis environment measurer IdealContent BlockAxis bounds.layoutHeight spec.gridRowGap spec.gridRows items (Just columns)
          columnOrigins = itemOrigins bounds.layoutX spec.gridColumnGap 0 columns
          rowOrigins = itemOrigins bounds.layoutY spec.gridRowGap 0 rows
          place :: GridItem key -> Placed key
          place item =
            let column = clampIndex (length columns) item.gridItemColumn
                row = clampIndex (length rows) item.gridItemRow
                columnSpan = validSpan (length columns) column item.gridItemColumnSpan
                rowSpan = validSpan (length rows) row item.gridItemRowSpan
                cellWidth = spanExtent spec.gridColumnGap columns column columnSpan
                cellHeight = spanExtent spec.gridRowGap rows row rowSpan
                cell = LayoutRect (columnOrigins !! column) (rowOrigins !! row) cellWidth cellHeight
                measured = measureLayout environment measurer ConstrainedContent (looseConstraints cellWidth cellHeight) item.gridItemLayout
                inlineAlignment = fromMaybe spec.gridInlineAlignment item.gridItemInlineAlignment
                blockAlignment = fromMaybe spec.gridBlockAlignment item.gridItemBlockAlignment
                width = alignedExtent inlineAlignment cellWidth measured.measuredSize.sizeWidth
                height = alignedExtent blockAlignment cellHeight measured.measuredSize.sizeHeight
                raw =
                  LayoutRect
                    (alignedOrigin LeftToRight inlineAlignment cell.layoutX cellWidth width)
                    (alignedBlockOrigin blockAlignment cell.layoutY cellHeight height)
                    width
                    height
                directed = if environment.environmentDirection == RightToLeft then mirrorRectX bounds raw else raw
             in arrangeLayout environment measurer directed inheritedVisibility item.gridItemLayout
          invalid =
            [ LayoutDiagnostic DiagnosticError Nothing "Grid item placement is outside the declared tracks"
            | item <- items
            , item.gridItemColumn < 0
                || item.gridItemRow < 0
                || item.gridItemColumn + max 1 item.gridItemColumnSpan > length columns
                || item.gridItemRow + max 1 item.gridItemRowSpan > length rows
            ]
          placed = foldl' appendPlaced emptyPlaced (fmap place items)
       in placed {placedDiagnostics = placed.placedDiagnostics <> invalid}

resolveGridAxis
  :: Ord key
  => LayoutEnvironment
  -> Measurer key
  -> MeasureMode
  -> LayoutAxis
  -> Dp
  -> Dp
  -> [Track]
  -> [GridItem key]
  -> Maybe [Dp]
  -> [Dp]
resolveGridAxis environment measurer mode axis available gap tracks items crossTracks =
  if null tracks
    then []
    else
      let count = length tracks
          initial = fmap trackMinimum tracks
          singleContributions =
            [ (indexFor axis item, contributionFor item)
            | item <- items
            , spanFor axis item == 1
            , let index = indexFor axis item
            , index >= 0
            , index < count
            ]
          afterSingles = foldl' growSingle initial singleContributions
          spanned = filter ((> 1) . spanFor axis) items
          afterSpans = foldl' growSpan afterSingles spanned
          fixedAndIntrinsic = sum afterSpans + gapsTotal gap count
          remaining = max 0 (available - fixedAndIntrinsic)
          fractions = fmap trackFraction tracks
       in distributeUp (sum afterSpans + remaining) afterSpans fractions (fmap trackMaximum tracks)
  where
    contributionFor item =
      let constraints = itemConstraints axis item crossTracks
          requestedMode = trackMeasureMode (tracks !! indexFor axis item)
          measured = measureLayout environment measurer requestedMode constraints item.gridItemLayout
       in sizeMain axis measured.measuredSize
    growSingle sizes (index, contribution) =
      replaceAt index (min (trackMaximum (tracks !! index)) (max (sizes !! index) contribution)) sizes
    growSpan sizes item =
      let start = indexFor axis item
          spanCount = validSpan (length tracks) start (spanFor axis item)
          current = spanExtent gap sizes start spanCount
          contribution = sizeMain axis (measureLayout environment measurer mode (itemConstraints axis item crossTracks) item.gridItemLayout).measuredSize
          deficit = max 0 (contribution - current)
          growable = [index | index <- [start .. start + spanCount - 1], trackFraction (tracks !! index) > 0 || not (isFixedTrack (tracks !! index))]
          recipients = if null growable then [start .. start + spanCount - 1] else growable
          share = if null recipients then 0 else deficit / fromIntegral (length recipients)
       in foldl' (\values index -> replaceAt index (min (trackMaximum (tracks !! index)) (values !! index + share)) values) sizes recipients

itemConstraints :: LayoutAxis -> GridItem key -> Maybe [Dp] -> Constraints
itemConstraints axis item crossTracks =
  case (axis, crossTracks) of
    (BlockAxis, Just columns) ->
      let start = clampIndex (length columns) item.gridItemColumn
          spanCount = validSpan (length columns) start item.gridItemColumnSpan
          width = sum (take spanCount (drop start columns))
       in Constraints width (Finite width) 0 Unbounded
    _ -> unboundedConstraints

arrangeOverlayItem
  :: Ord key
  => LayoutEnvironment
  -> Measurer key
  -> LayoutRect
  -> Visibility
  -> OverlayItem key
  -> Placed key
arrangeOverlayItem environment measurer bounds inheritedVisibility item =
  let insets = normalizeInsets item.overlayItemInsets
      available = insetRect environment.environmentDirection insets bounds
      measured = measureLayout environment measurer IdealContent (looseConstraints available.layoutWidth available.layoutHeight) item.overlayItemLayout
      anchor = item.overlayItemAnchor
      width = anchorExtent anchor.anchorInline available.layoutWidth measured.measuredSize.sizeWidth
      height = anchorExtent anchor.anchorBlock available.layoutHeight measured.measuredSize.sizeHeight
      x = anchorOrigin environment.environmentDirection anchor.anchorInline available.layoutX available.layoutWidth width
      y = blockAnchorOrigin anchor.anchorBlock available.layoutY available.layoutHeight height
      child = LayoutRect (x + item.overlayItemOffsetX) (y + item.overlayItemOffsetY) width height
   in arrangeLayout environment measurer child inheritedVisibility item.overlayItemLayout

arrangeSplit
  :: Ord key
  => LayoutEnvironment
  -> Measurer key
  -> LayoutRect
  -> Visibility
  -> SplitSpec
  -> [SplitItem key]
  -> Placed key
arrangeSplit environment measurer bounds inheritedVisibility spec items =
  let count = length items
      available = max 0 (rectMain spec.splitAxis bounds - gapsTotal spec.splitDivider count)
      preferred = fmap (max 0 . splitItemPreferred) items
      minimums = fmap (max 0 . splitItemMinimum) items
      maximums = fmap (fromMaybe (Dp (1 / 0)) . splitItemMaximum) items
      weights = fmap (max 0 . splitItemStretch) items
      allocated
        | sum preferred < available = distributeUp available preferred weights maximums
        | sum preferred > available = distributeDown available preferred (fmap (const 1) items) minimums
        | otherwise = preferred
      origins = itemOrigins (rectMainOrigin spec.splitAxis bounds) spec.splitDivider 0 allocated
      placed =
        [ let raw = rectFromAxes spec.splitAxis (origins !! index) (rectCrossOrigin spec.splitAxis bounds) (allocated !! index) (rectCross spec.splitAxis bounds)
              directed = applyFlowDirection environment spec.splitAxis bounds raw
           in arrangeLayout environment measurer directed inheritedVisibility item.splitItemLayout
        | (index, item) <- zip [0 ..] items
        ]
      overflow = sum minimums > available + epsilon
      diagnostics = [LayoutDiagnostic DiagnosticWarning Nothing "Split minimum extents overflow the available axis" | overflow]
      combined = foldl' appendPlaced emptyPlaced placed
   in combined {placedDiagnostics = combined.placedDiagnostics <> diagnostics}

markVisibility :: Ord key => Visibility -> Layout key -> Placed key
markVisibility visibility layout =
  let keys = layoutLeafKeys layout
   in Placed Map.empty (Map.fromList [(key, visibility) | key <- keys]) keys []

validateLayout :: Ord key => Layout key -> [LayoutDiagnostic key]
validateLayout layout = duplicateDiagnostics <> go layout
  where
    duplicateDiagnostics =
      [ LayoutDiagnostic DiagnosticError (Just key) "Layout contains the same leaf key more than once"
      | key <- Set.toList duplicateKeys
      ]
    duplicateKeys =
      Set.fromList
        [ key
        | activeKeys <- activeLayoutLeafKeys layout
        , group <- groupSorted activeKeys
        , key : _ : _ <- [group]
        ]
    go = \case
      LayoutEmpty -> []
      LayoutLeaf _ -> []
      LayoutBox spec child -> validateBox spec <> go child
      LayoutFlow spec items ->
        validateNonnegative "Flow gap" spec.flowGap
          <> foldMap (validateFlowItem . flowItemSpec) items
          <> foldMap (go . flowItemLayout) items
      LayoutWrap spec items ->
        validateNonnegative "Wrap line gap" spec.wrapLineGap
          <> validateNonnegative "Wrap item gap" spec.wrapFlow.flowGap
          <> foldMap (validateFlowItem . flowItemSpec) items
          <> foldMap (go . flowItemLayout) items
      LayoutGrid spec items ->
        [LayoutDiagnostic DiagnosticError Nothing "Grid requires at least one column and row" | null spec.gridColumns || null spec.gridRows]
          <> validateNonnegative "Grid column gap" spec.gridColumnGap
          <> validateNonnegative "Grid row gap" spec.gridRowGap
          <> foldMap validateTrack (spec.gridColumns <> spec.gridRows)
          <> [ LayoutDiagnostic DiagnosticError Nothing "Grid spans must be positive"
             | item <- items
             , item.gridItemColumnSpan <= 0 || item.gridItemRowSpan <= 0
             ]
          <> foldMap (go . gridItemLayout) items
      LayoutOverlay _ items ->
        foldMap (validateInsets . overlayItemInsets) items
          <> foldMap (go . overlayItemLayout) items
      LayoutCanvas spec items ->
        maybe [] validateSize spec.canvasContentSize
          <> [ LayoutDiagnostic DiagnosticError Nothing "Canvas item dimensions must be nonnegative"
             | item <- items
             , maybe False (< 0) item.canvasItemWidth || maybe False (< 0) item.canvasItemHeight
             ]
          <> foldMap (go . canvasItemLayout) items
      LayoutSplit spec items ->
        validateNonnegative "Split divider" spec.splitDivider
          <> [ LayoutDiagnostic DiagnosticError Nothing "Split extents and stretch weights must be nonnegative and min <= preferred <= max"
             | item <- items
             , item.splitItemMinimum < 0
                || item.splitItemPreferred < item.splitItemMinimum
                || maybe False (< item.splitItemPreferred) item.splitItemMaximum
                || item.splitItemStretch < 0
             ]
          <> foldMap (go . splitItemLayout) items
      LayoutAdaptive cases fallback ->
        [ LayoutDiagnostic DiagnosticError Nothing "Adaptive range minimum exceeds maximum"
        | item <- cases
        , Just minimumValue <- [item.adaptiveMinimumInline]
        , Just maximumValue <- [item.adaptiveMaximumInline]
        , minimumValue > maximumValue
        ]
          <> foldMap (go . adaptiveLayout) cases
          <> go fallback

validateBox :: BoxSpec -> [LayoutDiagnostic key]
validateBox spec =
  validateAxisBounds "Box width" spec.boxWidth
    <> validateAxisBounds "Box height" spec.boxHeight
    <> validateInsets spec.boxPadding
    <> case spec.boxAspectRatio of
      Just (ratio, _) | ratio <= 0 || isNaN ratio || isInfinite ratio ->
        [LayoutDiagnostic DiagnosticError Nothing "Aspect ratio must be finite and positive"]
      _ -> []

validateFlowItem :: FlowItemSpec -> [LayoutDiagnostic key]
validateFlowItem spec =
  [ LayoutDiagnostic DiagnosticError Nothing "Flex grow and shrink weights must be finite and nonnegative"
  | spec.itemGrow < 0
      || spec.itemShrink < 0
      || isNaN spec.itemGrow
      || isNaN spec.itemShrink
      || isInfinite spec.itemGrow
      || isInfinite spec.itemShrink
  ]
    <> [ LayoutDiagnostic DiagnosticError Nothing "Flow item minimum exceeds maximum"
       | Just minimumValue <- [spec.itemMinimumMain]
       , Just maximumValue <- [spec.itemMaximumMain]
       , minimumValue > maximumValue
       ]
    <> case spec.itemBasis of
      FixedBasis value -> validateNonnegative "Fixed flex basis" value
      IntrinsicBasis -> []

validateTrack :: Track -> [LayoutDiagnostic key]
validateTrack = \case
  FixedTrack value -> validateNonnegative "Fixed grid track" value
  FitContentTrack value -> validateNonnegative "Fit-content grid track" value
  FractionTrack weight ->
    [LayoutDiagnostic DiagnosticError Nothing "Grid fractional weight must be finite and nonnegative" | weight < 0 || isNaN weight || isInfinite weight]
  MinMaxTrack minimumTrack maximumTrack ->
    [LayoutDiagnostic DiagnosticError Nothing "A fractional track cannot be the minimum of minmax" | trackFraction minimumTrack > 0]
      <> validateTrack minimumTrack
      <> validateTrack maximumTrack
  _ -> []

validateAxisBounds :: Text -> AxisBounds -> [LayoutDiagnostic key]
validateAxisBounds label bounds =
  [LayoutDiagnostic DiagnosticError Nothing (label <> " values must be finite and nonnegative") | any invalid values]
    <> [LayoutDiagnostic DiagnosticError Nothing (label <> " minimum exceeds maximum") | Just minimumValue <- [bounds.axisMinimum], Just maximumValue <- [bounds.axisMaximum], minimumValue > maximumValue]
  where
    values = mapMaybe id [bounds.axisMinimum, bounds.axisIdeal, bounds.axisMaximum]
    invalid (Dp value) = value < 0 || isNaN value || isInfinite value

validateInsets :: Insets -> [LayoutDiagnostic key]
validateInsets insets =
  [LayoutDiagnostic DiagnosticError Nothing "Insets must be finite and nonnegative" | any invalid [insets.insetTop, insets.insetEnd, insets.insetBottom, insets.insetStart]]
  where
    invalid (Dp value) = value < 0 || isNaN value || isInfinite value

validateNonnegative :: Text -> Dp -> [LayoutDiagnostic key]
validateNonnegative label (Dp value) =
  [LayoutDiagnostic DiagnosticError Nothing (label <> " must be finite and nonnegative") | value < 0 || isNaN value || isInfinite value]

validateSize :: Size -> [LayoutDiagnostic key]
validateSize size = validateNonnegative "Width" size.sizeWidth <> validateNonnegative "Height" size.sizeHeight

layoutLeafKeys :: Layout key -> [key]
layoutLeafKeys = \case
  LayoutEmpty -> []
  LayoutLeaf key -> [key]
  LayoutBox _ child -> layoutLeafKeys child
  LayoutFlow _ items -> foldMap (layoutLeafKeys . flowItemLayout) items
  LayoutWrap _ items -> foldMap (layoutLeafKeys . flowItemLayout) items
  LayoutGrid _ items -> foldMap (layoutLeafKeys . gridItemLayout) items
  LayoutOverlay _ items -> foldMap (layoutLeafKeys . overlayItemLayout) items
  LayoutCanvas _ items -> foldMap (layoutLeafKeys . canvasItemLayout) items
  LayoutSplit _ items -> foldMap (layoutLeafKeys . splitItemLayout) items
  LayoutAdaptive cases fallback -> foldMap (layoutLeafKeys . adaptiveLayout) cases <> layoutLeafKeys fallback

-- Each list represents one simultaneously active branch.  Adaptive alternatives
-- may intentionally reference the same retained controls without creating
-- duplicate peers.
activeLayoutLeafKeys :: Layout key -> [[key]]
activeLayoutLeafKeys = \case
  LayoutEmpty -> [[]]
  LayoutLeaf key -> [[key]]
  LayoutBox _ child -> activeLayoutLeafKeys child
  LayoutFlow _ items -> combineActive (fmap (activeLayoutLeafKeys . flowItemLayout) items)
  LayoutWrap _ items -> combineActive (fmap (activeLayoutLeafKeys . flowItemLayout) items)
  LayoutGrid _ items -> combineActive (fmap (activeLayoutLeafKeys . gridItemLayout) items)
  LayoutOverlay _ items -> combineActive (fmap (activeLayoutLeafKeys . overlayItemLayout) items)
  LayoutCanvas _ items -> combineActive (fmap (activeLayoutLeafKeys . canvasItemLayout) items)
  LayoutSplit _ items -> combineActive (fmap (activeLayoutLeafKeys . splitItemLayout) items)
  LayoutAdaptive cases fallback ->
    foldMap (activeLayoutLeafKeys . adaptiveLayout) cases <> activeLayoutLeafKeys fallback

combineActive :: [[[key]]] -> [[key]]
combineActive = fmap concat . sequence

selectAdaptive :: forall key. Constraints -> [AdaptiveCase key] -> Layout key -> Layout key
selectAdaptive constraints cases fallback =
  fromMaybe fallback $ do
    width <- limitValue constraints.maximumWidth
    adaptiveLayout <$> firstMatching width cases
  where
    firstMatching :: Dp -> [AdaptiveCase key] -> Maybe (AdaptiveCase key)
    firstMatching _ [] = Nothing
    firstMatching width (candidate : rest)
      | maybe True (<= width) candidate.adaptiveMinimumInline
          && maybe True (>= width) candidate.adaptiveMaximumInline = Just candidate
      | otherwise = firstMatching width rest

constrainSize :: Constraints -> Size -> Size
constrainSize constraints size =
  Size
    (clampLimit constraints.minimumWidth constraints.maximumWidth size.sizeWidth)
    (clampLimit constraints.minimumHeight constraints.maximumHeight size.sizeHeight)

applyBoxBounds :: AxisBounds -> AxisBounds -> Size -> Size
applyBoxBounds widthBounds heightBounds size =
  Size (applyAxisBounds widthBounds size.sizeWidth) (applyAxisBounds heightBounds size.sizeHeight)

clampBoxLimits :: AxisBounds -> AxisBounds -> Size -> Size
clampBoxLimits widthBounds heightBounds size =
  Size (clampAxisLimits widthBounds size.sizeWidth) (clampAxisLimits heightBounds size.sizeHeight)

clampAxisLimits :: AxisBounds -> Dp -> Dp
clampAxisLimits bounds value =
  let minimumValue = max 0 (fromMaybe 0 bounds.axisMinimum)
      maximumValue = max minimumValue (fromMaybe (Dp (1 / 0)) bounds.axisMaximum)
   in max minimumValue (min maximumValue value)

applyAxisBounds :: AxisBounds -> Dp -> Dp
applyAxisBounds bounds natural =
  let minimumValue = max 0 (fromMaybe 0 bounds.axisMinimum)
      maximumValue = max minimumValue (fromMaybe (Dp (1 / 0)) bounds.axisMaximum)
      idealValue = fromMaybe natural bounds.axisIdeal
   in max minimumValue (min maximumValue idealValue)

applyAspect :: Maybe (Double, AspectMode) -> Size -> Constraints -> Size
applyAspect Nothing size _ = size
applyAspect (Just (ratio, mode)) size constraints
  | ratio <= 0 = size
  | otherwise =
      let widthFromHeight = size.sizeHeight * realToFrac ratio
          heightFromWidth = size.sizeWidth / realToFrac ratio
          candidate =
            case mode of
              AspectFit
                | widthFromHeight <= size.sizeWidth -> Size widthFromHeight size.sizeHeight
                | otherwise -> Size size.sizeWidth heightFromWidth
              AspectFill
                | widthFromHeight >= size.sizeWidth -> Size widthFromHeight size.sizeHeight
                | otherwise -> Size size.sizeWidth heightFromWidth
       in constrainSize constraints candidate

insetConstraints :: Insets -> Constraints -> Constraints
insetConstraints insets constraints =
  let horizontal = insets.insetStart + insets.insetEnd
      vertical = insets.insetTop + insets.insetBottom
   in Constraints
        (max 0 (constraints.minimumWidth - horizontal))
        (subtractLimit horizontal constraints.maximumWidth)
        (max 0 (constraints.minimumHeight - vertical))
        (subtractLimit vertical constraints.maximumHeight)

looseForAxis :: LayoutAxis -> Constraints -> Constraints
looseForAxis InlineAxis constraints = constraints {minimumWidth = 0, maximumWidth = Unbounded, minimumHeight = 0}
looseForAxis BlockAxis constraints = constraints {minimumWidth = 0, minimumHeight = 0, maximumHeight = Unbounded}

constraintsFromAxes :: LayoutAxis -> Dp -> Dp -> Constraints
constraintsFromAxes InlineAxis main cross = Constraints main (Finite main) 0 (Finite cross)
constraintsFromAxes BlockAxis main cross = Constraints 0 (Finite cross) main (Finite main)

unboundedConstraints :: Constraints
unboundedConstraints = Constraints 0 Unbounded 0 Unbounded

looseConstraints :: Dp -> Dp -> Constraints
looseConstraints width height = Constraints 0 (Finite (max 0 width)) 0 (Finite (max 0 height))

tightRectConstraints :: LayoutRect -> Constraints
tightRectConstraints rect = Constraints rect.layoutWidth (Finite rect.layoutWidth) rect.layoutHeight (Finite rect.layoutHeight)

normalizeInsets :: Insets -> Insets
normalizeInsets insets =
  Insets
    (max 0 insets.insetTop)
    (max 0 insets.insetEnd)
    (max 0 insets.insetBottom)
    (max 0 insets.insetStart)

addInsets :: Insets -> Size -> Size
addInsets insets size =
  Size
    (size.sizeWidth + insets.insetStart + insets.insetEnd)
    (size.sizeHeight + insets.insetTop + insets.insetBottom)

insetRect :: LayoutDirection -> Insets -> LayoutRect -> LayoutRect
insetRect direction insets rect =
  let leading = if direction == LeftToRight then insets.insetStart else insets.insetEnd
   in LayoutRect
        (rect.layoutX + leading)
        (rect.layoutY + insets.insetTop)
        (max 0 (rect.layoutWidth - insets.insetStart - insets.insetEnd))
        (max 0 (rect.layoutHeight - insets.insetTop - insets.insetBottom))

alignedExtent :: BoxAlignment -> Dp -> Dp -> Dp
alignedExtent BoxStretch available _ = available
alignedExtent _ available desired = min available desired

alignedOrigin :: LayoutDirection -> BoxAlignment -> Dp -> Dp -> Dp -> Dp
alignedOrigin direction alignment origin available extent =
  case (direction, alignment) of
    (_, BoxCenter) -> origin + (available - extent) / 2
    (LeftToRight, BoxEnd) -> origin + available - extent
    (RightToLeft, BoxStart) -> origin + available - extent
    (RightToLeft, BoxEnd) -> origin
    _ -> origin

alignedBlockOrigin :: BoxAlignment -> Dp -> Dp -> Dp -> Dp
alignedBlockOrigin BoxCenter origin available extent = origin + (available - extent) / 2
alignedBlockOrigin BoxEnd origin available extent = origin + available - extent
alignedBlockOrigin _ origin _ _ = origin

anchorExtent :: AxisAnchor -> Dp -> Dp -> Dp
anchorExtent AnchorStretch available _ = available
anchorExtent _ available desired = min available desired

anchorOrigin :: LayoutDirection -> AxisAnchor -> Dp -> Dp -> Dp -> Dp
anchorOrigin direction anchor origin available extent =
  case (direction, anchor) of
    (_, AnchorCenter) -> origin + (available - extent) / 2
    (LeftToRight, AnchorEnd) -> origin + available - extent
    (RightToLeft, AnchorStart) -> origin + available - extent
    (RightToLeft, AnchorEnd) -> origin
    _ -> origin

blockAnchorOrigin :: AxisAnchor -> Dp -> Dp -> Dp -> Dp
blockAnchorOrigin AnchorCenter origin available extent = origin + (available - extent) / 2
blockAnchorOrigin AnchorEnd origin available extent = origin + available - extent
blockAnchorOrigin _ origin _ _ = origin

crossAlignedOrigin :: CrossAlignment -> Maybe Dp -> Maybe Dp -> Dp -> Dp -> Dp -> Dp
crossAlignedOrigin CrossCenter _ _ origin available extent = origin + (available - extent) / 2
crossAlignedOrigin CrossEnd _ _ origin available extent = origin + available - extent
crossAlignedOrigin CrossBaseline (Just line) (Just child) origin _ _ = origin + line - child
crossAlignedOrigin _ _ _ origin _ _ = origin

combineVisibility :: Visibility -> Visibility -> Visibility
combineVisibility Collapsed _ = Collapsed
combineVisibility _ Collapsed = Collapsed
combineVisibility Invisible _ = Invisible
combineVisibility _ Invisible = Invisible
combineVisibility Visible Visible = Visible

applyFlowDirection :: LayoutEnvironment -> LayoutAxis -> LayoutRect -> LayoutRect -> LayoutRect
applyFlowDirection environment axis parent child
  | environment.environmentDirection == RightToLeft && axis == InlineAxis = mirrorRectX parent child
  | environment.environmentDirection == RightToLeft && axis == BlockAxis = mirrorRectX parent child
  | otherwise = child

mirrorRectX :: LayoutRect -> LayoutRect -> LayoutRect
mirrorRectX parent child =
  child
    { layoutX =
        parent.layoutX
          + parent.layoutWidth
          - (child.layoutX - parent.layoutX)
          - child.layoutWidth
    }

flowBasis :: LayoutAxis -> FlowItem key -> Measurement -> Dp
flowBasis axis item measurement =
  let natural = sizeMain axis measurement.measuredSize
   in case item.flowItemSpec.itemBasis of
        IntrinsicBasis -> natural
        FixedBasis value -> max 0 value

normalizedItemMinimum :: FlowItem key -> Dp -> Dp
normalizedItemMinimum item _ = max 0 (fromMaybe 0 item.flowItemSpec.itemMinimumMain)

normalizedItemMaximum :: FlowItem key -> Dp -> Dp
normalizedItemMaximum item base =
  max (normalizedItemMinimum item base) (fromMaybe (Dp (1 / 0)) item.flowItemSpec.itemMaximumMain)

distributeUp :: Dp -> [Dp] -> [Double] -> [Dp] -> [Dp]
distributeUp target initial weights maximums = go initial
  where
    go values
      | remaining <= epsilon = values
      | totalWeight <= 0 = values
      | otherwise =
          let proposed =
                zipWith3
                  (\value weight maximumValue -> min maximumValue (value + remaining * realToFrac (weight / totalWeight)))
                  values
                  activeWeights
                  maximums
           in if sum proposed <= sum values + epsilon then values else go proposed
      where
        remaining = max 0 (target - sum values)
        activeWeights = zipWith3 (\value weight maximumValue -> if value + epsilon < maximumValue then max 0 weight else 0) values weights maximums
        totalWeight = sum activeWeights

distributeDown :: Dp -> [Dp] -> [Double] -> [Dp] -> [Dp]
distributeDown target initial weights minimums = go initial
  where
    go values
      | deficit <= epsilon = values
      | totalWeight <= 0 = values
      | otherwise =
          let proposed =
                zipWith3
                  (\value weight minimumValue -> max minimumValue (value - deficit * realToFrac (weight / totalWeight)))
                  values
                  activeWeights
                  minimums
           in if sum proposed >= sum values - epsilon then values else go proposed
      where
        deficit = max 0 (sum values - target)
        activeWeights = zipWith3 (\value weight minimumValue -> if value > minimumValue + epsilon then max 0 weight else 0) values weights minimums
        totalWeight = sum activeWeights

alignmentSpacing :: MainAlignment -> Dp -> Int -> (Dp, Dp)
alignmentSpacing alignment free count =
  case alignment of
    MainStart -> (0, 0)
    MainCenter -> (free / 2, 0)
    MainEnd -> (free, 0)
    SpaceBetween
      | count > 1 -> (0, free / fromIntegral (count - 1))
      | otherwise -> (0, 0)
    SpaceAround
      | count > 0 -> let gap = free / fromIntegral count in (gap / 2, gap)
      | otherwise -> (0, 0)
    SpaceEvenly
      | count > 0 -> let gap = free / fromIntegral (count + 1) in (gap, gap)
      | otherwise -> (0, 0)

itemOrigins :: Dp -> Dp -> Dp -> [Dp] -> [Dp]
itemOrigins origin gap extraGap sizes = snd (mapAccumL step origin sizes)
  where
    step current size = (current + size + gap + extraGap, current)

sizeMain :: LayoutAxis -> Size -> Dp
sizeMain InlineAxis = sizeWidth
sizeMain BlockAxis = sizeHeight

sizeCross :: LayoutAxis -> Size -> Dp
sizeCross InlineAxis = sizeHeight
sizeCross BlockAxis = sizeWidth

sizeFromAxes :: LayoutAxis -> Dp -> Dp -> Size
sizeFromAxes InlineAxis main cross = Size main cross
sizeFromAxes BlockAxis main cross = Size cross main

rectMain :: LayoutAxis -> LayoutRect -> Dp
rectMain InlineAxis = layoutWidth
rectMain BlockAxis = layoutHeight

rectCross :: LayoutAxis -> LayoutRect -> Dp
rectCross InlineAxis = layoutHeight
rectCross BlockAxis = layoutWidth

rectMainOrigin :: LayoutAxis -> LayoutRect -> Dp
rectMainOrigin InlineAxis = layoutX
rectMainOrigin BlockAxis = layoutY

rectCrossOrigin :: LayoutAxis -> LayoutRect -> Dp
rectCrossOrigin InlineAxis = layoutY
rectCrossOrigin BlockAxis = layoutX

rectFromAxes :: LayoutAxis -> Dp -> Dp -> Dp -> Dp -> LayoutRect
rectFromAxes InlineAxis mainOrigin crossOrigin mainExtent crossExtent = LayoutRect mainOrigin crossOrigin mainExtent crossExtent
rectFromAxes BlockAxis mainOrigin crossOrigin mainExtent crossExtent = LayoutRect crossOrigin mainOrigin crossExtent mainExtent

axisConstraintMaximum :: LayoutAxis -> Constraints -> Limit
axisConstraintMaximum InlineAxis = maximumWidth
axisConstraintMaximum BlockAxis = maximumHeight

gapsTotal :: Dp -> Int -> Dp
gapsTotal gap count = max 0 gap * fromIntegral (max 0 (count - 1))

maximumSize :: [Size] -> Size
maximumSize sizes = Size (maximumOrZero (fmap sizeWidth sizes)) (maximumOrZero (fmap sizeHeight sizes))

maximumOrZero :: [Dp] -> Dp
maximumOrZero [] = 0
maximumOrZero values = maximum values

maximumMaybe :: [Maybe Dp] -> Maybe Dp
maximumMaybe values =
  case mapMaybe id values of
    [] -> Nothing
    present -> Just (maximum present)

firstPresent :: [Maybe value] -> Maybe value
firstPresent [] = Nothing
firstPresent (Just value : _) = Just value
firstPresent (Nothing : rest) = firstPresent rest

zeroSize :: Size
zeroSize = Size 0 0

zeroMeasurement :: Measurement
zeroMeasurement = Measurement zeroSize Nothing Nothing

clampLimit :: Dp -> Limit -> Dp -> Dp
clampLimit minimumValue Unbounded value = max minimumValue value
clampLimit minimumValue (Finite maximumValue) value = max minimumValue (min (max minimumValue maximumValue) value)

subtractLimit :: Dp -> Limit -> Limit
subtractLimit _ Unbounded = Unbounded
subtractLimit value (Finite maximumValue) = Finite (max 0 (maximumValue - value))

limitValue :: Limit -> Maybe Dp
limitValue Unbounded = Nothing
limitValue (Finite value) = Just value

trackMinimum :: Track -> Dp
trackMinimum = \case
  FixedTrack value -> max 0 value
  FitContentTrack _ -> 0
  MinMaxTrack minimumTrack _ -> trackMinimum minimumTrack
  _ -> 0

trackMaximum :: Track -> Dp
trackMaximum = \case
  FixedTrack value -> max 0 value
  FitContentTrack value -> max 0 value
  MinMaxTrack _ maximumTrack -> trackMaximum maximumTrack
  _ -> Dp (1 / 0)

trackFraction :: Track -> Double
trackFraction = \case
  FractionTrack value -> max 0 value
  MinMaxTrack _ maximumTrack -> trackFraction maximumTrack
  _ -> 0

trackMeasureMode :: Track -> MeasureMode
trackMeasureMode = \case
  MinContentTrack -> MinimumContent
  MaxContentTrack -> MaximumContent
  FitContentTrack _ -> MaximumContent
  MinMaxTrack minimumTrack maximumTrack -> max (trackMeasureMode minimumTrack) (trackMeasureMode maximumTrack)
  _ -> IdealContent

isFixedTrack :: Track -> Bool
isFixedTrack FixedTrack {} = True
isFixedTrack (MinMaxTrack (FixedTrack _) (FixedTrack _)) = True
isFixedTrack _ = False

indexFor :: LayoutAxis -> GridItem key -> Int
indexFor InlineAxis = gridItemColumn
indexFor BlockAxis = gridItemRow

spanFor :: LayoutAxis -> GridItem key -> Int
spanFor InlineAxis = gridItemColumnSpan
spanFor BlockAxis = gridItemRowSpan

spanExtent :: Dp -> [Dp] -> Int -> Int -> Dp
spanExtent gap values start count = sum (take count (drop start values)) + gapsTotal gap count

validSpan :: Int -> Int -> Int -> Int
validSpan total start requested = max 1 (min (max 1 requested) (max 1 (total - start)))

clampIndex :: Int -> Int -> Int
clampIndex count value = max 0 (min (max 0 (count - 1)) value)

replaceAt :: Int -> value -> [value] -> [value]
replaceAt index value values =
  [if current == index then value else existing | (current, existing) <- zip [0 ..] values]

canvasNaturalSize
  :: Ord key
  => LayoutEnvironment
  -> Measurer key
  -> MeasureMode
  -> [CanvasItem key]
  -> Size
canvasNaturalSize environment measurer mode items =
  Size
    (maximumOrZero [item.canvasItemX + fromMaybe measured.measuredSize.sizeWidth item.canvasItemWidth | item <- items, let measured = measureLayout environment measurer mode unboundedConstraints item.canvasItemLayout])
    (maximumOrZero [item.canvasItemY + fromMaybe measured.measuredSize.sizeHeight item.canvasItemHeight | item <- items, let measured = measureLayout environment measurer mode unboundedConstraints item.canvasItemLayout])

groupSorted :: Ord value => [value] -> [[value]]
groupSorted = foldr step [] . sort
  where
    step value [] = [[value]]
    step value (current@(first : _) : rest)
      | value == first = (value : current) : rest
      | otherwise = [value] : current : rest
    step value ([] : rest) = [value] : [] : rest

epsilon :: Dp
epsilon = 0.000001
