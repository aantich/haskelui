{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Control.Exception (bracket)
import Data.List (isInfixOf)
import System.Directory
  ( createDirectory
  , getTemporaryDirectory
  , removeFile
  , removePathForcibly
  )
import System.FilePath ((</>))
import System.IO (hClose, openTempFile)
import VisualHaskell.Logging (DebugLogger (..), withDebugLogger)
import HaskeLUI.Core (TraceSeverity (TraceWarning), trace)

main :: IO ()
main =
  bracket createFixture removePathForcibly $ \fixture -> do
    let logPath = fixture </> "explicit-debug.jsonl"
    withDebugLogger (fixture </> "generated") (Just logPath) $ \logger ->
      trace logger.debugTraceSink TraceWarning "fixture" "operation"
        [("document", "doc-1"), ("characters", "42")]
    contents <- readFile logPath
    assert "debug log contains session start" ("debug-session.start" `isInfixOf` contents)
    assert "debug log contains UTC timestamps" ("\"timestamp\":" `isInfixOf` contents)
    assert "debug log contains session-relative timing" ("\"elapsedMilliseconds\":" `isInfixOf` contents)
    assert "debug log contains monotonic sequence numbers" ("\"sequence\":" `isInfixOf` contents)
    assert "debug log contains structured subsystem" ("\"subsystem\":\"fixture\"" `isInfixOf` contents)
    assert "debug log contains structured operation" ("\"operation\":\"operation\"" `isInfixOf` contents)
    assert "debug log contains safe metadata" ("\"characters\":\"42\"" `isInfixOf` contents)
    assert "debug log contains session stop" ("debug-session.stop" `isInfixOf` contents)
    putStrLn "Visual Haskell structured debug logging test passed"

createFixture :: IO FilePath
createFixture = do
  temporary <- getTemporaryDirectory
  (path, handle) <- openTempFile temporary "visual-haskell-logging-"
  hClose handle
  removeFile path
  createDirectory path
  pure path

assert :: String -> Bool -> IO ()
assert label condition =
  if condition then pure () else error (label <> " failed")
