{-# LANGUAGE OverloadedRecordDot #-}

module Main (main) where

import Control.Monad (unless)
import Example.DrawingPrimitives
  ( application
  , gallerySurfaceKey
  , galleryWindowKey
  )
import HaskeLUI.Backend.AppKit.Testing
import HaskeLUI.Runtime (runApp)

main :: IO ()
main = do
  runApp
    ( appKitBackendWithDrawingTest
        AppKitDrawingTestSpec
          { testDrawingWindow = galleryWindowKey
          , testDrawingSurface = gallerySurfaceKey
          }
    )
    application
  counters <- queryAppKitDebugCounters
  failure <- queryAppKitLastTestFailure
  unless (counters.debugTestFailures == 0) $
    error ("drawing-primitives: native validation failed: " <> show failure)
  unless (appKitResourcesReleased counters) $
    error ("drawing-primitives: native resources survived shutdown: " <> show counters)
  putStrLn "drawing-primitives: AppKit retained display list, native paint pass, and pointer bridge validated"
