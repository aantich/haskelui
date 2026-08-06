{-# LANGUAGE OverloadedRecordDot #-}

module Main (main) where

import Example.DrawingPrimitives (application, galleryDrawing, gallerySurfaceKey)
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
