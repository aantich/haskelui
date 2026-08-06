{-# LANGUAGE OverloadedRecordDot #-}

module Main (main) where

import VisualHaskell (applicationWithEnvironment)
import VisualHaskell.Paths
  ( ensureVisualHaskellPaths
  , resolveVisualHaskellPaths
  , visualHaskellHome
  , visualHaskellLastWorkspacePath
  )
import VisualHaskell.TextMate (defaultTextMateConfiguration)
import HaskeLUI.Backend.AppKit
  ( AppKitCapabilities (..)
  , appKitBackend
  , queryAppKitCapabilities
  )
import HaskeLUI.Runtime (runApp)

main :: IO ()
main = do
  capabilities <- queryAppKitCapabilities
  paths <- resolveVisualHaskellPaths
  ensureVisualHaskellPaths paths
  textMateConfiguration <- defaultTextMateConfiguration paths.visualHaskellHome
  putStrLn ("Starting Visual Haskell on " <> show capabilities.appKitVersion)
  runApp
    appKitBackend
    ( applicationWithEnvironment
        paths.visualHaskellLastWorkspacePath
        textMateConfiguration
    )
