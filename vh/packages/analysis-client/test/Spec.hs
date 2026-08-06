{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Control.Concurrent.STM
  ( TQueue
  , atomically
  , newTQueueIO
  , readTQueue
  , writeTQueue
  )
import Control.Exception (finally)
import Control.Monad (unless)
import Data.IORef (modifyIORef', newIORef, readIORef)
import System.Directory
  ( doesFileExist
  , findExecutable
  , getTemporaryDirectory
  , removeFile
  )
import System.IO (hClose, openTempFile)
import System.Timeout (timeout)
import VisualHaskell.Analysis.Client
import VisualHaskell.Analysis.Acceptance
import VisualHaskell.Analysis.Protocol
import VisualHaskell.Semantic

main :: IO ()
main = do
  executable <-
    findExecutable "visual-haskell-analysis-fake-worker"
      >>= maybe (fail "fake analysis worker was not on the test PATH") pure
  temporaryDirectory <- getTemporaryDirectory
  (crashMarker, crashMarkerHandle) <- openTempFile temporaryDirectory "visual-haskell-worker-crash"
  hClose crashMarkerHandle
  removeFile crashMarker
  events <- newTQueueIO
  eventLog <- newIORef []
  let workspace = WorkspaceId "fixture-workspace"
      generation = WorkspaceGeneration 4
      document = DocumentId "Main.hs"
      source = "main = putStrLn \"hello\""
      snapshot = DocumentSnapshot document "/fixture/Main.hs" (TextRevision 3) (contentHash source) source LF
      updatedSource = "main = ERROR"
      updatedSnapshot = DocumentSnapshot document "/fixture/Main.hs" (TextRevision 4) (contentHash updatedSource) updatedSource LF
      hello =
        protocolEnvelope generation $
          ClientHelloMessage
            ( ClientHello
                "visual-haskell-test/0.1"
                (Just "/fixture")
                TrustedWorkspace
                [WorkspaceLoadingCapability, FullDocumentSnapshotsCapability, DiagnosticsCapability]
            )
      record event = do
        modifyIORef' eventLog (<> [event])
        atomically (writeTQueue events event)
  let launch = (defaultWorkerLaunch executable) {workerArguments = ["--crash-once", crashMarker]}
  client <- startAnalysisClient launch hello record
  (do
      firstGeneration <- awaitReady events
      assertEqual "first worker generation" (WorkerGeneration 1) firstGeneration
      sendAnalysisMessage client (workspaceEnvelope generation workspace (OpenWorkspace (WorkspaceRequest workspace "/fixture" TrustedWorkspace)))
      sendAnalysisMessage client (documentEnvelope generation workspace snapshot (OpenDocument snapshot))
      sendAnalysisMessage client (documentEnvelope generation workspace updatedSnapshot (UpdateDocumentSnapshot updatedSnapshot))
      sendAnalysisMessage client (documentEnvelope generation workspace updatedSnapshot (AnalyzeDocument document))
      restartingGeneration <- awaitRestarting events firstGeneration
      assert "unexpected crash advances worker generation" (restartingGeneration > firstGeneration)
      secondGeneration <- awaitReadyGeneration events restartingGeneration
      replayed <- awaitAnalysis events secondGeneration
      assertEqual "replay restores latest authoritative document" updatedSnapshot.snapshotContentHash replayed.analysisContentHash
      assertEqual "replay retains workspace generation" generation replayed.analysisWorkspaceGeneration
      assert "fake result contains declaration" (not (null replayed.analysisDeclarations))
      assert "fake result contains requested diagnostic" (not (null replayed.analysisDiagnostics))
      let expectation =
            AnalysisExpectation
              { expectedWorkerGeneration = secondGeneration
              , expectedWorkspaceGeneration = generation
              , expectedSession = replayed.analysisSession
              , expectedDocument = document
              , expectedRevision = updatedSnapshot.snapshotRevision
              , expectedContentHash = updatedSnapshot.snapshotContentHash
              }
      assertEqual "all current identities accept a result" (Right replayed) (acceptAnalysisSnapshot expectation secondGeneration replayed)
      assert "a stale worker and revision are both reported" $
        case acceptAnalysisSnapshot expectation firstGeneration replayed {analysisRevision = TextRevision 2} of
          Left mismatches ->
            any isWorkerMismatch mismatches && any isRevisionMismatch mismatches
          Right _ -> False
      stopAnalysisClient client
      awaitStopped events
      recorded <- readIORef eventLog
      let afterSecondReady = dropWhile (not . isReadyGeneration secondGeneration) recorded
      assert "no stale pre-restart worker message is delivered after the new generation is ready" $
        all (not . isOlderWorkerMessage secondGeneration) afterSecondReady
    ) `finally` (stopAnalysisClient client >> waitAnalysisClient client >> removeIfPresent crashMarker)
  putStrLn "Visual Haskell analysis client supervision and replay tests passed"

workspaceEnvelope :: WorkspaceGeneration -> WorkspaceId -> ClientMessage -> ProtocolEnvelope ClientMessage
workspaceEnvelope generation workspace payload =
  (protocolEnvelope generation payload) {envelopeWorkspace = Just workspace}

documentEnvelope
  :: WorkspaceGeneration
  -> WorkspaceId
  -> DocumentSnapshot
  -> ClientMessage
  -> ProtocolEnvelope ClientMessage
documentEnvelope generation workspace snapshot payload =
  (workspaceEnvelope generation workspace payload)
    { envelopeDocument = Just snapshot.snapshotDocumentId
    , envelopeRevision = Just snapshot.snapshotRevision
    , envelopeContentHash = Just snapshot.snapshotContentHash
    }

awaitReady :: TQueue AnalysisClientEvent -> IO WorkerGeneration
awaitReady events = awaitMatching events $ \case
  AnalysisWorkerReady generation _ -> Just generation
  _ -> Nothing

awaitReadyGeneration :: TQueue AnalysisClientEvent -> WorkerGeneration -> IO WorkerGeneration
awaitReadyGeneration events expected = awaitMatching events $ \case
  AnalysisWorkerReady generation _ | generation == expected -> Just generation
  _ -> Nothing

awaitRestarting :: TQueue AnalysisClientEvent -> WorkerGeneration -> IO WorkerGeneration
awaitRestarting events previous = awaitMatching events $ \case
  AnalysisWorkerRestarting generation _ | generation > previous -> Just generation
  _ -> Nothing

awaitAnalysis :: TQueue AnalysisClientEvent -> WorkerGeneration -> IO (AnalysisSnapshot RevisionedSourceRange)
awaitAnalysis events expectedGeneration = awaitMatching events $ \case
  AnalysisWorkerMessage generation envelope
    | generation == expectedGeneration
    , AnalysisCompleted snapshot <- envelope.envelopePayload -> Just snapshot
  _ -> Nothing

awaitStopped :: TQueue AnalysisClientEvent -> IO ()
awaitStopped events = awaitMatching events $ \case
  AnalysisWorkerStopped -> Just ()
  _ -> Nothing

awaitMatching :: TQueue event -> (event -> Maybe value) -> IO value
awaitMatching events select = do
  result <- timeout 5000000 loop
  maybe (fail "timed out waiting for analysis-client event") pure result
  where
    loop = do
      event <- atomically (readTQueue events)
      maybe loop pure (select event)

assert :: String -> Bool -> IO ()
assert message condition = unless condition (fail message)

assertEqual :: (Eq value, Show value) => String -> value -> value -> IO ()
assertEqual message expected actual =
  assert (message <> ": expected " <> show expected <> ", got " <> show actual) (expected == actual)

isReadyGeneration :: WorkerGeneration -> AnalysisClientEvent -> Bool
isReadyGeneration expected (AnalysisWorkerReady actual _) = expected == actual
isReadyGeneration _ _ = False

isOlderWorkerMessage :: WorkerGeneration -> AnalysisClientEvent -> Bool
isOlderWorkerMessage current (AnalysisWorkerMessage generation _) = generation < current
isOlderWorkerMessage _ _ = False

isWorkerMismatch :: AnalysisMismatch -> Bool
isWorkerMismatch WorkerGenerationMismatch {} = True
isWorkerMismatch _ = False

isRevisionMismatch :: AnalysisMismatch -> Bool
isRevisionMismatch RevisionMismatch {} = True
isRevisionMismatch _ = False

removeIfPresent :: FilePath -> IO ()
removeIfPresent path = do
  present <- doesFileExist path
  if present then removeFile path else pure ()
