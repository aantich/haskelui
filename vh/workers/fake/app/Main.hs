{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import qualified Data.Map.Strict as Map
import Data.Map.Strict (Map)
import qualified Data.Text as Text
import System.Directory (doesFileExist)
import System.Environment (getArgs)
import System.Exit (exitFailure)
import System.IO
  ( BufferMode (NoBuffering)
  , hPutStrLn
  , hSetBinaryMode
  , hSetBuffering
  , stderr
  , stdin
  , stdout
  )
import VisualHaskell.Analysis.Protocol
import VisualHaskell.Semantic

data WorkerState = WorkerState
  { workerWorkspace :: !(Maybe WorkspaceId)
  , workerSession :: !(Maybe SessionId)
  , workerDocuments :: !(Map DocumentId DocumentSnapshot)
  }

data FakeConfiguration = FakeConfiguration
  { crashOnceMarker :: !(Maybe FilePath)
  }

main :: IO ()
main = do
  configuration <- parseArguments <$> getArgs
  hSetBinaryMode stdin True
  hSetBinaryMode stdout True
  hSetBuffering stdout NoBuffering
  first <- readFrame defaultFrameLimits stdin
  case first of
    Right envelope@(ProtocolEnvelope {envelopePayload = ClientHelloMessage _}) -> do
      send envelope $ WorkerHelloMessage
        WorkerHello
          { workerAcceptedProtocol = protocolV1
          , workerVersion = "visual-haskell-fake-worker/0.1.0"
          , workerCompilerVersion = Nothing
          , workerCapabilities =
              [ WorkspaceLoadingCapability
              , FullDocumentSnapshotsCapability
              , DiagnosticsCapability
              , DocumentDeclarationsCapability
              , StructuredTypesCapability
              , CancellationCapability
              ]
          , workerMaximumFrameBytes = maximumFrameBytes defaultFrameLimits
          }
      loop configuration (WorkerState Nothing Nothing Map.empty)
    Right _ -> failWorker "first frame was not ClientHello"
    Left failure -> failWorker ("could not read ClientHello: " <> show failure)

loop :: FakeConfiguration -> WorkerState -> IO ()
loop configuration state = do
  incoming <- readFrame defaultFrameLimits stdin
  case incoming of
    Left FrameEndOfInput -> pure ()
    Left failure -> failWorker ("protocol read failed: " <> show failure)
    Right envelope ->
      case envelope.envelopePayload of
        ClientHelloMessage _ -> do
          sendFailure envelope "duplicate-client-hello" "ClientHello may only be sent once"
          loop configuration state
        OpenWorkspace request -> do
          let session = SessionId ("fake:" <> request.workspaceRequestId.unWorkspaceId)
              updated = WorkerState (Just request.workspaceRequestId) (Just session) Map.empty
          send envelope (WorkspaceLoading request.workspaceRequestId)
          send envelope (WorkspaceReady request.workspaceRequestId session)
          loop configuration updated
        SelectComponent _ -> do
          sendFailure envelope "component-selection-unsupported" "The deterministic fake worker has no project components"
          loop configuration state
        OpenDocument snapshot -> loop configuration state {workerDocuments = Map.insert snapshot.snapshotDocumentId snapshot state.workerDocuments}
        UpdateDocumentSnapshot snapshot -> loop configuration state {workerDocuments = Map.insert snapshot.snapshotDocumentId snapshot state.workerDocuments}
        CloseDocument document -> loop configuration state {workerDocuments = Map.delete document state.workerDocuments}
        AnalyzeDocument document -> do
          crashIfRequested configuration
          case (state.workerWorkspace, state.workerSession, Map.lookup document state.workerDocuments) of
            (Just workspace, Just session, Just snapshot) ->
              send envelope (AnalysisCompleted (analyze workspace session envelope.envelopeWorkspaceGeneration snapshot))
            _ -> sendFailure envelope "document-unavailable" "Document is not open in a ready workspace"
          loop configuration state
        CancelRequest _ -> loop configuration state
        ReloadConfiguration -> do
          send envelope (WorkerHealthChanged WorkerHealthy)
          loop configuration state
        ShutdownWorker -> pure ()

parseArguments :: [String] -> FakeConfiguration
parseArguments ["--crash-once", marker] = FakeConfiguration (Just marker)
parseArguments _ = FakeConfiguration Nothing

crashIfRequested :: FakeConfiguration -> IO ()
crashIfRequested configuration =
  case configuration.crashOnceMarker of
    Nothing -> pure ()
    Just marker -> do
      alreadyCrashed <- doesFileExist marker
      if alreadyCrashed
        then pure ()
        else do
          writeFile marker "visual-haskell fake worker crashed once\n"
          hPutStrLn stderr "forced one-shot fake-worker crash"
          exitFailure

analyze
  :: WorkspaceId
  -> SessionId
  -> WorkspaceGeneration
  -> DocumentSnapshot
  -> AnalysisSnapshot RevisionedSourceRange
analyze _workspace session generation snapshot =
  AnalysisSnapshot
    { analysisWorkspaceGeneration = generation
    , analysisSession = session
    , analysisDocument = snapshot.snapshotDocumentId
    , analysisRevision = snapshot.snapshotRevision
    , analysisContentHash = snapshot.snapshotContentHash
    , analysisCompleteness = Typechecked
    , analysisFreshness = CurrentAnalysis
    , analysisDiagnostics = diagnostics
    , analysisDeclarations = [declaration]
    , analysisTypes = Map.fromList [(typeId, FunctionType argumentType resultType), (argumentType, TypeConstructor "Text"), (resultType, TypeConstructor "IO")]
    }
  where
    lineLength = Text.length (Text.takeWhile (/= '\n') snapshot.snapshotText)
    wholeLine =
      RevisionedSourceRange
        snapshot.snapshotRevision
        (SourcePosition 0 0 UnicodeScalarColumn)
        (SourcePosition 0 lineLength UnicodeScalarColumn)
    declaration =
      Declaration
        { declarationId = DeclarationId "fake:main"
        , declarationName = "main"
        , declarationKind = ValueDeclaration
        , declarationRange = wholeLine
        , declarationSelectionRange = wholeLine
        , declarationType = Just typeId
        , declarationSignatureText = Just "main :: Text -> IO"
        , declarationTypeSemantics = Nothing
        }
    diagnostics =
      [ Diagnostic
          { diagnosticId = DiagnosticId "fake:error"
          , diagnosticSeverity = DiagnosticError
          , diagnosticSource = "fake-worker"
          , diagnosticCode = Just "FAKE001"
          , diagnosticMessage = "Fixture requested a diagnostic"
          , diagnosticRange = wholeLine
          , diagnosticRelated = []
          }
      | "ERROR" `Text.isInfixOf` snapshot.snapshotText
      ]
    typeId = TypeId "fake:main-type"
    argumentType = TypeId "fake:text"
    resultType = TypeId "fake:io"

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
          , envelopeSession = incoming.envelopeSession
          , envelopeDocument = incoming.envelopeDocument
          , envelopeRevision = incoming.envelopeRevision
          , envelopeContentHash = incoming.envelopeContentHash
          , envelopePayload = payload
          }
  result <- writeFrame defaultFrameLimits stdout outgoing
  case result of
    Right () -> pure ()
    Left failure -> failWorker ("protocol write failed: " <> show failure)

sendFailure :: ProtocolEnvelope ClientMessage -> Text.Text -> Text.Text -> IO ()
sendFailure envelope code message =
  send envelope (WorkerRequestFailed envelope.envelopeRequestId (RequestFailure code message True))

failWorker :: String -> IO value
failWorker message = hPutStrLn stderr message >> exitFailure
