{-# LANGUAGE OverloadedRecordDot #-}

module Main (main) where

import VisualHaskell (applicationWithWorkspaceRegistry)
import System.Directory
  ( XdgDirectory (XdgState)
  , createDirectoryIfMissing
  , getXdgDirectory
  )
import System.FilePath ((</>))
import HaskeLUI.Backend.AppKit
  ( AppKitCapabilities (..)
  , appKitBackend
  , queryAppKitCapabilities
  )
import HaskeLUI.Runtime (runApp)

main :: IO ()
main = do
  capabilities <- queryAppKitCapabilities
  stateDirectory <- getXdgDirectory XdgState "visual-haskell"
  createDirectoryIfMissing True stateDirectory
  let registryPath = stateDirectory </> "last-workspace"
  putStrLn ("Starting Visual Haskell on " <> show capabilities.appKitVersion)
  runApp appKitBackend (applicationWithWorkspaceRegistry registryPath)
