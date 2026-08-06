{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

module VisualHaskell.Analysis.Service
  ( AnalysisCommand (..)
  , AnalysisConfiguration (..)
  , AnalysisServiceEvent (..)
  , analysisService
  , analysisServiceKey
  , defaultAnalysisConfiguration
  ) where

import Control.Concurrent.Async (race_)
import Control.Exception (finally)
import Data.Text (Text)
import qualified Data.Text as Text
import HaskeLUI.Core
import VisualHaskell.Analysis.Client
import VisualHaskell.Analysis.Protocol
import VisualHaskell.Semantic

-- | Product-level commands deliberately carry semantic identities rather than
-- transport details. The adapter is the only Visual Haskell UI module that
-- constructs protocol envelopes.
data AnalysisCommand
  = ConfigureAnalysisWorkspace
      !WorkspaceGeneration
      !WorkspaceRequest
  | SelectAnalysisComponent
      !WorkspaceGeneration
      !WorkspaceId
      !ComponentId
  | UpsertAnalysisDocument
      !WorkspaceGeneration
      !WorkspaceId
      !(Maybe SessionId)
      !DocumentSnapshot
  | CloseAnalysisDocument
      !WorkspaceGeneration
      !WorkspaceId
      !(Maybe SessionId)
      !DocumentId
  | RequestDocumentAnalysis
      !WorkspaceGeneration
      !WorkspaceId
      !(Maybe SessionId)
      !DocumentSnapshot
  | ReloadAnalysisConfiguration
      !WorkspaceGeneration
      !(Maybe WorkspaceId)
      !(Maybe SessionId)
  | RestartAnalysisWorker
  deriving stock (Eq, Show)

data AnalysisConfiguration = AnalysisConfiguration
  { analysisWorkerLaunch :: !WorkerLaunch
  , analysisClientVersion :: !Text
  , analysisTrustMode :: !TrustMode
  , analysisRequestedCapabilities :: ![AnalysisCapability]
  , analysisTraceSink :: !TraceSink
  }

instance Eq AnalysisConfiguration where
  left == right =
    left.analysisWorkerLaunch == right.analysisWorkerLaunch
      && left.analysisClientVersion == right.analysisClientVersion
      && left.analysisTrustMode == right.analysisTrustMode
      && left.analysisRequestedCapabilities == right.analysisRequestedCapabilities

instance Show AnalysisConfiguration where
  show configuration =
    "AnalysisConfiguration {analysisWorkerLaunch = "
      <> show configuration.analysisWorkerLaunch
      <> ", analysisClientVersion = "
      <> show configuration.analysisClientVersion
      <> ", analysisTrustMode = "
      <> show configuration.analysisTrustMode
      <> ", analysisRequestedCapabilities = "
      <> show configuration.analysisRequestedCapabilities
      <> ", analysisTraceSink = <trace-sink>}"

defaultAnalysisConfiguration :: FilePath -> AnalysisConfiguration
defaultAnalysisConfiguration executable =
  AnalysisConfiguration
    { analysisWorkerLaunch = defaultWorkerLaunch executable
    , analysisClientVersion = "visual-haskell/0.1.0"
    , analysisTrustMode = TrustedWorkspace
    , analysisRequestedCapabilities =
        [ WorkspaceLoadingCapability
        , ComponentDiscoveryCapability
        , FullDocumentSnapshotsCapability
        , DiagnosticsCapability
        , DocumentDeclarationsCapability
        , StructuredTypesCapability
        ]
    , analysisTraceSink = noTrace
    }

data AnalysisServiceEvent
  = AnalysisClientChanged !AnalysisClientEvent
  | AnalysisServiceChanged !ServiceStatus
  deriving stock (Eq, Show)

analysisServiceKey :: ServiceKey
analysisServiceKey = ServiceKey "visual-haskell.analysis"

analysisService
  :: AnalysisConfiguration
  -> (AnalysisServiceEvent -> ExternalEvent model)
  -> (Service model, ServiceEndpoint AnalysisCommand)
analysisService configuration toExternal =
  serviceWithStatus
    analysisServiceKey
    "Visual Haskell direct GHC analysis service"
    serviceOptions
    (toExternal . AnalysisServiceChanged)
    (runAnalysisService configuration toExternal)
  where
    serviceOptions =
      defaultServiceOptions
        { serviceCommandCapacity = 256
        , serviceOverflowPolicy = ReplacePendingCommand analysisCommandKey
        }

runAnalysisService
  :: AnalysisConfiguration
  -> (AnalysisServiceEvent -> ExternalEvent model)
  -> ServiceContext model AnalysisCommand
  -> IO ()
runAnalysisService configuration toExternal context = do
  analysisTrace configuration TraceInfo "service.start"
    [ ("worker", Text.pack configuration.analysisWorkerLaunch.workerExecutable)
    , ("arguments", Text.pack (show configuration.analysisWorkerLaunch.workerArguments))
    ]
  client <-
    startAnalysisClient
      configuration.analysisWorkerLaunch
      helloEnvelope
      (\event -> do
        traceAnalysisClientEvent configuration event
        emitExternalEvent context.serviceEvents (toExternal (AnalysisClientChanged event))
      )
  -- Runtime service cancellation must remain prompt. The client supervisor
  -- owns graceful child shutdown after receiving StopCommand; waiting here
  -- would make an outer asynchronous cancellation block on a worker that is
  -- itself still inside startup/handshake timeout handling.
  let stop =
        analysisTrace configuration TraceInfo "service.stop" []
          >> stopAnalysisClient client
  race_ (waitAnalysisClient client) (commandLoop client) `finally` stop
  where
    helloEnvelope =
      protocolEnvelope (WorkspaceGeneration 0) $
        ClientHelloMessage
          ClientHello
            { clientVersion = configuration.analysisClientVersion
            , clientRequestedWorkspaceRoot = Nothing
            , clientTrustMode = configuration.analysisTrustMode
            , clientRequestedCapabilities = configuration.analysisRequestedCapabilities
            }

    commandLoop client = do
      next <- context.receiveCommand
      case next of
        Nothing -> pure ()
        Just RestartAnalysisWorker -> do
          analysisTrace configuration TraceWarning "command.restart-worker" []
          restartAnalysisWorker client
          commandLoop client
        Just command -> do
          traceAnalysisCommand configuration command
          sendAnalysisMessage client (commandEnvelope command)
          commandLoop client

analysisTrace
  :: AnalysisConfiguration
  -> TraceSeverity
  -> Text
  -> [(Text, Text)]
  -> IO ()
analysisTrace configuration severity =
  trace configuration.analysisTraceSink severity "visual-haskell.analysis"

traceAnalysisCommand :: AnalysisConfiguration -> AnalysisCommand -> IO ()
traceAnalysisCommand configuration command =
  analysisTrace configuration TraceDebug "command.send" (analysisCommandFields command)

analysisCommandFields :: AnalysisCommand -> [(Text, Text)]
analysisCommandFields command =
  ("kind", analysisCommandKey command) :
    case command of
      ConfigureAnalysisWorkspace generation request ->
        generationFields generation
          <> [ ("workspace", request.workspaceRequestId.unWorkspaceId)
             , ("root", Text.pack request.workspaceRequestRoot)
             , ("trust", Text.pack (show request.workspaceRequestTrust))
             ]
      SelectAnalysisComponent generation workspace component ->
        generationFields generation
          <> [("workspace", workspace.unWorkspaceId), ("component", component.unComponentId)]
      UpsertAnalysisDocument generation workspace _ snapshot ->
        generationFields generation <> documentFields workspace snapshot
      CloseAnalysisDocument generation workspace _ document ->
        generationFields generation
          <> [("workspace", workspace.unWorkspaceId), ("document", document.unDocumentId)]
      RequestDocumentAnalysis generation workspace _ snapshot ->
        generationFields generation <> documentFields workspace snapshot
      ReloadAnalysisConfiguration generation workspace _ ->
        generationFields generation
          <> [("workspace", maybe "<none>" (.unWorkspaceId) workspace)]
      RestartAnalysisWorker -> []
  where
    generationFields :: WorkspaceGeneration -> [(Text, Text)]
    generationFields generation =
      [("workspaceGeneration", Text.pack (show generation.unWorkspaceGeneration))]
    documentFields :: WorkspaceId -> DocumentSnapshot -> [(Text, Text)]
    documentFields workspace snapshot =
      [ ("workspace", workspace.unWorkspaceId)
      , ("document", snapshot.snapshotDocumentId.unDocumentId)
      , ("path", Text.pack snapshot.snapshotPath)
      , ("revision", Text.pack (show snapshot.snapshotRevision.unTextRevision))
      , ("contentHash", Text.pack (show snapshot.snapshotContentHash.unContentHash))
      , ("characters", Text.pack (show (Text.length snapshot.snapshotText)))
      ]

traceAnalysisClientEvent :: AnalysisConfiguration -> AnalysisClientEvent -> IO ()
traceAnalysisClientEvent configuration event =
  analysisTrace configuration severity "client.event" fields
  where
    (severity, fields) =
      case event of
        AnalysisWorkerStarting generation ->
          (TraceInfo, [("kind", "worker-starting"), workerGenerationField generation])
        AnalysisWorkerReady generation hello ->
          ( TraceInfo
          , [ ("kind", "worker-ready")
            , workerGenerationField generation
            , ("workerVersion", hello.workerVersion)
            ]
          )
        AnalysisWorkerMessage generation envelope ->
          ( TraceDebug
          , [ ("kind", workerMessageKind envelope.envelopePayload)
            , workerGenerationField generation
            , ("workspaceGeneration", Text.pack (show envelope.envelopeWorkspaceGeneration.unWorkspaceGeneration))
            ]
          )
        AnalysisWorkerLog generation message ->
          (TraceDebug, [("kind", "worker-log"), workerGenerationField generation, ("message", message)])
        AnalysisWorkerProtocolFailure generation message ->
          (TraceError, [("kind", "protocol-failure"), workerGenerationField generation, ("message", message)])
        AnalysisWorkerExited generation exitCode ->
          (TraceWarning, [("kind", "worker-exited"), workerGenerationField generation, ("exit", Text.pack (show exitCode))])
        AnalysisWorkerRestarting generation attempt ->
          (TraceWarning, [("kind", "worker-restarting"), workerGenerationField generation, ("attempt", Text.pack (show attempt))])
        AnalysisWorkerStopped -> (TraceInfo, [("kind", "worker-stopped")])

    workerGenerationField :: WorkerGeneration -> (Text, Text)
    workerGenerationField generation =
      ("workerGeneration", Text.pack (show generation.unWorkerGeneration))

workerMessageKind :: WorkerMessage -> Text
workerMessageKind message =
  case message of
    WorkerHelloMessage {} -> "worker-hello"
    WorkspaceLoading {} -> "workspace-loading"
    WorkspaceReady {} -> "workspace-ready"
    WorkspaceFailed {} -> "workspace-failed"
    ComponentDiscovered {} -> "component-discovered"
    ComponentSelected {} -> "component-selected"
    AnalysisCompleted {} -> "analysis-completed"
    WorkerRequestFailed {} -> "request-failed"
    WorkerHealthChanged {} -> "health-changed"

commandEnvelope :: AnalysisCommand -> ProtocolEnvelope ClientMessage
commandEnvelope command =
  case command of
    ConfigureAnalysisWorkspace generation request ->
      (protocolEnvelope generation (OpenWorkspace request))
        { envelopeWorkspace = Just request.workspaceRequestId
        }
    SelectAnalysisComponent generation workspace component ->
      (protocolEnvelope generation (SelectComponent component))
        { envelopeWorkspace = Just workspace
        }
    UpsertAnalysisDocument generation workspace session snapshot ->
      documentEnvelope generation workspace session snapshot (UpdateDocumentSnapshot snapshot)
    CloseAnalysisDocument generation workspace session document ->
      (protocolEnvelope generation (CloseDocument document))
        { envelopeWorkspace = Just workspace
        , envelopeSession = session
        , envelopeDocument = Just document
        }
    RequestDocumentAnalysis generation workspace session snapshot ->
      documentEnvelope generation workspace session snapshot (AnalyzeDocument snapshot.snapshotDocumentId)
    ReloadAnalysisConfiguration generation workspace session ->
      (protocolEnvelope generation ReloadConfiguration)
        { envelopeWorkspace = workspace
        , envelopeSession = session
        }
    RestartAnalysisWorker ->
      error "RestartAnalysisWorker is handled by the service and has no wire envelope"

documentEnvelope
  :: WorkspaceGeneration
  -> WorkspaceId
  -> Maybe SessionId
  -> DocumentSnapshot
  -> ClientMessage
  -> ProtocolEnvelope ClientMessage
documentEnvelope generation workspace session snapshot payload =
  (protocolEnvelope generation payload)
    { envelopeWorkspace = Just workspace
    , envelopeSession = session
    , envelopeDocument = Just snapshot.snapshotDocumentId
    , envelopeRevision = Just snapshot.snapshotRevision
    , envelopeContentHash = Just snapshot.snapshotContentHash
    }

analysisCommandKey :: AnalysisCommand -> Text
analysisCommandKey command =
  case command of
    ConfigureAnalysisWorkspace {} -> "workspace"
    SelectAnalysisComponent {} -> "component"
    UpsertAnalysisDocument _ _ _ snapshot -> documentKey "snapshot" snapshot.snapshotDocumentId
    CloseAnalysisDocument _ _ _ document -> documentKey "snapshot" document
    RequestDocumentAnalysis _ _ _ snapshot -> documentKey "analysis" snapshot.snapshotDocumentId
    ReloadAnalysisConfiguration {} -> "configuration"
    RestartAnalysisWorker -> "restart"
  where
    documentKey :: Text -> DocumentId -> Text
    documentKey kind document = kind <> ":" <> document.unDocumentId
