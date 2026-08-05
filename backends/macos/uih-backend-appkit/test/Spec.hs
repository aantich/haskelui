{-# LANGUAGE OverloadedRecordDot #-}

module Main (main) where

import UIH.Backend.AppKit

main :: IO ()
main = do
  capabilities <- queryAppKitCapabilities
  if capabilities.appKitVersion.macOSMajor > 0
    then putStrLn ("uih-backend-appkit: detected " <> show capabilities.appKitVersion)
    else error "uih-backend-appkit: invalid macOS version"
