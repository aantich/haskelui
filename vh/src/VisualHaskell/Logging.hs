{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

module VisualHaskell.Logging
  ( DebugLogger (..)
  , withDebugLogger
  ) where

import Control.Concurrent.MVar (newMVar, withMVar)
import Control.Exception (SomeException, displayException, finally, try)
import Control.Monad (void)
import Data.Aeson (encode, object, (.=))
import qualified Data.ByteString.Lazy as LazyByteString
import Data.IORef (newIORef, readIORef, writeIORef)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Time.Clock (diffUTCTime, getCurrentTime)
import Data.Time.Format (defaultTimeLocale, formatTime)
import System.Directory (createDirectoryIfMissing)
import System.FilePath (takeDirectory, (</>))
import System.IO
  ( BufferMode (LineBuffering)
  , IOMode (AppendMode)
  , hPutStrLn
  , hFlush
  , hSetBuffering
  , stderr
  , withBinaryFile
  )
import HaskeLUI.Diagnostics

data DebugLogger = DebugLogger
  { debugLogPath :: !FilePath
  , debugTraceSink :: !TraceSink
  }

-- | Open one append-only JSONL session log. Writes are serialized because
-- services, tasks, worker supervision, and the UI thread may report at once.
withDebugLogger
  :: FilePath
  -> Maybe FilePath
  -> (DebugLogger -> IO value)
  -> IO value
withDebugLogger logDirectory requestedPath action = do
  started <- getCurrentTime
  let session = Text.pack (formatTime defaultTimeLocale "%Y%m%dT%H%M%S%QZ" started)
      generatedName = "vh-debug-" <> Text.unpack session <> ".jsonl"
      path = maybe (logDirectory </> generatedName) id requestedPath
  createDirectoryIfMissing True (takeDirectory path)
  withBinaryFile path AppendMode $ \handle -> do
    hSetBuffering handle LineBuffering
    lock <- newMVar ()
    sequenceReference <- newIORef (0 :: Integer)
    let sink :: TraceSink
        sink event = withMVar lock $ \_ -> do
          timestamp <- getCurrentTime
          sequenceNumber <- readIORef sequenceReference
          let next = sequenceNumber + 1
              severity = severityText event.traceSeverity
              timestampText =
                Text.pack
                  (formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%S%QZ" timestamp)
              elapsedMilliseconds =
                round (diffUTCTime timestamp started * 1000) :: Integer
          writeIORef sequenceReference next
          let human =
                "[" <> timestampText
                  <> " +" <> Text.pack (show elapsedMilliseconds) <> "ms"
                  <> " #" <> Text.pack (show next) <> "] "
                  <> "[vh " <> severity <> "] "
                  <> event.traceSubsystem <> "." <> event.traceOperation
                  <> foldMap (\(name, value) -> " " <> name <> "=" <> value) event.traceFields
              encoded =
                encode $
                  object
                    [ "timestamp" .= timestampText
                    , "elapsedMilliseconds" .= elapsedMilliseconds
                    , "session" .= session
                    , "sequence" .= next
                    , "severity" .= severity
                    , "subsystem" .= event.traceSubsystem
                    , "operation" .= event.traceOperation
                    , "fields" .= Map.fromList event.traceFields
                    ]
          void (try (hPutStrLn stderr (Text.unpack human)) :: IO (Either SomeException ()))
          persisted <-
            try
              ( LazyByteString.hPutStr handle encoded
                  >> LazyByteString.hPutStr handle "\n"
                  >> hFlush handle
              )
              :: IO (Either SomeException ())
          case persisted of
            Right () -> pure ()
            Left exception ->
              void
                ( try
                    (hPutStrLn stderr ("Visual Haskell debug-log write failed: " <> displayException exception))
                    :: IO (Either SomeException ())
                )
        logger = DebugLogger path sink
    trace sink TraceInfo "visual-haskell" "debug-session.start"
      [("path", Text.pack path)]
    action logger
      `finally` trace sink TraceInfo "visual-haskell" "debug-session.stop" []

severityText :: TraceSeverity -> Text
severityText severity =
  case severity of
    TraceDebug -> "debug"
    TraceInfo -> "info"
    TraceWarning -> "warning"
    TraceError -> "error"
