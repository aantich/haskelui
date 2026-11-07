{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE OverloadedRecordDot #-}
module ProtocolCheck (protocolCheck) where
import Control.Concurrent.STM hiding (check)
import Control.Exception (finally)
import Control.Monad (unless, forM_)
import Data.List (find)
import qualified Data.Text as T
import qualified Data.Text.IO as T
import System.Directory hiding (executable)
import System.Environment
import System.FilePath
import System.Timeout (timeout)
import System.IO (stderr)
import VisualHaskell.Analysis.Client
import VisualHaskell.Analysis.Protocol
import VisualHaskell.Semantic

protocolCheck :: FilePath -> ProjectProfile -> ProjectCatalog -> IO ()
protocolCheck root profile catalog = do
  executable <- getExecutablePath
  let candidates = [takeDirectory executable </> "visual-haskell-analysis-ghc910",
        takeDirectory (takeDirectory executable) </> "visual-haskell-analysis-ghc910/visual-haskell-analysis-ghc910"]
  worker <- findWorker candidates
  events <- newTQueueIO
  let generation = WorkspaceGeneration 7
      workspace = WorkspaceId "integration"
      base payload = (protocolEnvelope generation payload) {envelopeWorkspace = Just workspace}
      hello = base (ClientHelloMessage (ClientHello "integration" Nothing TrustedWorkspace []))
  client <- startAnalysisClient (defaultWorkerLaunch worker) hello (atomically . writeTQueue events)
  flip finally (stopAnalysisClient client >> waitAnalysisClient client) $ do
    sendAnalysisMessage client (base (OpenWorkspace (WorkspaceRequest workspace root UntrustedWorkspace)))
    _ <- await events (\message -> case message of WorkspaceFailed _ _ -> Just (); _ -> Nothing)
    sendAnalysisMessage client (base (OpenWorkspace (WorkspaceRequest workspace root TrustedWorkspace)))
    sendAnalysisMessage client (base (DiscoverProject (Just profile.profileId)))
    sourceUp <- T.readFile (root </> "upstream/src/Upstream.hs")
    sourceDown <- T.readFile (root </> "consumer/src/Downstream.hs")
    let up = document "upstream" (root </> "upstream/src/Upstream.hs") sourceUp
        down = document "downstream" (root </> "consumer/src/Downstream.hs") sourceDown
        changedUp = document "upstream" up.snapshotPath "module Upstream (value) where\nvalue :: String\nvalue = \"protocol-unsaved\"\n"
        changedDown = document "downstream" down.snapshotPath "module Downstream (answer) where\nimport Upstream\nanswer :: String\nanswer = value\n"
        analyze :: [DocumentSnapshot] -> DocumentSnapshot -> IO ()
        analyze documents snapshot = do
          forM_ documents (sendAnalysisMessage client . base . UpdateDocumentSnapshot)
          sendAnalysisMessage client (base (AnalyzeDocument snapshot.snapshotDocumentId))
            {envelopeDocument = Just snapshot.snapshotDocumentId, envelopeRevision = Just snapshot.snapshotRevision,
             envelopeContentHash = Just snapshot.snapshotContentHash, envelopeInputHash = Just (analysisInputsHash documents)}
        waitAnalysis = await events (\message -> case message of AnalysisCompleted analysis -> Just analysis; _ -> Nothing)
    -- Submit while discovery is still running: the coordinator must keep the
    -- newest intent, not fall back to an implicit flattened Stack cradle.
    analyze [up, down] down
    first <- waitAnalysis
    check "coordinator loads selected project" (first.analysisCompleteness == Typechecked)
    analyze [changedUp, down] down
    broken <- waitAnalysis
    check "coordinator propagates dependency overlays" (broken.analysisCompleteness == PartiallyFailed)
    analyze [changedUp, changedDown] changedDown
    fixed <- waitAnalysis
    check "coordinator recovers without saving" (fixed.analysisCompleteness == Typechecked)
    restartAnalysisWorker client
    restored <- waitAnalysis
    check "restart restores project choice and all unsaved documents" (restored.analysisCompleteness == Typechecked && restored.analysisSession /= fixed.analysisSession)
    -- Test/executable contexts share Component.hs but give it DIFFERENT types.
    test <- maybe (fail "missing test descriptor") pure (find ((== TestComponent) . projectComponentKind) catalog.catalogComponents)
    sendAnalysisMessage client (base (PrepareComponent test.projectComponentId))
    _ <- await events (\message -> case message of ProjectProgress text | "Preparing " `T.isPrefixOf` text -> Just (); _ -> Nothing)
    sendAnalysisMessage client (base (CancelRequest (RequestId 0)))
    _ <- await events (\message -> case message of ProjectProgress text | "cancelled" `T.isInfixOf` text -> Just (); _ -> Nothing)
    putStrLn "  ok: in-flight component preparation can be cancelled"
    let sharedPath = root </> "consumer/shared/Component.hs"
    sharedSource <- T.readFile sharedPath
    let shared = document "shared" sharedPath sharedSource
    sendAnalysisMessage client (base (PrepareComponent test.projectComponentId))
    analyze [changedUp, changedDown, shared] shared
    sharedAnalysis <- waitAnalysis
    check "explicit shared-source test context" (sharedAnalysis.analysisCompleteness == Typechecked)
    exe <- maybe (fail "missing exe descriptor") pure (find ((== ExecutableComponent) . projectComponentKind) catalog.catalogComponents)
    sendAnalysisMessage client (base (PrepareComponent exe.projectComponentId))
    analyze [changedUp, changedDown, shared] shared
    exeAnalysis <- waitAnalysis
    check "switching shared-source context makes a fresh session" (exeAnalysis.analysisCompleteness == Typechecked && exeAnalysis.analysisSession /= sharedAnalysis.analysisSession)
    let signatures :: AnalysisSnapshot RevisionedSourceRange -> [Maybe T.Text]
        signatures value = map declarationSignatureText value.analysisDeclarations
    check "shared-source contexts retain different inferred types" (signatures exeAnalysis /= signatures sharedAnalysis)
    sendAnalysisMessage client (base (CloseDocument shared.snapshotDocumentId))
    sendAnalysisMessage client (base (CancelRequest (RequestId 0)))
    _ <- await events (\message -> case message of ProjectProgress text | "cancelled" `T.isInfixOf` text -> Just (); _ -> Nothing)
    analyze [changedUp, changedDown] changedDown
    afterCancel <- waitAnalysis
    check "retry after cancellation keeps buffers" (afterCancel.analysisCompleteness == Typechecked)
    -- An atomic config edit must invalidate the live session automatically.
    let package = root </> "consumer/stage0-consumer.cabal"
    contents <- readFile package
    writeFile (package <.> "new") (contents <> "\n-- watcher regression\n")
    renameFile (package <.> "new") package
    _ <- await events (\message -> case message of ProjectConfigurationChanged _ -> Just (); _ -> Nothing)
    _ <- await events (\message -> case message of ProjectDiscovered _ -> Just (); _ -> Nothing)
    analyze [changedUp, changedDown] changedDown
    afterConfig <- waitAnalysis
    check "config reload preserves authoritative buffers" (afterConfig.analysisCompleteness == Typechecked && afterConfig.analysisSession /= afterCancel.analysisSession)
    sendAnalysisMessage client (base (CloseDocument up.snapshotDocumentId))
    analyze [down] down
    afterClose <- waitAnalysis
    check "closing dependency removes its overlay" (afterClose.analysisCompleteness == Typechecked)
  putStrLn ("PASS: " <> show profile.profileTool <> " protocol routing, shared contexts, crash replay, cancel, atomic config watch, close")

document :: T.Text -> FilePath -> T.Text -> DocumentSnapshot
document identifier path source = DocumentSnapshot (DocumentId identifier) path
  (TextRevision (unContentHash (contentHash source))) (contentHash source) source LF

await :: TQueue AnalysisClientEvent -> (WorkerMessage -> Maybe value) -> IO value
await events select = do
  result <- timeout (180 * 1000000) loop
  maybe (fail "Timed out waiting for project worker event") pure result
  where
    loop = do
      event <- atomically (readTQueue events)
      case event of
        AnalysisWorkerMessage _ envelope -> case select envelope.envelopePayload of
          Just value -> pure value
          Nothing -> case envelope.envelopePayload of
            WorkerRequestFailed _ failure -> fail (T.unpack failure.requestFailureCode <> ": " <> T.unpack failure.requestFailureMessage)
            ProjectProgress message -> T.hPutStrLn stderr ("  worker: " <> T.take 300 message) >> loop
            ProjectDiscovered _ -> putStrLn "  worker: project discovered" >> loop
            ComponentSelected component -> putStrLn ("  worker: selected " <> T.unpack component.componentId.unComponentId) >> loop
            _ -> loop
        AnalysisWorkerProtocolFailure _ message -> fail (T.unpack message)
        _ -> loop

findWorker :: [FilePath] -> IO FilePath
findWorker [] = fail "Build visual-haskell-analysis-ghc910 before running protocol checks"
findWorker (path : rest) = doesFileExist path >>= \exists -> if exists then pure path else findWorker rest
check :: String -> Bool -> IO ()
check label condition = unless condition (fail label) >> putStrLn ("  ok: " <> label)
