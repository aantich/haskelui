module Main (main) where

import Example.DrawingPrimitives (application)
import HaskeLUI.Backend.AppKit (appKitBackend)
import HaskeLUI.Runtime (runApp)

main :: IO ()
main = runApp appKitBackend application
