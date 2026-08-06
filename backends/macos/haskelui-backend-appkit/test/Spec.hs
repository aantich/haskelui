{-# LANGUAGE OverloadedRecordDot #-}

module Main (main) where

import HaskeLUI.Backend.AppKit

main :: IO ()
main = do
  capabilities <- queryAppKitCapabilities
  if capabilities.appKitVersion.macOSMajor > 0
    then putStrLn ("haskelui-backend-appkit: detected " <> show capabilities.appKitVersion)
    else error "haskelui-backend-appkit: invalid macOS version"
