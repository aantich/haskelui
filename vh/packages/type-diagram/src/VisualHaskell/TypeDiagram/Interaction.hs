{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedRecordDot #-}

module VisualHaskell.TypeDiagram.Interaction
  ( TypeDiagramUpdate (..)
  , handleTypeDiagramInput
  , resetTypeDiagramSelection
  ) where

import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import HaskeLUI.Core
import VisualHaskell.TypeDiagram.Layout
import VisualHaskell.TypeDiagram.Render
import VisualHaskell.TypeDiagram.Scene

data TypeDiagramUpdate = TypeDiagramUpdate
  { updatedTypeDiagramState :: !TypeDiagramState
  , activatedDiagramPart :: !(Maybe DiagramPart)
  }
  deriving stock (Eq, Show)

handleTypeDiagramInput
  :: DiagramMetrics
  -> TypeDiagramPresentation
  -> DrawingInput
  -> TypeDiagramState
  -> TypeDiagramUpdate
handleTypeDiagramInput metrics presentation input state =
  case input of
    DrawingPointerInput event -> handlePointer event
    DrawingScrollInput event ->
      TypeDiagramUpdate (changedIfDifferent state (handleScroll event state)) Nothing
  where
    partForTarget :: Maybe DrawingHitResult -> Maybe DiagramPart
    partForTarget = (>>= diagramPartForHit presentation)
    handlePointer :: DrawingPointerEvent -> TypeDiagramUpdate
    handlePointer event =
      let target = partForTarget event.drawingPointerTarget
          activation
            | event.drawingPointerPhase == DrawingPointerDown
            , event.drawingPointerClickCount >= 2 = target
            | otherwise = Nothing
       in case event.drawingPointerPhase of
            DrawingPointerDown ->
              TypeDiagramUpdate
                ( changed
                    ( if activation == Nothing
                        then pointerDown target state
                        else (pointerDown target state) {typeDiagramDrag = Nothing}
                    )
                )
                activation
            DrawingPointerMoved ->
              TypeDiagramUpdate
                (changedIfDifferent state (pointerMoved target event state))
                Nothing
            DrawingPointerUp ->
              TypeDiagramUpdate
                (changedIfDifferent state (state {typeDiagramDrag = Nothing, typeDiagramHovered = target}))
                Nothing
            DrawingPointerCancelled ->
              TypeDiagramUpdate
                (changedIfDifferent state (state {typeDiagramDrag = Nothing}))
                Nothing
            DrawingPointerEntered ->
              TypeDiagramUpdate
                (changedIfDifferent state (state {typeDiagramHovered = target}))
                Nothing
            DrawingPointerExited ->
              TypeDiagramUpdate
                (changedIfDifferent state (state {typeDiagramHovered = Nothing}))
                Nothing
    pointerDown :: Maybe DiagramPart -> TypeDiagramState -> TypeDiagramState
    pointerDown target current =
      case target of
        Just (DisclosurePart entityId) ->
          current
            { typeDiagramCollapsedNodes = toggle entityId current.typeDiagramCollapsedNodes
            , typeDiagramSelected = Just (DisclosurePart entityId)
            , typeDiagramDrag = Nothing
            }
        Just part@(AnchorPart (NodeAnchor nodeId)) ->
          current
            { typeDiagramSelected = Just part
            , typeDiagramHovered = Just part
            , typeDiagramDrag = Just (DraggingNode nodeId)
            }
        Just part@(FunctionEndpointPart nodeId _) ->
          current
            { typeDiagramSelected = Just part
            , typeDiagramHovered = Just part
            , typeDiagramDrag = Just (DraggingNode nodeId)
            }
        Just part@(FunctionOverflowPart nodeId) ->
          current
            { typeDiagramSelected = Just part
            , typeDiagramHovered = Just part
            , typeDiagramDrag = Just (DraggingNode nodeId)
            }
        Just part ->
          current
            { typeDiagramSelected = Just part
            , typeDiagramHovered = Just part
            , typeDiagramDrag = Nothing
            }
        Nothing ->
          current
            { typeDiagramSelected = Nothing
            , typeDiagramHovered = Nothing
            , typeDiagramDrag = Just PanningDiagram
            }
    pointerMoved :: Maybe DiagramPart -> DrawingPointerEvent -> TypeDiagramState -> TypeDiagramState
    pointerMoved target event current =
      case current.typeDiagramDrag of
        Just PanningDiagram ->
          current
            { typeDiagramViewport =
                moveViewport event.drawingPointerDelta current.typeDiagramViewport
            , typeDiagramHovered = target
            }
        Just (DraggingNode nodeId) ->
          current
            { typeDiagramPinnedNodes =
                Map.insert
                  nodeId
                  (moveNode nodeId event.drawingPointerDelta current)
                  current.typeDiagramPinnedNodes
            , typeDiagramHovered = target
            }
        Nothing -> current {typeDiagramHovered = target}
    moveNode :: DiagramNodeId -> Point -> TypeDiagramState -> Point
    moveNode nodeId delta current =
      let scale = current.typeDiagramViewport.diagramViewportScale
          Point dx dy = delta
          origin =
            Map.findWithDefault
              (autoPosition nodeId)
              nodeId
              current.typeDiagramPinnedNodes
       in Point (origin.pointX + dx / scale) (origin.pointY + dy / scale)
    autoPosition :: DiagramNodeId -> Point
    autoPosition nodeId =
      case Map.lookup nodeId presentation.diagramPresentationLayout.laidOutNodes of
        Nothing -> Point 0 0
        Just nodeLayout ->
          Point nodeLayout.laidOutNodeRect.rectX nodeLayout.laidOutNodeRect.rectY
    handleScroll :: DrawingScrollEvent -> TypeDiagramState -> TypeDiagramState
    handleScroll event current
      | event.drawingScrollModifiers.drawingControlPressed
          || event.drawingScrollModifiers.drawingMetaPressed =
          zoomAt event.drawingScrollPosition event.drawingScrollDelta.pointY current
      | otherwise =
          current
            { typeDiagramViewport =
                moveViewport event.drawingScrollDelta current.typeDiagramViewport
            }
    zoomAt :: Point -> Double -> TypeDiagramState -> TypeDiagramState
    zoomAt point delta current =
      let viewport = current.typeDiagramViewport
          oldScale = viewport.diagramViewportScale
          factor = exp (-delta * 0.008)
          newScale = clamp metrics.diagramMinimumScale metrics.diagramMaximumScale (oldScale * factor)
          Point offsetX offsetY = viewport.diagramViewportOffset
          ratio = newScale / oldScale
          newOffset =
            Point
              (point.pointX - (point.pointX - offsetX) * ratio)
              (point.pointY - (point.pointY - offsetY) * ratio)
       in current
            { typeDiagramViewport = DiagramViewport newOffset newScale
            }
    changed next = nextDiagramRevision next

resetTypeDiagramSelection :: TypeDiagramState -> TypeDiagramState
resetTypeDiagramSelection state =
  nextDiagramRevision
    state
      { typeDiagramSelected = Nothing
      , typeDiagramHovered = Nothing
      , typeDiagramDrag = Nothing
      }

changedIfDifferent :: TypeDiagramState -> TypeDiagramState -> TypeDiagramState
changedIfDifferent previous next
  | previous == next = previous
  | otherwise = nextDiagramRevision next

moveViewport :: Point -> DiagramViewport -> DiagramViewport
moveViewport delta viewport =
  let Point x y = viewport.diagramViewportOffset
      Point dx dy = delta
   in viewport {diagramViewportOffset = Point (x + dx) (y + dy)}

toggle :: Ord value => value -> Set.Set value -> Set.Set value
toggle value values
  | Set.member value values = Set.delete value values
  | otherwise = Set.insert value values

clamp :: Ord value => value -> value -> value -> value
clamp lower upper = max lower . min upper
