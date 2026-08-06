{-# LANGUAGE OverloadedRecordDot #-}

module Main (main) where

import Example.ControlGallery (application, collectionApplication, layoutApplication)
import System.Environment (getArgs)
import HaskeLUI.Backend.AppKit
  ( AppKitCapabilities (..)
  , appKitBackend
  , queryAppKitCapabilities
  )
import HaskeLUI.Runtime (runApp)

main :: IO ()
main = do
  arguments <- getArgs
  capabilities <- queryAppKitCapabilities
  putStrLn ("Starting HaskeLUI control gallery on " <> show capabilities.appKitVersion)
  runApp appKitBackend $
    if "--layout" `elem` arguments
      then layoutApplication
      else
        if "--collections" `elem` arguments
          then collectionApplication
          else application
