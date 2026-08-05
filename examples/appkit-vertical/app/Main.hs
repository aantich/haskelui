{-# LANGUAGE OverloadedRecordDot #-}

module Main (main) where

import Example.AppKitVertical (application)
import UIH.Backend.AppKit
  ( AppKitCapabilities (..)
  , appKitBackend
  , queryAppKitCapabilities
  )
import UIH.Runtime (runApp)

main :: IO ()
main = do
  capabilities <- queryAppKitCapabilities
  putStrLn ("Starting UIH AppKit vertical slice on " <> show capabilities.appKitVersion)
  runApp appKitBackend application
