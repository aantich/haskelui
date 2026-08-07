{-# LANGUAGE OverloadedRecordDot #-}

module Main (main) where

import Example.DrawingPrimitives
  ( GalleryModel (..)
  , application
  , galleryDrawing
  , galleryHitTest
  , gallerySurfaceKey
  , initialGalleryModel
  )
import HaskeLUI.Backend.Headless
import HaskeLUI.Core
import HaskeLUI.Runtime (runApp)

main :: IO ()
main = do
  if null (validateDrawing galleryDrawing)
    then pure ()
    else error "drawing-primitives: gallery contains an invalid command"
  (backend, latestView) <- newHeadlessBackend
  runApp backend application
  rendered <- latestView
  case rendered of
    Just view ->
      case captureDrawingSurfaces view of
        [captured]
          | captured.capturedDrawingSurfaceKey == gallerySurfaceKey
          , captured.capturedDrawingSurfaceRevision == DrawingRevision 1
          , length captured.capturedDrawingCommands >= 60 ->
              putStrLn "drawing-primitives: all portable primitives compiled into the headless display list"
        _ -> error "drawing-primitives: unexpected captured drawing surface"
    Nothing -> error "drawing-primitives: headless backend did not render"
  let cardPoint = Point 150 466
      cardTarget = hitTestDrawing cardPoint (galleryHitTest initialGalleryModel)
  case cardTarget of
    Just target | target.drawingHitResultCursor == OpenHandCursor -> pure ()
    _ -> error "drawing-primitives: transformed card was not hit in surface coordinates"
  let pressed = noDrawingPointerButtons {primaryPointerButtonPressed = True}
      down = pointerEvent DrawingPointerDown cardPoint (Point 0 0) pressed cardTarget
      afterDown = applyTransaction (appHandleEvent application (DrawingInputReceived gallerySurfaceKey (DrawingPointerInput down)) initialGalleryModel) initialGalleryModel
      movedPoint = Point 190 490
      moved = pointerEvent DrawingPointerMoved movedPoint (Point 40 24) pressed cardTarget
      afterMove = applyTransaction (appHandleEvent application (DrawingInputReceived gallerySurfaceKey (DrawingPointerInput moved)) afterDown) afterDown
  if afterMove.galleryDragOffset == Point 40 24 && afterMove.galleryRevision > initialGalleryModel.galleryRevision
    then putStrLn "drawing-primitives: click, hover, drag, capture targets, and scroll model updates validated"
    else error ("drawing-primitives: interactive drag did not update the model: " <> show afterMove)

pointerEvent
  :: DrawingPointerPhase
  -> Point
  -> Point
  -> DrawingPointerButtons
  -> Maybe DrawingHitResult
  -> DrawingPointerEvent
pointerEvent phase position delta buttons target =
  DrawingPointerEvent
    { drawingPointerId = DrawingPointerId 1
    , drawingPointerPhase = phase
    , drawingPointerPosition = position
    , drawingPointerDelta = delta
    , drawingPointerChangedButton = Nothing
    , drawingPointerButtons = buttons
    , drawingPointerModifiers = noDrawingModifiers
    , drawingPointerClickCount = 1
    , drawingPointerTarget = target
    }
