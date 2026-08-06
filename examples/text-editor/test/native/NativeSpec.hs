{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Control.Exception (bracket)
import Control.Monad (unless)
import qualified Data.Text as Text
import Example.TextEditor
  ( applicationWithDocuments
  , firstDocumentEditorKey
  , firstDocumentTabKey
  , firstDocumentWindowKey
  , openFolderCommand
  , saveCommand
  )
import System.Directory
  ( getTemporaryDirectory
  , removeFile
  )
import System.IO
  ( hClose
  , hPutStr
  , openTempFile
  )
import UIH.Backend.AppKit.Testing
  ( AppKitDebugCounters (..)
  , AppKitTextEditorTestSpec (..)
  , appKitBackendWithTextEditorTest
  , appKitResourcesReleased
  , queryAppKitDebugCounters
  , queryAppKitLastTestFailure
  )
import UIH.Core
  ( App (..)
  , AppView (..)
  )
import UIH.Runtime (runApp)

expectedContents :: String
expectedContents = "module Saved where\nanswer = 42\n"

main :: IO ()
main =
  bracket createFixture removeFile $ \path -> do
    let testSpec =
          AppKitTextEditorTestSpec
            { testDocumentWindow = firstDocumentWindowKey
            , testTextEditor = firstDocumentEditorKey
            , testDocumentTab = firstDocumentTabKey
            , testEditorSaveCommand = saveCommand
            , testEditorOpenFolderCommand = openFolderCommand
            }
        testApplication =
          applicationWithDocuments
            [ (path, Text.pack "😀 module Initial where\n")
            , (path <> "-README.md", "# Fixture\n")
            , (path <> "-stack.yaml", "resolver: lts-24.50\n")
            ]
    unless (length (testApplication.appView testApplication.appInitialModel).appWindows == 1) $
      error "native text editor fixture must begin with exactly one workspace window"
    runApp (appKitBackendWithTextEditorTest testSpec) testApplication
    actualContents <- readFile path
    counters <- queryAppKitDebugCounters
    lastFailure <- queryAppKitLastTestFailure
    unless (counters.debugTestFailures == 0) $
      error ("native text editor validation failed: " <> show lastFailure)
    unless (actualContents == expectedContents) $
      error ("native Save wrote unexpected contents: " <> show actualContents)
    unless (appKitResourcesReleased counters) $
      error ("native text editor resources survived shutdown: " <> show counters)
    putStrLn ("AppKit text editor edit/save/resource validation passed: " <> show counters)

createFixture :: IO FilePath
createFixture = do
  temporaryDirectory <- getTemporaryDirectory
  (path, handle) <- openTempFile temporaryDirectory "uih-text-editor.hs"
  hPutStr handle "😀 module Initial where\n"
  hClose handle
  pure path
