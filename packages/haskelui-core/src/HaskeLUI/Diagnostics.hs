{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedRecordDot #-}

-- | Structured, sink-agnostic diagnostics shared by the pure surface API,
-- runtime, backends, and product services. A producer reports stable operation
-- names and metadata; the application decides whether and where to persist it.
module HaskeLUI.Diagnostics
  ( TraceEvent (..)
  , TraceSeverity (..)
  , TraceSink
  , noTrace
  , trace
  ) where

import Data.Text (Text)

data TraceSeverity
  = TraceDebug
  | TraceInfo
  | TraceWarning
  | TraceError
  deriving stock (Eq, Ord, Show)

data TraceEvent = TraceEvent
  { traceSeverity :: !TraceSeverity
  , traceSubsystem :: !Text
  , traceOperation :: !Text
  , traceFields :: ![(Text, Text)]
  }
  deriving stock (Eq, Show)

type TraceSink = TraceEvent -> IO ()

noTrace :: TraceSink
noTrace _ = pure ()

trace :: TraceSink -> TraceSeverity -> Text -> Text -> [(Text, Text)] -> IO ()
trace sink severity subsystem operation fields =
  sink
    TraceEvent
      { traceSeverity = severity
      , traceSubsystem = subsystem
      , traceOperation = operation
      , traceFields = fields
      }
