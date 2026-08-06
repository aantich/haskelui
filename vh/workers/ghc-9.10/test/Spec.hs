{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE LambdaCase #-}

module Main (main) where

import Control.Concurrent.STM
  ( TQueue
  , atomically
  , newTQueueIO
  , readTQueue
  , writeTQueue
  )
import Control.Exception (finally)
import Control.Monad (unless, when)
import qualified Data.Map.Strict as Map
import qualified Data.Text as Text
import System.Directory
  ( findExecutable
  , getTemporaryDirectory
  , makeAbsolute
  , removeFile
  )
import System.Environment (lookupEnv)
import System.FilePath ((</>))
import System.IO (hClose, openTempFile)
import System.Timeout (timeout)
import VisualHaskell.Analysis.Client
import VisualHaskell.Analysis.Ghc910
import VisualHaskell.Analysis.Protocol
import VisualHaskell.Semantic

main :: IO ()
main = do
  -- A Stack cradle launches @stack repl@. Running that while an enclosing
  -- @stack test@ owns Stack's build lock can deadlock, so the repository's
  -- self-hosted cradle check is an explicit post-build validation. The direct
  -- fixture below still exercises hie-bios during every ordinary test run.
  selfHostedRequested <- (== Just "1") <$> lookupEnv "VISUAL_HASKELL_TEST_SELF_HOSTED_CRADLE"
  when selfHostedRequested $ do
    repositoryRoot <- makeAbsolute (".." </> ".." </> "..")
    let repositoryModule = repositoryRoot </> "vh" </> "src" </> "VisualHaskell" </> "WorkspaceState.hs"
    selfHosted <- discoverCompilerInvocation repositoryModule [repositoryModule]
    selfHostedInvocation <- either (fail . show) pure selfHosted
    assert "hie-bios loads the repository's real Stack component" $
      selfHostedInvocation.invocationCompilerVersion == "9.10.3"
        && not (null selfHostedInvocation.invocationCompilerOptions)

  fixture <- makeAbsolute ("test" </> "fixtures" </> "two-module")
  discovered <- discoverCompilerInvocation (fixture </> "A.hs") [fixture </> "A.hs", fixture </> "B.hs"]
  invocation <- either (fail . show) pure discovered
  assert "hie-bios selected the fixture component root" (invocation.invocationComponentRoot == fixture)
  assert "hie-bios selected GHC 9.10.3" (invocation.invocationCompilerVersion == "9.10.3")
  let aPath = fixture </> "A.hs"
      bPath = fixture </> "B.hs"
      aSource = Text.unlines
        [ "module A (message) where"
        , "import B (value)"
        , "message :: String"
        , "message = value"
        ]
      bSource = Text.unlines
        [ "module B (value) where"
        , "value :: String"
        , "value = \"unsaved 😀\""
        ]
      aSnapshot = snapshot (DocumentId "A") aPath (TextRevision 1) aSource
      bSnapshot = snapshot (DocumentId "B") bPath (TextRevision 1) bSource
      documents = Map.fromList [(DocumentId "A", aSnapshot), (DocumentId "B", bSnapshot)]
  successful <- analyzeWorkspace fixture documents (DocumentId "A") (WorkspaceGeneration 3)
  analyzed <- either (fail . show) pure successful
  assert "two dependent unsaved modules typecheck" (analyzed.analysisCompleteness == Typechecked)
  assert "GHC returns the requested top-level declaration" (any ((== "message") . declarationName) analyzed.analysisDeclarations)
  assert "GHC types normalize into the stable type table" (not (Map.null analyzed.analysisTypes))
  assert "successful unsaved analysis has no errors" (null analyzed.analysisDiagnostics)

  let brokenSource = Text.unlines
        [ "module B (value) where"
        , "value :: String"
        , "value = missingIdentifier"
        ]
      brokenSnapshot = snapshot (DocumentId "B") bPath (TextRevision 2) brokenSource
      brokenDocuments = Map.insert (DocumentId "B") brokenSnapshot documents
  failed <- analyzeWorkspace fixture brokenDocuments (DocumentId "B") (WorkspaceGeneration 3)
  failedAnalysis <- either (fail . show) pure failed
  assert "a typecheck failure remains a semantic result" (failedAnalysis.analysisCompleteness == PartiallyFailed)
  assert "GHC diagnostics are captured" (not (null failedAnalysis.analysisDiagnostics))
  assert "diagnostics retain the exact unsaved revision" $
    all ((== TextRevision 2) . sourceRangeRevision . diagnosticRange) failedAnalysis.analysisDiagnostics
  (_, protocolAnalysis) <- analyzeThroughWorker fixture aSnapshot bSnapshot []
  assert "the real worker protocol returns typechecked unsaved analysis" (protocolAnalysis.analysisCompleteness == Typechecked)
  assert "the real worker protocol preserves content identity" (protocolAnalysis.analysisContentHash == aSnapshot.snapshotContentHash)
  temporary <- getTemporaryDirectory
  (marker, markerHandle) <- openTempFile temporary "visual-haskell-ghc-worker-crash-"
  hClose markerHandle
  removeFile marker
  (recoveredGeneration, recoveredAnalysis) <-
    analyzeThroughWorker fixture aSnapshot bSnapshot ["--crash-once-marker", marker]
      `finally` removeFile marker
  assert "the GHC worker was replaced after the forced process crash" (recoveredGeneration > WorkerGeneration 1)
  assert "the replacement worker replays unsaved buffers and completes analysis" $
    recoveredAnalysis.analysisCompleteness == Typechecked
      && recoveredAnalysis.analysisContentHash == aSnapshot.snapshotContentHash
  putStrLn "Visual Haskell GHC 9.10 project discovery, unsaved analysis, protocol, and crash/replay tests passed"

snapshot :: DocumentId -> FilePath -> TextRevision -> Text.Text -> DocumentSnapshot
snapshot document path revision contents =
  DocumentSnapshot document path revision (contentHash contents) contents LF

analyzeThroughWorker
  :: FilePath
  -> DocumentSnapshot
  -> DocumentSnapshot
  -> [String]
  -> IO (WorkerGeneration, AnalysisSnapshot RevisionedSourceRange)
analyzeThroughWorker fixture aSnapshot bSnapshot arguments = do
  executable <-
    findExecutable "visual-haskell-analysis-ghc910"
      >>= maybe (fail "GHC analysis worker executable was not on PATH") pure
  events <- newTQueueIO
  let generation = WorkspaceGeneration 8
      workspace = WorkspaceId "ghc-fixture"
      hello =
        protocolEnvelope generation $
          ClientHelloMessage
            ( ClientHello
                "visual-haskell-ghc-worker-test/0.1"
                (Just fixture)
                TrustedWorkspace
                [ WorkspaceLoadingCapability
                , FullDocumentSnapshotsCapability
                , DiagnosticsCapability
                , DocumentDeclarationsCapability
                , StructuredTypesCapability
                ]
            )
      record event = atomically (writeTQueue events event)
  let launch = (defaultWorkerLaunch executable) {workerArguments = arguments}
  client <- startAnalysisClient launch hello record
  (do
      workerGeneration <- awaitMatching events $ \case
        AnalysisWorkerReady readyGeneration _ -> Just readyGeneration
        _ -> Nothing
      sendAnalysisMessage client $
        (protocolEnvelope generation (OpenWorkspace (WorkspaceRequest workspace fixture TrustedWorkspace)))
          { envelopeWorkspace = Just workspace }
      sendAnalysisMessage client (documentEnvelope generation workspace aSnapshot (OpenDocument aSnapshot))
      sendAnalysisMessage client (documentEnvelope generation workspace bSnapshot (OpenDocument bSnapshot))
      sendAnalysisMessage client (documentEnvelope generation workspace aSnapshot (AnalyzeDocument aSnapshot.snapshotDocumentId))
      awaitMatching events $ \case
        AnalysisWorkerMessage actual envelope
          | actual >= workerGeneration
          , AnalysisCompleted analysis <- envelope.envelopePayload -> Just (actual, analysis)
        _ -> Nothing
    ) `finally` (stopAnalysisClient client >> waitAnalysisClient client)

documentEnvelope
  :: WorkspaceGeneration
  -> WorkspaceId
  -> DocumentSnapshot
  -> ClientMessage
  -> ProtocolEnvelope ClientMessage
documentEnvelope generation workspace document payload =
  (protocolEnvelope generation payload)
    { envelopeWorkspace = Just workspace
    , envelopeDocument = Just document.snapshotDocumentId
    , envelopeRevision = Just document.snapshotRevision
    , envelopeContentHash = Just document.snapshotContentHash
    }

awaitMatching :: TQueue event -> (event -> Maybe value) -> IO value
awaitMatching events select = do
  result <- timeout 30000000 loop
  maybe (fail "timed out waiting for GHC worker event") pure result
  where
    loop = do
      event <- atomically (readTQueue events)
      maybe loop pure (select event)

assert :: String -> Bool -> IO ()
assert message condition = unless condition (fail message)
