{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
module RegressionCheck (projectRegressionChecks) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.STM hiding (check)
import Control.Exception (finally, try, IOException)
import Control.Monad (forM_, unless, when)
import Data.List (find)
import qualified Data.Text as T
import qualified Data.Text.IO as T
import System.Directory hiding (executable)
import System.Environment (getExecutablePath)
import System.FilePath
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Signals (signalProcess, nullSignal)
import System.Timeout (timeout)
import Text.Read (readMaybe)
import VisualHaskell.Analysis.Client
import VisualHaskell.Analysis.Protocol
import VisualHaskell.Projects
import VisualHaskell.Semantic

projectRegressionChecks :: FilePath -> IO ()
projectRegressionChecks fixture = do
  executable <- getExecutablePath
  let candidates = [takeDirectory executable </> "visual-haskell-analysis-ghc910",
        takeDirectory (takeDirectory executable) </> "visual-haskell-analysis-ghc910/visual-haskell-analysis-ghc910"]
  worker <- findWorker candidates
  -- Use the real documented Stack launch, not just a simulated environment.
  withSystemTempDirectory "vh-stack-launch-" $ \temporary -> do
    root <- canonicalizePath temporary
    copyTree fixture root
    createDirectory (root </> ".git")
    profiles <- discoverProfiles root
    cabal <- maybe (fail "missing Cabal profile") pure (find ((== CabalProject) . profileTool) profiles)
    withClient ((defaultWorkerLaunch "stack") {workerArguments = ["exec", "--", worker], workerHandshakeTimeoutMicroseconds = 30000000}) $ \client events -> do
      open client root TrustedWorkspace
      sendAnalysisMessage client (message (DiscoverProject (Just cabal.profileId)))
      _ <- await events $ \payload -> case payload of
        ProjectDiscovered catalog | not (null catalog.catalogComponents) -> Just ()
        _ -> Nothing
      source <- T.readFile (root </> "consumer/src/Downstream.hs")
      submit client (document (root </> "consumer/src/Downstream.hs") source)
      result <- await events analysisResult
      check "Cabal preparation works when IDE is launched by stack exec" (result.analysisCompleteness == Typechecked)
  withSystemTempDirectory "vh-profile-recovery-" $ \temporary -> do
    root <- canonicalizePath temporary
    copyTree fixture root
    createDirectory (root </> ".git")
    writeFile (root </> "stack.yaml") "resolver: [invalid-resolver-shape]\npackages: [upstream, consumer]\n"
    profiles <- discoverProfiles root
    stack <- maybe (fail "missing Stack profile") pure (find ((== StackProject) . profileTool) profiles)
    cabal <- maybe (fail "missing Cabal profile") pure (find ((== CabalProject) . profileTool) profiles)
    withClient (defaultWorkerLaunch worker) $ \client events -> do
      open client root TrustedWorkspace
      sendAnalysisMessage client (message (DiscoverProject (Just stack.profileId)))
      preview <- await events $ \payload -> case payload of ProjectDiscovered catalog -> Just catalog; _ -> Nothing
      check "failed restored profile exposes healthy alternatives" (length preview.catalogProfiles == 2 && preview.catalogSelectedProfile == Just stack.profileId)
      _ <- await events $ \payload -> case payload of
        WorkerRequestFailed _ failure | failure.requestFailureCode `elem` ["project-discovery-failed", "compiler-unavailable"] -> Just ()
        _ -> Nothing
      sendAnalysisMessage client (message (DiscoverProject (Just cabal.profileId)))
      _ <- await events $ \payload -> case payload of
        ProjectDiscovered catalog | not (null catalog.catalogComponents) -> Just ()
        _ -> Nothing
      source <- T.readFile (root </> "consumer/src/Downstream.hs")
      submit client (document (root </> "consumer/src/Downstream.hs") source)
      result <- await events analysisResult
      check "selecting healthy Cabal profile recovers without reopening" (result.analysisCompleteness == Typechecked)
  forM_ ["cancel", "revoke", "switch-profile", "stop-client"] $ \action ->
    withSystemTempDirectory "vh-busy-compiler-" $ \temporary -> do
      root <- canonicalizePath temporary
      createDirectory (root </> ".git")
      writeFile (root </> "hie.yaml") "cradle:\n  direct:\n    arguments: [-i., -package, template-haskell, -package, unix, Slow.hs]\n"
      let source = T.unlines
            [ "{-# LANGUAGE TemplateHaskell #-}", "module Slow where"
            , "import Control.Concurrent (threadDelay)", "import Language.Haskell.TH"
            , "import System.Posix.Process (getProcessID)", "import System.IO (hPutStrLn, stderr)"
            , "value :: Int"
            , "value = $(runIO (getProcessID >>= hPutStrLn stderr . (\"slow-compiler-pid:\" ++) . show) >> runIO (threadDelay 60000000) >> [| 1 |])"
            ]
          path = root </> "Slow.hs"
      T.writeFile path source
      withClient ((defaultWorkerLaunch worker) {workerArguments = ["--debug"]}) $ \client events -> do
        open client root TrustedWorkspace
        submit client (document path source)
        process <- await events $ \payload -> case payload of
          ProjectProgress logLine | (_, pid) <- T.breakOn "slow-compiler-pid:" logLine, not (T.null pid) ->
            readMaybe (T.unpack (T.strip (T.drop (T.length "slow-compiler-pid:") pid)))
          _ -> Nothing
        let large = document path (source <> "\n-- " <> T.replicate (2 * 1024 * 1024) "x")
        sendAnalysisMessage client (message (UpdateDocumentSnapshot large))
        threadDelay 100000
        result <- timeout 2000000 $ if action == "stop-client"
          then stopAnalysisClient client >> waitAnalysisClient client
          else do
            case action of
              "cancel" -> sendAnalysisMessage client (message (CancelRequest (RequestId 0)))
              "revoke" -> open client root UntrustedWorkspace
              _ -> sendAnalysisMessage client (message (DiscoverProject Nothing))
            await events $ \payload -> case (action, payload) of
              ("cancel", ProjectProgress text) | "cancelled" `T.isInfixOf` text -> Just ()
              ("revoke", WorkspaceFailed _ _) -> Just ()
              ("switch-profile", ProjectDiscovered _) -> Just ()
              _ -> Nothing
        check (action <> " interrupts a compiler with a full input pipe") (result == Just ())
        let waitExit 0 = fail (action <> " left its compiler process alive")
            waitExit attempts = do
              alive <- try (signalProcess nullSignal process) :: IO (Either IOException ())
              case alive of Left _ -> pure (); Right () -> threadDelay 10000 >> waitExit (attempts - 1)
        waitExit (100 :: Int)
        putStrLn ("PASS: " <> action <> " reaps busy compiler before acknowledging")

message :: ClientMessage -> ProtocolEnvelope ClientMessage
message payload = (protocolEnvelope (WorkspaceGeneration 1) payload) {envelopeWorkspace = Just (WorkspaceId "regressions")}

open :: AnalysisClient -> FilePath -> TrustMode -> IO ()
open client root trust = sendAnalysisMessage client (message (OpenWorkspace (WorkspaceRequest (WorkspaceId "regressions") root trust)))

document :: FilePath -> T.Text -> DocumentSnapshot
document path source = DocumentSnapshot (DocumentId "regression") path (TextRevision (unContentHash (contentHash source))) (contentHash source) source LF

submit :: AnalysisClient -> DocumentSnapshot -> IO ()
submit client snapshot = do
  sendAnalysisMessage client (message (UpdateDocumentSnapshot snapshot))
  sendAnalysisMessage client (message (AnalyzeDocument snapshot.snapshotDocumentId))
    {envelopeDocument = Just snapshot.snapshotDocumentId, envelopeRevision = Just snapshot.snapshotRevision,
     envelopeContentHash = Just snapshot.snapshotContentHash, envelopeInputHash = Just (analysisInputsHash [snapshot])}

analysisResult :: WorkerMessage -> Maybe (AnalysisSnapshot RevisionedSourceRange)
analysisResult (AnalysisCompleted result) = Just result
analysisResult _ = Nothing

withClient :: WorkerLaunch -> (AnalysisClient -> TQueue AnalysisClientEvent -> IO value) -> IO value
withClient launch action = do
  events <- newTQueueIO
  client <- startAnalysisClient launch (message (ClientHelloMessage (ClientHello "regression-check" Nothing TrustedWorkspace []))) (atomically . writeTQueue events)
  action client events `finally` (stopAnalysisClient client >> waitAnalysisClient client)

await :: TQueue AnalysisClientEvent -> (WorkerMessage -> Maybe value) -> IO value
await events select = do
  result <- timeout 180000000 loop
  maybe (fail "Timed out waiting for regression worker event") pure result
  where
    loop = do
      event <- atomically (readTQueue events)
      case event of
        AnalysisWorkerMessage _ envelope -> case select envelope.envelopePayload of
          Just value -> pure value
          Nothing -> case envelope.envelopePayload of
            WorkerRequestFailed _ failure -> fail (show failure)
            _ -> loop
        AnalysisWorkerProtocolFailure _ failure -> fail (T.unpack failure)
        AnalysisWorkerExited _ code -> fail ("worker exited: " <> show code)
        _ -> loop

findWorker :: [FilePath] -> IO FilePath
findWorker [] = fail "Build visual-haskell-analysis-ghc910 before regression checks"
findWorker (path : rest) = doesFileExist path >>= \exists -> if exists then pure path else findWorker rest

check :: String -> Bool -> IO ()
check label condition = unless condition (fail label) >> putStrLn ("  ok: " <> label)

copyTree :: FilePath -> FilePath -> IO ()
copyTree source destination = do
  createDirectoryIfMissing True destination
  entries <- listDirectory source
  forM_ entries $ \entry -> when (entry `notElem` [".stack-work", "dist-newstyle", "stack.yaml.lock"]) $ do
    let from = source </> entry; to = destination </> entry
    directory <- doesDirectoryExist from
    if directory then copyTree from to else copyFile from to
