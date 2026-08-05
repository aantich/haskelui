{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE OverloadedRecordDot #-}

module Main (main) where

import UIH.Backend.Headless (newHeadlessBackend)
import UIH.Core
import UIH.Runtime (runApp)

main :: IO ()
main = do
  (backend, latestView) <- newHeadlessBackend
  runApp backend application
  rendered <- latestView
  case rendered of
    Just (AppView [window] [])
      | window.windowKey == WindowKey 1 ->
          putStrLn "uih-backend-headless: render smoke test passed"
    _ -> error "uih-backend-headless: unexpected rendered view"
  where
    application =
      App
        { appInitialModel = ()
        , appView = const (AppView [WindowSpec (WindowKey 1) "Headless" (Rect 0 0 100 100) []] [])
        , appHandleEvent = \_ _ -> noTransaction
        }
