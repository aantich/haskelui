{-# LANGUAGE OverloadedRecordDot #-}

module Main (main) where

import Control.Monad (unless)
import Example.ControlGallery (application, galleryWindowKey, rootTabKey)
import HaskeLUI.Backend.AppKit.Testing
  ( AppKitControlGalleryTestSpec (..)
  , AppKitDebugCounters (..)
  , appKitBackendWithControlGalleryTest
  , appKitResourcesReleased
  , queryAppKitDebugCounters
  , queryAppKitLastTestFailure
  )
import HaskeLUI.Core (ElementKey (..))
import HaskeLUI.Runtime (runApp)

main :: IO ()
main = do
  let spec =
        AppKitControlGalleryTestSpec
          { testGalleryWindow = galleryWindowKey
          , testGalleryRootTab = rootTabKey
          , testGalleryTextInput = ElementKey 203
          , testGalleryTextMirror = ElementKey 201
          , testGalleryToggle = ElementKey 108
          , testGalleryChoice = ElementKey 112
          , testGalleryNumeric = ElementKey 212
          , testGalleryCollection = ElementKey 301
          , testGalleryDialogButton = ElementKey 403
          , testGalleryDialog = ElementKey 412
          , testGalleryPopoverButton = ElementKey 405
          , testGalleryPopover = ElementKey 414
          , testGalleryContainer = ElementKey 500
          , testGalleryNestedChild = ElementKey 502
          }
  runApp (appKitBackendWithControlGalleryTest spec) application
  counters <- queryAppKitDebugCounters
  failure <- queryAppKitLastTestFailure
  unless (counters.debugTestFailures == 0) $
    error ("native control-gallery validation failed: " <> show failure)
  unless (appKitResourcesReleased counters) $
    error ("native control-gallery resources survived shutdown: " <> show counters)
  putStrLn
    ("AppKit created every Core control, reconciled representative typed events, and released all resources: "
      <> show counters)
