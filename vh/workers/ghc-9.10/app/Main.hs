{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Main (main) where

import Control.Exception (SomeException, displayException, try)
import qualified Data.Map.Strict as Map
import Data.Map.Strict (Map)
import qualified Data.Text as Text
import Data.Time.Clock (diffUTCTime, getCurrentTime)
import System.Directory (doesFileExist)
import System.Environment (getArgs)
import System.Exit (ExitCode (ExitFailure), exitFailure, exitWith)
import System.IO
  ( BufferMode (NoBuffering)
  , hPutStrLn
  , hSetBinaryMode
  , hSetBuffering
  , stderr
  , stdin
  , stdout
  )
import VisualHaskell.Analysis.Ghc910
import VisualHaskell.Analysis.Protocol
import VisualHaskell.Semantic

data WorkerState = WorkerState
  { workerWorkspace :: !(Maybe WorkspaceId)
  , workerRoot :: !(Maybe FilePath)
  , workerSession :: !(Maybe SessionId)
  , workerComponent :: !(Maybe ComponentInfo)
  , workerDocuments :: !(Map DocumentId DocumentSnapshot)
  }

data WorkerOptions = WorkerOptions
  { crashOnceMarker :: !(Maybe FilePath)
  , workerDebugEnabled :: !Bool
  }

main :: IO ()
main = do
  options <- parseWorkerOptions <$> getArgs
  hSetBinaryMode stdin True
  hSetBinaryMode stdout True
  hSetBuffering stdout NoBuffering
  workerDebug options "worker.start" []
  first <- readFrame defaultFrameLimits stdin
  case first of
    Right envelope@(ProtocolEnvelope {envelopePayload = ClientHelloMessage _}) -> do
      workerDebug options "handshake.received" []
      send envelope $
        WorkerHelloMessage
          WorkerHello
            { workerAcceptedProtocol = protocolV1
            , workerVersion = "visual-haskell-analysis-ghc910/0.1.0"
            , workerCompilerVersion = Just (CompilerVersion "9.10.3")
            , workerCapabilities =
                [ WorkspaceLoadingCapability
                , ComponentDiscoveryCapability
                , FullDocumentSnapshotsCapability
                , DiagnosticsCapability
                , DocumentDeclarationsCapability
                , StructuredTypesCapability
                ]
            , workerMaximumFrameBytes = maximumFrameBytes defaultFrameLimits
            }
      workerDebug options "handshake.complete" []
      loop options (WorkerState Nothing Nothing Nothing Nothing Map.empty)
    Right _ -> failWorker "first frame was not ClientHello"
    Left failure -> failWorker ("could not read ClientHello: " <> show failure)

loop :: WorkerOptions -> WorkerState -> IO ()
loop options state = do
  incoming <- readFrame defaultFrameLimits stdin
  case incoming of
    Left FrameEndOfInput -> pure ()
    Left failure -> failWorker ("protocol read failed: " <> show failure)
    Right envelope -> do
      workerDebug options "command.received" (clientMessageFields envelope.envelopePayload)
      case envelope.envelopePayload of
        ClientHelloMessage _ -> do
          sendFailure envelope "duplicate-client-hello" "ClientHello may only be sent once" False
          loop options state
        OpenWorkspace request ->
          case request.workspaceRequestTrust of
            UntrustedWorkspace -> do
              let rejected = RequestFailure "workspace-untrusted" "Direct GHC analysis requires explicit workspace trust" True
              send envelope (WorkspaceFailed request.workspaceRequestId rejected)
              loop options state
            TrustedWorkspace -> do
              workerDebug options "workspace.open"
                [ ("workspace", request.workspaceRequestId.unWorkspaceId)
                , ("root", Text.pack request.workspaceRequestRoot)
                ]
              let session = SessionId ("workspace:" <> request.workspaceRequestId.unWorkspaceId)
                  updated =
                    WorkerState
                      (Just request.workspaceRequestId)
                      (Just request.workspaceRequestRoot)
                      (Just session)
                      Nothing
                      Map.empty
              send envelope (WorkspaceLoading request.workspaceRequestId)
              send envelope (WorkspaceReady request.workspaceRequestId session)
              loop options updated
        SelectComponent component ->
          case state.workerComponent of
            Just info | info.componentId == component -> do
              send envelope (ComponentSelected info)
              loop options state
            _ -> do
              sendFailure envelope "component-unavailable" "The requested component has not been discovered" True
              loop options state
        OpenDocument snapshot ->
          loop options state {workerDocuments = Map.insert snapshot.snapshotDocumentId snapshot state.workerDocuments}
        UpdateDocumentSnapshot snapshot ->
          loop options state {workerDocuments = Map.insert snapshot.snapshotDocumentId snapshot state.workerDocuments}
        CloseDocument document ->
          loop options state {workerDocuments = Map.delete document state.workerDocuments}
        AnalyzeDocument document -> do
          crashOnceIfRequested options
          discovered <- analyze options envelope state document
          let selected = case discovered of
                Just component -> Just component
                Nothing -> state.workerComponent
          loop options state {workerComponent = selected}
        CancelRequest _ -> do
          sendFailure envelope "cancellation-unsupported" "This feasibility worker completes one request at a time" True
          loop options state
        ReloadConfiguration -> do
          send envelope (WorkerHealthChanged WorkerHealthy)
          loop options state
        ShutdownWorker -> pure ()

parseWorkerOptions :: [String] -> WorkerOptions
parseWorkerOptions = go (WorkerOptions Nothing False)
  where
    go options [] = options
    go options ("--debug" : rest) = go options {workerDebugEnabled = True} rest
    go options ("--crash-once-marker" : marker : rest) =
      go options {crashOnceMarker = Just marker} rest
    go options (_ : rest) = go options rest

-- Test-only process fault injection. The marker lives outside the worker, so
-- the replacement process observes it and completes replayed work normally.
crashOnceIfRequested :: WorkerOptions -> IO ()
crashOnceIfRequested options =
  case options.crashOnceMarker of
    Nothing -> pure ()
    Just marker -> do
      alreadyCrashed <- doesFileExist marker
      if alreadyCrashed
        then pure ()
        else do
          writeFile marker "crashed\n"
          hPutStrLn stderr "forced GHC worker crash before analysis result"
          exitWith (ExitFailure 86)

analyze
  :: WorkerOptions
  -> ProtocolEnvelope ClientMessage
  -> WorkerState
  -> DocumentId
  -> IO (Maybe ComponentInfo)
analyze options envelope state document =
  case (state.workerWorkspace, state.workerRoot, state.workerSession) of
    (Just _, Just root, Just _) -> do
      started <- getCurrentTime
      workerDebug options "analysis.start"
        [ ("document", document.unDocumentId)
        , ("root", Text.pack root)
        , ("openDocuments", Text.pack (show (Map.size state.workerDocuments)))
        ]
      attempted <- try (analyzeWorkspace root state.workerDocuments document envelope.envelopeWorkspaceGeneration)
      finished <- getCurrentTime
      workerDebug options "analysis.finish"
        [ ("document", document.unDocumentId)
        , ("milliseconds", Text.pack (show (round (diffUTCTime finished started * 1000) :: Integer)))
        , ("result", either (const "exception") (either (const "failure") (const "success")) attempted)
        ]
      case attempted of
        Left (exception :: SomeException) ->
          sendFailure envelope "worker-exception" (Text.pack (displayException exception)) True >> pure Nothing
        Right (Left failure) ->
          sendFailure envelope failure.failureCode failure.failureMessage failure.failureRecoverable >> pure Nothing
        Right (Right snapshot) -> do
          let component =
                ComponentInfo
                  { componentId = ComponentId snapshot.analysisSession.unSessionId
                  , componentRoot = root
                  , componentCompilerVersion = CompilerVersion "9.10.3"
                  , componentSession = snapshot.analysisSession
                  }
          send envelope (ComponentDiscovered component)
          send envelope (ComponentSelected component)
          send envelope (AnalysisCompleted snapshot)
          pure (Just component)
    _ ->
      sendFailure envelope "workspace-unavailable" "Open a trusted workspace before analysis" True
        >> pure Nothing

send
  :: ProtocolEnvelope ClientMessage
  -> WorkerMessage
  -> IO ()
send incoming payload = do
  let outgoing =
        ProtocolEnvelope
          { envelopeProtocolVersion = protocolV1
          , envelopeRequestId = incoming.envelopeRequestId
          , envelopeWorkspace = incoming.envelopeWorkspace
          , envelopeWorkspaceGeneration = incoming.envelopeWorkspaceGeneration
          , envelopeSession = case messageSession payload of
              Just session -> Just session
              Nothing -> incoming.envelopeSession
          , envelopeDocument = incoming.envelopeDocument
          , envelopeRevision = incoming.envelopeRevision
          , envelopeContentHash = incoming.envelopeContentHash
          , envelopePayload = payload
          }
  result <- writeFrame defaultFrameLimits stdout outgoing
  case result of
    Right () -> pure ()
    Left failure -> failWorker ("protocol write failed: " <> show failure)

workerDebug :: WorkerOptions -> Text.Text -> [(Text.Text, Text.Text)] -> IO ()
workerDebug options operation fields =
  if options.workerDebugEnabled
    then
      hPutStrLn stderr . Text.unpack $
        "vh-ghc-worker "
          <> operation
          <> foldMap (\(name, value) -> " " <> name <> "=" <> value) fields
    else pure ()

clientMessageFields :: ClientMessage -> [(Text.Text, Text.Text)]
clientMessageFields message =
  case message of
    ClientHelloMessage {} -> [("kind", "client-hello")]
    OpenWorkspace request ->
      [ ("kind", "open-workspace")
      , ("workspace", request.workspaceRequestId.unWorkspaceId)
      , ("root", Text.pack request.workspaceRequestRoot)
      , ("trust", Text.pack (show request.workspaceRequestTrust))
      ]
    SelectComponent component -> [("kind", "select-component"), ("component", component.unComponentId)]
    OpenDocument snapshot -> snapshotFields "open-document" snapshot
    UpdateDocumentSnapshot snapshot -> snapshotFields "update-document" snapshot
    CloseDocument document -> [("kind", "close-document"), ("document", document.unDocumentId)]
    AnalyzeDocument document -> [("kind", "analyze-document"), ("document", document.unDocumentId)]
    CancelRequest request -> [("kind", "cancel-request"), ("request", Text.pack (show request))]
    ReloadConfiguration -> [("kind", "reload-configuration")]
    ShutdownWorker -> [("kind", "shutdown-worker")]
  where
    snapshotFields
      :: Text.Text
      -> DocumentSnapshot
      -> [(Text.Text, Text.Text)]
    snapshotFields kind snapshot =
      [ ("kind", kind)
      , ("document", snapshot.snapshotDocumentId.unDocumentId)
      , ("path", Text.pack snapshot.snapshotPath)
      , ("revision", Text.pack (show snapshot.snapshotRevision.unTextRevision))
      , ("contentHash", Text.pack (show snapshot.snapshotContentHash.unContentHash))
      , ("characters", Text.pack (show (Text.length snapshot.snapshotText)))
      ]

messageSession :: WorkerMessage -> Maybe SessionId
messageSession message =
  case message of
    ComponentDiscovered component -> Just component.componentSession
    ComponentSelected component -> Just component.componentSession
    AnalysisCompleted snapshot -> Just snapshot.analysisSession
    _ -> Nothing

sendFailure
  :: ProtocolEnvelope ClientMessage
  -> Text.Text
  -> Text.Text
  -> Bool
  -> IO ()
sendFailure envelope code message recoverable =
  send envelope (WorkerRequestFailed envelope.envelopeRequestId (RequestFailure code message recoverable))

failWorker :: String -> IO value
failWorker message = hPutStrLn stderr message >> exitFailure
