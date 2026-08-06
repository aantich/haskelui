{-# LANGUAGE OverloadedRecordDot #-}

module Main (main) where

import Control.Monad (unless)
import Example.AppKitVertical
  ( application
  , greetingLabelKey
  , mainWindowKey
  , nameFieldKey
  , saveCommand
  )
import HaskeLUI.Backend.AppKit.Testing
  ( AppKitDebugCounters (..)
  , AppKitVerticalTestSpec (..)
  , appKitBackendWithVerticalTest
  , appKitResourcesReleased
  , queryAppKitDebugCounters
  , queryAppKitLastTestFailure
  )
import HaskeLUI.Runtime (runApp)

main :: IO ()
main = do
  let testSpec =
        AppKitVerticalTestSpec
          { testMainWindow = mainWindowKey
          , testNameField = nameFieldKey
          , testGreetingLabel = greetingLabelKey
          , testSaveCommand = saveCommand
          }
  runApp (appKitBackendWithVerticalTest testSpec) application
  counters <- queryAppKitDebugCounters
  lastFailure <- queryAppKitLastTestFailure
  unless (counters.debugTestFailures == 0) $
    error ("native AppKit interaction validation failed: " <> show lastFailure)
  unless (appKitResourcesReleased counters) $
    error ("native AppKit resources survived backend shutdown: " <> show counters)
  putStrLn ("AppKit native interaction and resource validation passed: " <> show counters)
