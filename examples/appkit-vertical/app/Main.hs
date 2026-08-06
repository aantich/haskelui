{-# LANGUAGE OverloadedRecordDot #-}

module Main (main) where

import Example.AppKitVertical (application)
import HaskeLUI.Backend.AppKit
  ( AppKitCapabilities (..)
  , appKitBackend
  , queryAppKitCapabilities
  )
import HaskeLUI.Runtime (runApp)

main :: IO ()
main = do
  capabilities <- queryAppKitCapabilities
  putStrLn ("Starting HaskeLUI AppKit vertical slice on " <> show capabilities.appKitVersion)
  runApp appKitBackend application
