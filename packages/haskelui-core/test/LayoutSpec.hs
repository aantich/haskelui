{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

module LayoutSpec (runLayoutTests) where

import Control.Monad (forM_)
import qualified Data.Map.Strict as Map
import qualified Data.Text as Text
import HaskeLUI.Core

runLayoutTests :: IO ()
runLayoutTests = do
  testBox
  testMainAlignments
  testCrossAlignments
  testFlexGrowthAndShrink
  testDirection
  testWrap
  testGrid
  testTableGrid
  testOverlay
  testCanvas
  testSplit
  testAdaptive
  testVisibility
  testStrategyVariants
  testValidation
  testControlIntegration
  testGeometryProperties
  testLargeTree
  putStrLn "haskelui-layout: all box, flow, wrap, grid, overlay, canvas, split, adaptive, validation, and scale tests passed"

testBox :: IO ()
testBox = do
  let centered =
        LayoutBox
          defaultBoxSpec
            { boxPadding = uniformInsets 10
            , boxInlineAlignment = BoxCenter
            , boxBlockAlignment = BoxCenter
            }
          (LayoutLeaf 1)
      plan = solve centered (LayoutRect 0 0 100 80) (Map.singleton 1 (metric 0 0 20 10 80 40 7))
  assertRect "centered padded box" (LayoutRect 40 35 20 10) (frame 1 plan)

  let fixedBox =
        LayoutFlow
          defaultRow {flowCrossAlignment = CrossStart}
          [ FlowItem
              defaultFlowItem
              ( LayoutBox
                  defaultBoxSpec
                    { boxWidth = exactAxis 100
                    , boxHeight = exactAxis 50
                    }
                  (LayoutLeaf 1)
              )
          ]
      fixedPlan = solve fixedBox (LayoutRect 0 0 200 100) (Map.singleton 1 (metric 0 0 10 10 50 50 7))
  assertRect "exact box bounds" (LayoutRect 0 0 100 50) (frame 1 fixedPlan)

  let aspectBox =
        LayoutFlow
          defaultRow {flowCrossAlignment = CrossStart}
          [ FlowItem
              defaultFlowItem
              ( LayoutBox
                  defaultBoxSpec
                    { boxWidth = exactAxis 100
                    , boxHeight = AxisBounds Nothing (Just 100) Nothing
                    , boxAspectRatio = Just (2, AspectFit)
                    }
                  (LayoutLeaf 1)
              )
          ]
      aspectPlan = solve aspectBox (LayoutRect 0 0 200 120) (Map.singleton 1 (metric 0 0 20 20 100 100 10))
  assertNear "aspect ratio width" 100 (frame 1 aspectPlan).layoutWidth
  assertNear "aspect ratio height" 50 (frame 1 aspectPlan).layoutHeight

testMainAlignments :: IO ()
testMainAlignments = do
  let expected =
        [ (MainStart, (0, 20))
        , (MainCenter, (30, 50))
        , (MainEnd, (60, 80))
        , (SpaceBetween, (0, 80))
        , (SpaceAround, (15, 65))
        , (SpaceEvenly, (20, 60))
        ]
      metrics = uniformMetrics [(1, 20, 10), (2, 20, 10)]
  forM_ expected $ \(alignment, (firstOrigin, secondOrigin)) -> do
    let layout = LayoutFlow defaultRow {flowMainAlignment = alignment, flowCrossAlignment = CrossStart} (naturalLeaves [1, 2])
        plan = solve layout (LayoutRect 0 0 100 30) metrics
    assertNear (show alignment <> " first") firstOrigin (frame 1 plan).layoutX
    assertNear (show alignment <> " second") secondOrigin (frame 2 plan).layoutX

testCrossAlignments :: IO ()
testCrossAlignments = do
  let metrics = uniformMetrics [(1, 20, 20)]
      expected =
        [ (CrossStart, LayoutRect 0 0 20 20)
        , (CrossCenter, LayoutRect 0 20 20 20)
        , (CrossEnd, LayoutRect 0 40 20 20)
        , (CrossStretch, LayoutRect 0 0 20 60)
        ]
  forM_ expected $ \(alignment, expectedRect) -> do
    let layout = LayoutFlow defaultRow {flowCrossAlignment = alignment} (naturalLeaves [1])
    assertRect (show alignment) expectedRect (frame 1 (solve layout (LayoutRect 0 0 100 60) metrics))

  let baselineMetrics =
        Map.fromList
          [ (1, metric 0 0 20 20 20 20 15)
          , (2, metric 0 0 20 20 20 20 10)
          ]
      baselineLayout = LayoutFlow defaultRow {flowCrossAlignment = CrossBaseline} (naturalLeaves [1, 2])
      baselinePlan = solve baselineLayout (LayoutRect 0 0 100 60) baselineMetrics
  assertNear "baseline first" 0 (frame 1 baselinePlan).layoutY
  assertNear "baseline second" 5 (frame 2 baselinePlan).layoutY

testFlexGrowthAndShrink :: IO ()
testFlexGrowthAndShrink = do
  let metrics = uniformMetrics [(1, 50, 20), (2, 50, 20)]
      growing =
        LayoutFlow
          defaultRow {flowGap = 10, flowCrossAlignment = CrossStart}
          [ FlowItem defaultFlowItem {itemGrow = 1} (LayoutLeaf 1)
          , FlowItem defaultFlowItem {itemGrow = 2} (LayoutLeaf 2)
          ]
      growPlan = solve growing (LayoutRect 0 0 300 40) metrics
  assertNear "flex grow one" (Dp (50 + 190 / 3)) (frame 1 growPlan).layoutWidth
  assertNear "flex grow two" (Dp (50 + 380 / 3)) (frame 2 growPlan).layoutWidth
  assertNear "flex grow gap" ((frame 1 growPlan).layoutWidth + 10) (frame 2 growPlan).layoutX

  let shrinking =
        LayoutFlow
          defaultRow {flowCrossAlignment = CrossStart}
          [ FlowItem defaultFlowItem {itemMinimumMain = Just 50} (LayoutLeaf 1)
          , FlowItem defaultFlowItem {itemMinimumMain = Just 10} (LayoutLeaf 2)
          ]
      shrinkMetrics = uniformMetrics [(1, 60, 20), (2, 60, 20)]
      shrinkPlan = solve shrinking (LayoutRect 0 0 80 40) shrinkMetrics
  assertNear "flex shrink freezes at minimum" 50 (frame 1 shrinkPlan).layoutWidth
  assertNear "flex shrink redistributes deficit" 30 (frame 2 shrinkPlan).layoutWidth

testDirection :: IO ()
testDirection = do
  let metrics = uniformMetrics [(1, 20, 10), (2, 20, 10)]
      rowLayout = LayoutFlow defaultRow {flowCrossAlignment = CrossStart} (naturalLeaves [1, 2])
      rtlPlan = solveWith defaultLayoutEnvironment {environmentDirection = RightToLeft} rowLayout (LayoutRect 0 0 100 30) metrics
  assertNear "RTL first starts at trailing edge" 80 (frame 1 rtlPlan).layoutX
  assertNear "RTL second follows toward start" 60 (frame 2 rtlPlan).layoutX

  let columnLayout = LayoutFlow defaultColumn {flowCrossAlignment = CrossStart} (naturalLeaves [1])
      columnPlan = solveWith defaultLayoutEnvironment {environmentDirection = RightToLeft} columnLayout (LayoutRect 0 0 100 40) metrics
  assertNear "RTL column cross-start" 80 (frame 1 columnPlan).layoutX

testWrap :: IO ()
testWrap = do
  let layout =
        LayoutWrap
          defaultWrap
            { wrapFlow = defaultRow {flowGap = 10, flowCrossAlignment = CrossStart}
            , wrapLineGap = 5
            }
          (naturalLeaves [1, 2, 3])
      plan = solve layout (LayoutRect 0 0 100 60) (uniformMetrics [(1, 40, 10), (2, 40, 10), (3, 40, 10)])
  assertRect "wrap first" (LayoutRect 0 0 40 10) (frame 1 plan)
  assertRect "wrap second" (LayoutRect 50 0 40 10) (frame 2 plan)
  assertRect "wrap next line" (LayoutRect 0 15 40 10) (frame 3 plan)

testGrid :: IO ()
testGrid = do
  let spec =
        defaultGrid
          { gridColumns = [FixedTrack 50, AutoTrack, FractionTrack 1]
          , gridRows = [FractionTrack 1]
          , gridColumnGap = 5
          , gridInlineAlignment = BoxStretch
          , gridBlockAlignment = BoxStretch
          }
      items =
        [ gridItem 0 0 1
        , gridItem 1 0 2
        , gridItem 2 0 3
        ]
      plan = solve (LayoutGrid spec items) (LayoutRect 0 0 200 40) (uniformMetrics [(1, 20, 10), (2, 30, 10), (3, 10, 10)])
  assertRect "fixed grid track" (LayoutRect 0 0 50 40) (frame 1 plan)
  assertRect "content grid track" (LayoutRect 55 0 30 40) (frame 2 plan)
  assertRect "fractional grid track" (LayoutRect 90 0 110 40) (frame 3 plan)

  let intrinsicSpec =
        defaultGrid
          { gridColumns = [MinContentTrack, MaxContentTrack, FitContentTrack 40]
          , gridRows = [FixedTrack 20]
          }
      intrinsicMetrics =
        Map.fromList
          [ (1, metric 10 10 30 10 80 10 7)
          , (2, metric 10 10 30 10 80 10 7)
          , (3, metric 10 10 30 10 80 10 7)
          ]
      intrinsicPlan = solve (LayoutGrid intrinsicSpec items) (LayoutRect 0 0 200 20) intrinsicMetrics
  assertNear "min-content track" 10 (frame 1 intrinsicPlan).layoutWidth
  assertNear "max-content track" 80 (frame 2 intrinsicPlan).layoutWidth
  assertNear "fit-content cap" 40 (frame 3 intrinsicPlan).layoutWidth

  let spanningSpec = defaultGrid {gridColumns = [AutoTrack, AutoTrack], gridRows = [FixedTrack 20]}
      spanningItem = GridItem 0 0 2 1 Nothing Nothing (LayoutLeaf 4)
      spanningPlan = solve (LayoutGrid spanningSpec [spanningItem]) (LayoutRect 0 0 100 20) (uniformMetrics [(4, 100, 10)])
  assertRect "spanning grid item" (LayoutRect 0 0 100 20) (frame 4 spanningPlan)

testTableGrid :: IO ()
testTableGrid = do
  let columns = [FixedTrack 1, FixedTrack 50, FixedTrack 1, FixedTrack 60, FixedTrack 1, FixedTrack 40, FixedTrack 1]
      rows = [FixedTrack 1, FixedTrack 20, FixedTrack 1, FixedTrack 20, FixedTrack 1, FixedTrack 20, FixedTrack 1, FixedTrack 20, FixedTrack 1]
      contentColumns = [1, 3, 5]
      contentRows = [1, 3, 5, 7]
      cells =
        [ GridItem column row 1 1 Nothing Nothing (LayoutLeaf key)
        | (key, (row, column)) <- zip [1 ..] [(row, column) | row <- contentRows, column <- contentColumns]
        ]
      layout =
        LayoutGrid
          defaultGrid
            { gridColumns = columns
            , gridRows = rows
            , gridInlineAlignment = BoxStretch
            , gridBlockAlignment = BoxStretch
            }
          cells
      metrics = uniformMetrics [(key, 10, 10) | key <- [1 .. 12]]
      plan = solve layout (LayoutRect 0 0 154 85) metrics
  assert "table grid lays out every header/body cell" (Map.size plan.layoutFrames == 12)
  assertRect "table header first column" (LayoutRect 1 1 50 20) (frame 1 plan)
  assertRect "table header last column" (LayoutRect 113 1 40 20) (frame 3 plan)
  assertRect "table final row and column" (LayoutRect 113 64 40 20) (frame 12 plan)

testOverlay :: IO ()
testOverlay = do
  let item key inline block = OverlayItem (Anchor inline block) noInsets 0 0 (LayoutLeaf key)
      layout =
        LayoutOverlay
          defaultOverlay
          [ item 1 AnchorStart AnchorStart
          , item 2 AnchorCenter AnchorCenter
          , item 3 AnchorEnd AnchorEnd
          , item 4 AnchorStretch AnchorStretch
          ]
      metrics = uniformMetrics [(1, 10, 10), (2, 10, 10), (3, 10, 10), (4, 10, 10)]
      plan = solve layout (LayoutRect 0 0 100 80) metrics
  assertRect "overlay start" (LayoutRect 0 0 10 10) (frame 1 plan)
  assertRect "overlay center" (LayoutRect 45 35 10 10) (frame 2 plan)
  assertRect "overlay end" (LayoutRect 90 70 10 10) (frame 3 plan)
  assertRect "overlay stretch" (LayoutRect 0 0 100 80) (frame 4 plan)

  let insetItem = OverlayItem (Anchor AnchorEnd AnchorEnd) (Insets 2 4 6 8) (-1) (-2) (LayoutLeaf 1)
      insetPlan = solve (LayoutOverlay defaultOverlay [insetItem]) (LayoutRect 0 0 100 80) metrics
  assertRect "overlay logical insets and offset" (LayoutRect 85 62 10 10) (frame 1 insetPlan)

testCanvas :: IO ()
testCanvas = do
  let items =
        [ CanvasItem 10 20 Nothing Nothing 2 (LayoutLeaf 1)
        , CanvasItem 5 6 (Just 30) (Just 40) 1 (LayoutLeaf 2)
        ]
      plan = solve (LayoutCanvas defaultCanvas items) (LayoutRect 100 50 200 100) (uniformMetrics [(1, 20, 10), (2, 5, 5)])
  assertRect "canvas natural size" (LayoutRect 110 70 20 10) (frame 1 plan)
  assertRect "canvas explicit size" (LayoutRect 105 56 30 40) (frame 2 plan)
  assert "canvas z-order" (plan.layoutPaintOrder == [2, 1])

testSplit :: IO ()
testSplit = do
  let layout =
        LayoutSplit
          defaultSplit {splitDivider = 10}
          [ SplitItem 40 50 (Just 200) 1 (LayoutLeaf 1)
          , SplitItem 40 50 (Just 200) 2 (LayoutLeaf 2)
          ]
      plan = solve layout (LayoutRect 0 0 300 40) (uniformMetrics [(1, 10, 10), (2, 10, 10)])
  assertNear "split first growth" (Dp (50 + 190 / 3)) (frame 1 plan).layoutWidth
  assertNear "split second growth" (Dp (50 + 380 / 3)) (frame 2 plan).layoutWidth
  assertNear "split divider" ((frame 1 plan).layoutWidth + 10) (frame 2 plan).layoutX

testAdaptive :: IO ()
testAdaptive = do
  let layout =
        LayoutAdaptive
          [ AdaptiveCase Nothing (Just 149) (LayoutLeaf 1)
          , AdaptiveCase (Just 150) Nothing (LayoutLeaf 2)
          ]
          (LayoutLeaf 3)
      metrics = uniformMetrics [(1, 10, 10), (2, 10, 10), (3, 10, 10)]
  assert "adaptive compact branch" (Map.member 1 (solve layout (LayoutRect 0 0 100 20) metrics).layoutFrames)
  assert "adaptive wide branch" (Map.member 2 (solve layout (LayoutRect 0 0 200 20) metrics).layoutFrames)

testVisibility :: IO ()
testVisibility = do
  let collapsed = LayoutBox defaultBoxSpec {boxVisibility = Collapsed} (LayoutLeaf 1)
      invisible = LayoutBox defaultBoxSpec {boxVisibility = Invisible} (LayoutLeaf 2)
      collapsedPlan = solve collapsed (LayoutRect 0 0 100 20) (uniformMetrics [(1, 10, 10)])
      invisiblePlan = solve invisible (LayoutRect 0 0 100 20) (uniformMetrics [(2, 10, 10)])
  assert "collapsed child has no frame" (Map.notMember 1 collapsedPlan.layoutFrames)
  assert "collapsed child retains visibility identity" (Map.lookup 1 collapsedPlan.layoutVisibility == Just Collapsed)
  assert "invisible child keeps geometry" (Map.member 2 invisiblePlan.layoutFrames)
  assert "invisible child is marked" (Map.lookup 2 invisiblePlan.layoutVisibility == Just Invisible)

testStrategyVariants :: IO ()
testStrategyVariants = do
  let basicMetrics = uniformMetrics [(1, 20, 10), (2, 20, 10)]
      reversed =
        LayoutFlow
          defaultRow {flowReverse = True, flowCrossAlignment = CrossStart}
          (naturalLeaves [1, 2])
      reversePlan = solve reversed (LayoutRect 0 0 100 30) basicMetrics
  assertNear "reversed flow places the last item first" 20 (frame 1 reversePlan).layoutX
  assertNear "reversed flow places the first item at main start" 0 (frame 2 reversePlan).layoutX

  let column = LayoutFlow defaultColumn {flowGap = 4, flowCrossAlignment = CrossStart} (naturalLeaves [1, 2])
      columnPlan = solve column (LayoutRect 0 0 80 50) basicMetrics
  assertRect "block-axis first item" (LayoutRect 0 0 20 10) (frame 1 columnPlan)
  assertRect "block-axis gap" (LayoutRect 0 14 20 10) (frame 2 columnPlan)

  let override =
        LayoutFlow
          defaultRow {flowCrossAlignment = CrossStart}
          [FlowItem defaultFlowItem {itemCrossAlignment = Just CrossEnd} (LayoutLeaf 1)]
      overridePlan = solve override (LayoutRect 0 0 100 40) basicMetrics
  assertNear "per-item cross alignment overrides the flow" 30 (frame 1 overridePlan).layoutY

  let endAlignedWrap =
        LayoutWrap
          defaultWrap
            { wrapFlow = defaultRow {flowGap = 10, flowCrossAlignment = CrossStart}
            , wrapLineGap = 5
            , wrapLineAlignment = MainEnd
            }
          (naturalLeaves [1, 2, 3])
      wrapPlan = solve endAlignedWrap (LayoutRect 0 0 50 60) (uniformMetrics [(1, 20, 10), (2, 20, 10), (3, 20, 10)])
  assertNear "wrapped lines can align at block end" 35 (frame 1 wrapPlan).layoutY
  assertNear "wrapped second line follows line gap" 50 (frame 3 wrapPlan).layoutY

  let minMaxGrid =
        LayoutGrid
          defaultGrid
            { gridColumns = [MinMaxTrack (FixedTrack 20) (FractionTrack 1), FixedTrack 30]
            , gridRows = [FixedTrack 20]
            , gridInlineAlignment = BoxStretch
            }
          [ gridItem 0 0 1
          , (gridItem 1 0 2) {gridItemInlineAlignment = Just BoxEnd, gridItemBlockAlignment = Just BoxCenter}
          ]
      minMaxPlan = solve minMaxGrid (LayoutRect 0 0 100 20) basicMetrics
  assertNear "minmax fractional track grows from its minimum" 70 (frame 1 minMaxPlan).layoutWidth
  assertRect "per-cell grid alignment" (LayoutRect 80 5 20 10) (frame 2 minMaxPlan)

  let blockSplit =
        LayoutSplit
          defaultSplit {splitAxis = BlockAxis, splitDivider = 5}
          [ SplitItem 10 20 (Just 20) 0 (LayoutLeaf 1)
          , SplitItem 10 20 Nothing 1 (LayoutLeaf 2)
          ]
      blockSplitPlan = solve blockSplit (LayoutRect 0 0 60 65) basicMetrics
  assertRect "block split fixed pane" (LayoutRect 0 0 60 20) (frame 1 blockSplitPlan)
  assertRect "block split flexible pane" (LayoutRect 0 25 60 40) (frame 2 blockSplitPlan)

  let fallbackAdaptive =
        LayoutAdaptive
          [AdaptiveCase (Just 200) Nothing (LayoutLeaf 1)]
          (LayoutLeaf 2)
      fallbackPlan = solve fallbackAdaptive (LayoutRect 0 0 100 20) basicMetrics
  assert "adaptive layout uses its fallback when no range matches" (Map.member 2 fallbackPlan.layoutFrames)

  let canvas :: Layout Int
      canvas = LayoutCanvas defaultCanvas {canvasContentSize = Just (Size 320 180)} []
      canvasMeasurement =
        measureLayout
          defaultLayoutEnvironment
          (metricsMeasurer Map.empty)
          IdealContent
          (Constraints 0 Unbounded 0 Unbounded)
          canvas
      emptyMeasurement =
        measureLayout
          defaultLayoutEnvironment
          (metricsMeasurer Map.empty)
          IdealContent
          (Constraints 0 Unbounded 0 Unbounded)
          (LayoutEmpty :: Layout Int)
  assert "declared canvas content size participates in measurement" (canvasMeasurement.measuredSize == Size 320 180)
  assert "empty layout measures to zero" (emptyMeasurement.measuredSize == Size 0 0)

  let fillBox =
        LayoutFlow
          defaultRow {flowCrossAlignment = CrossStart}
          [ FlowItem
              defaultFlowItem
              ( LayoutBox
                  defaultBoxSpec
                    { boxWidth = AxisBounds Nothing (Just 100) Nothing
                    , boxHeight = AxisBounds Nothing (Just 100) Nothing
                    , boxAspectRatio = Just (2, AspectFill)
                    }
                  (LayoutLeaf 1)
              )
          ]
      fillPlan = solve fillBox (LayoutRect 0 0 250 120) basicMetrics
  assertRect "aspect-fill expands the limiting axis" (LayoutRect 0 0 200 100) (frame 1 fillPlan)

testValidation :: IO ()
testValidation = do
  let invalid :: Layout Int
      invalid =
        LayoutFlow
          defaultRow {flowGap = -1}
          [ FlowItem defaultFlowItem {itemGrow = -1} (LayoutLeaf 1)
          , FlowItem defaultFlowItem (LayoutLeaf 1)
          , FlowItem defaultFlowItem (LayoutGrid defaultGrid {gridColumns = []} [])
          ]
      diagnostics = validateLayout invalid
  assert "invalid layout reports several diagnostics" (length diagnostics >= 4)
  assert "invalid layout reports duplicate identity" (any ((== Just 1) . diagnosticKey) diagnostics)
  assert "invalid layout messages are useful" (all (not . Text.null . diagnosticMessage) diagnostics)

testControlIntegration :: IO ()
testControlIntegration = do
  let first = Label (ElementKey 1) (Rect 99 99 40 20) "First"
      second = Button (ElementKey 2) (Rect 99 99 30 20) "Second" (CommandId 1) True
      root =
        LayoutContainer
          LayoutContainerSpec
            { layoutContainerKey = ElementKey 10
            , layoutContainerFrame = Rect 0 0 200 50
            , layoutContainerPresentation = PlainLayoutContainer
            , layoutContainerEnvironment = defaultLayoutEnvironment
            , layoutContainerLayout =
                LayoutFlow
                  defaultRow {flowGap = 5, flowCrossAlignment = CrossStart}
                  (naturalLeaves [ElementKey 1, ElementKey 2])
            , layoutContainerChildren = [first, second]
            }
      (resolved, diagnostics) = resolveControlLayouts Map.empty [root]
  assert "portable control layout has no diagnostics" (null diagnostics)
  case resolved of
    [LayoutContainer spec]
      | firstChild : secondChild : _ <- spec.layoutContainerChildren -> do
          assert "layout keeps stable child keys" (fmap controlKey spec.layoutContainerChildren == [ElementKey 1, ElementKey 2])
          assertRectDouble "first control frame" (Rect 0 0 40 20) (controlFrame firstChild)
          assertRectDouble "second control frame" (Rect 45 0 30 20) (controlFrame secondChild)
    _ -> error "resolved portable layout root changed shape"

testGeometryProperties :: IO ()
testGeometryProperties = do
  let layout =
        LayoutFlow
          defaultRow {flowGap = 3, flowCrossAlignment = CrossStretch}
          [ FlowItem defaultFlowItem {itemGrow = 1, itemMinimumMain = Just 0} (LayoutLeaf 1)
          , FlowItem defaultFlowItem {itemGrow = 2, itemMinimumMain = Just 0} (LayoutLeaf 2)
          , FlowItem defaultFlowItem {itemGrow = 3, itemMinimumMain = Just 0} (LayoutLeaf 3)
          ]
      metrics = uniformMetrics [(1, 10, 10), (2, 20, 15), (3, 30, 20)]
  forM_ [0 .. 100 :: Int] $ \width ->
    forM_ [0, 1, 17, 50 :: Int] $ \height -> do
      let bounds = LayoutRect 0 0 (fromIntegral width) (fromIntegral height)
          plan = solve layout bounds metrics
      assert "fuzzed frames are finite and nonnegative" (all validRect (Map.elems plan.layoutFrames))
      assert "fuzzed solver is deterministic" (plan == solve layout bounds metrics)

testLargeTree :: IO ()
testLargeTree = do
  let count = 2500
      keys = [1 .. count]
      layout = LayoutFlow defaultRow {flowCrossAlignment = CrossStretch} (naturalLeaves keys)
      metrics = uniformMetrics [(key, 1, 1) | key <- keys]
      plan = solve layout (LayoutRect 0 0 (fromIntegral count) 10) metrics
  assert "large linear layout returns every frame" (Map.size plan.layoutFrames == count)
  assert "large linear layout preserves source paint order" (plan.layoutPaintOrder == keys)

solve :: Layout Int -> LayoutRect -> Map.Map Int IntrinsicMetrics -> LayoutPlan Int
solve = solveWith defaultLayoutEnvironment

solveWith :: LayoutEnvironment -> Layout Int -> LayoutRect -> Map.Map Int IntrinsicMetrics -> LayoutPlan Int
solveWith environment layout bounds metrics = solveLayout environment (metricsMeasurer metrics) bounds layout

naturalLeaves :: [key] -> [FlowItem key]
naturalLeaves = fmap (FlowItem defaultFlowItem . LayoutLeaf)

gridItem :: Int -> Int -> key -> GridItem key
gridItem column row key = GridItem column row 1 1 Nothing Nothing (LayoutLeaf key)

uniformMetrics :: Ord key => [(key, Dp, Dp)] -> Map.Map key IntrinsicMetrics
uniformMetrics = Map.fromList . fmap (\(key, width, height) -> (key, metric 0 0 width height width height (height * 0.75)))

metric :: Dp -> Dp -> Dp -> Dp -> Dp -> Dp -> Dp -> IntrinsicMetrics
metric minWidth minHeight idealWidth idealHeight maxWidth maxHeight baseline =
  IntrinsicMetrics
    (Size minWidth minHeight)
    (Size idealWidth idealHeight)
    (Size maxWidth maxHeight)
    (Just baseline)
    (Just baseline)

frame :: Ord key => key -> LayoutPlan key -> LayoutRect
frame key plan =
  case Map.lookup key plan.layoutFrames of
    Just value -> value
    Nothing -> error "expected layout frame is missing"

validRect :: LayoutRect -> Bool
validRect rect =
  all valid [rect.layoutX, rect.layoutY, rect.layoutWidth, rect.layoutHeight]
    && rect.layoutWidth >= 0
    && rect.layoutHeight >= 0
  where
    valid (Dp value) = not (isNaN value || isInfinite value)

assertRect :: String -> LayoutRect -> LayoutRect -> IO ()
assertRect label expected actual = do
  assertNear (label <> " x") expected.layoutX actual.layoutX
  assertNear (label <> " y") expected.layoutY actual.layoutY
  assertNear (label <> " width") expected.layoutWidth actual.layoutWidth
  assertNear (label <> " height") expected.layoutHeight actual.layoutHeight

assertRectDouble :: String -> Rect -> Rect -> IO ()
assertRectDouble label expected actual =
  assert
    label
    ( and
        [ close (rectX expected) (rectX actual)
        , close (rectY expected) (rectY actual)
        , close (rectWidth expected) (rectWidth actual)
        , close (rectHeight expected) (rectHeight actual)
        ]
    )

assertNear :: String -> Dp -> Dp -> IO ()
assertNear label (Dp expected) (Dp actual) =
  assert (label <> ": expected " <> show expected <> ", got " <> show actual) (close expected actual)

close :: Double -> Double -> Bool
close left right = abs (left - right) <= 0.0001

assert :: String -> Bool -> IO ()
assert label condition =
  if condition then pure () else error (label <> " failed")
