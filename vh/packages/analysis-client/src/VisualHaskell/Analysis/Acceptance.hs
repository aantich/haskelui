{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedRecordDot #-}

module VisualHaskell.Analysis.Acceptance
  ( AnalysisExpectation (..)
  , AnalysisMismatch (..)
  , acceptAnalysisSnapshot
  ) where

import VisualHaskell.Analysis.Client (WorkerGeneration)
import VisualHaskell.Semantic

data AnalysisExpectation = AnalysisExpectation
  { expectedWorkerGeneration :: !WorkerGeneration
  , expectedWorkspaceGeneration :: !WorkspaceGeneration
  , expectedSession :: !SessionId
  , expectedDocument :: !DocumentId
  , expectedRevision :: !TextRevision
  , expectedContentHash :: !ContentHash
  }
  deriving stock (Eq, Show)

data AnalysisMismatch
  = WorkerGenerationMismatch !WorkerGeneration !WorkerGeneration
  | WorkspaceGenerationMismatch !WorkspaceGeneration !WorkspaceGeneration
  | SessionMismatch !SessionId !SessionId
  | DocumentMismatch !DocumentId !DocumentId
  | RevisionMismatch !TextRevision !TextRevision
  | ContentHashMismatch !ContentHash !ContentHash
  deriving stock (Eq, Show)

acceptAnalysisSnapshot
  :: AnalysisExpectation
  -> WorkerGeneration
  -> AnalysisSnapshot range
  -> Either [AnalysisMismatch] (AnalysisSnapshot range)
acceptAnalysisSnapshot expectation actualWorkerGeneration snapshot =
  case mismatches of
    [] -> Right snapshot
    _ -> Left mismatches
  where
    mismatches =
      concat
        [ mismatch
            (expectation.expectedWorkerGeneration == actualWorkerGeneration)
            (WorkerGenerationMismatch expectation.expectedWorkerGeneration actualWorkerGeneration)
        , mismatch
            (expectation.expectedWorkspaceGeneration == snapshot.analysisWorkspaceGeneration)
            (WorkspaceGenerationMismatch expectation.expectedWorkspaceGeneration snapshot.analysisWorkspaceGeneration)
        , mismatch
            (expectation.expectedSession == snapshot.analysisSession)
            (SessionMismatch expectation.expectedSession snapshot.analysisSession)
        , mismatch
            (expectation.expectedDocument == snapshot.analysisDocument)
            (DocumentMismatch expectation.expectedDocument snapshot.analysisDocument)
        , mismatch
            (expectation.expectedRevision == snapshot.analysisRevision)
            (RevisionMismatch expectation.expectedRevision snapshot.analysisRevision)
        , mismatch
            (expectation.expectedContentHash == snapshot.analysisContentHash)
            (ContentHashMismatch expectation.expectedContentHash snapshot.analysisContentHash)
        ]

mismatch :: Bool -> AnalysisMismatch -> [AnalysisMismatch]
mismatch matches value = if matches then [] else [value]
