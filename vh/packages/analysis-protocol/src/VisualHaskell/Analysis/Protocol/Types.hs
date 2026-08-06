{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

module VisualHaskell.Analysis.Protocol.Types
  ( AnalysisCapability (..)
  , ClientHello (..)
  , ClientMessage (..)
  , ProtocolEnvelope (..)
  , ProtocolVersion (..)
  , RequestFailure (..)
  , RequestId (..)
  , TrustMode (..)
  , WorkerHealth (..)
  , WorkerHello (..)
  , WorkerMessage (..)
  , WorkspaceRequest (..)
  , protocolV1
  , protocolEnvelope
  ) where

import Data.Aeson
  ( FromJSON (..)
  , ToJSON (..)
  , object
  , withObject
  , withText
  , (.:)
  , (.:?)
  , (.=)
  )
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word32, Word64)
import VisualHaskell.Semantic

data ProtocolVersion = ProtocolVersion
  { protocolMajor :: !Word32
  , protocolMinor :: !Word32
  }
  deriving stock (Eq, Ord, Show)

protocolV1 :: ProtocolVersion
protocolV1 = ProtocolVersion 1 0

newtype RequestId = RequestId {unRequestId :: Word64}
  deriving stock (Eq, Ord, Show)
  deriving newtype (FromJSON, ToJSON)

data ProtocolEnvelope payload = ProtocolEnvelope
  { envelopeProtocolVersion :: !ProtocolVersion
  , envelopeRequestId :: !(Maybe RequestId)
  , envelopeWorkspace :: !(Maybe WorkspaceId)
  , envelopeWorkspaceGeneration :: !WorkspaceGeneration
  , envelopeSession :: !(Maybe SessionId)
  , envelopeDocument :: !(Maybe DocumentId)
  , envelopeRevision :: !(Maybe TextRevision)
  , envelopeContentHash :: !(Maybe ContentHash)
  , envelopePayload :: !payload
  }
  deriving stock (Eq, Show)

protocolEnvelope :: WorkspaceGeneration -> payload -> ProtocolEnvelope payload
protocolEnvelope generation payload =
  ProtocolEnvelope
    { envelopeProtocolVersion = protocolV1
    , envelopeRequestId = Nothing
    , envelopeWorkspace = Nothing
    , envelopeWorkspaceGeneration = generation
    , envelopeSession = Nothing
    , envelopeDocument = Nothing
    , envelopeRevision = Nothing
    , envelopeContentHash = Nothing
    , envelopePayload = payload
    }

data AnalysisCapability
  = WorkspaceLoadingCapability
  | ComponentDiscoveryCapability
  | FullDocumentSnapshotsCapability
  | DiagnosticsCapability
  | DocumentDeclarationsCapability
  | StructuredTypesCapability
  | SemanticSpansCapability
  | DefinitionLocationsCapability
  | CancellationCapability
  | UnsupportedCapability !Text
  deriving stock (Eq, Ord, Show)

data TrustMode = UntrustedWorkspace | TrustedWorkspace
  deriving stock (Eq, Ord, Show)

data ClientHello = ClientHello
  { clientVersion :: !Text
  , clientRequestedWorkspaceRoot :: !(Maybe FilePath)
  , clientTrustMode :: !TrustMode
  , clientRequestedCapabilities :: ![AnalysisCapability]
  }
  deriving stock (Eq, Show)

data WorkerHello = WorkerHello
  { workerAcceptedProtocol :: !ProtocolVersion
  , workerVersion :: !Text
  , workerCompilerVersion :: !(Maybe CompilerVersion)
  , workerCapabilities :: ![AnalysisCapability]
  , workerMaximumFrameBytes :: !Word32
  }
  deriving stock (Eq, Show)

data WorkspaceRequest = WorkspaceRequest
  { workspaceRequestId :: !WorkspaceId
  , workspaceRequestRoot :: !FilePath
  , workspaceRequestTrust :: !TrustMode
  }
  deriving stock (Eq, Show)

data ClientMessage
  = ClientHelloMessage !ClientHello
  | OpenWorkspace !WorkspaceRequest
  | SelectComponent !ComponentId
  | OpenDocument !DocumentSnapshot
  | UpdateDocumentSnapshot !DocumentSnapshot
  | CloseDocument !DocumentId
  | AnalyzeDocument !DocumentId
  | CancelRequest !RequestId
  | ReloadConfiguration
  | ShutdownWorker
  deriving stock (Eq, Show)

data WorkerHealth
  = WorkerHealthy
  | WorkerDegraded !Text
  deriving stock (Eq, Show)

data RequestFailure = RequestFailure
  { requestFailureCode :: !Text
  , requestFailureMessage :: !Text
  , requestFailureRecoverable :: !Bool
  }
  deriving stock (Eq, Show)

data WorkerMessage
  = WorkerHelloMessage !WorkerHello
  | WorkspaceLoading !WorkspaceId
  | WorkspaceReady !WorkspaceId !SessionId
  | WorkspaceFailed !WorkspaceId !RequestFailure
  | ComponentDiscovered !ComponentInfo
  | ComponentSelected !ComponentInfo
  | AnalysisCompleted !(AnalysisSnapshot RevisionedSourceRange)
  | WorkerRequestFailed !(Maybe RequestId) !RequestFailure
  | WorkerHealthChanged !WorkerHealth
  deriving stock (Eq, Show)

instance ToJSON ProtocolVersion where
  toJSON version = object ["major" .= version.protocolMajor, "minor" .= version.protocolMinor]

instance FromJSON ProtocolVersion where
  parseJSON = withObject "protocol version" $ \value ->
    ProtocolVersion <$> value .: "major" <*> value .: "minor"

instance ToJSON payload => ToJSON (ProtocolEnvelope payload) where
  toJSON envelope = object
    [ "protocol" .= envelope.envelopeProtocolVersion
    , "requestId" .= envelope.envelopeRequestId
    , "workspace" .= envelope.envelopeWorkspace
    , "workspaceGeneration" .= envelope.envelopeWorkspaceGeneration
    , "session" .= envelope.envelopeSession
    , "document" .= envelope.envelopeDocument
    , "revision" .= envelope.envelopeRevision
    , "contentHash" .= envelope.envelopeContentHash
    , "payload" .= envelope.envelopePayload
    ]

instance FromJSON payload => FromJSON (ProtocolEnvelope payload) where
  parseJSON = withObject "protocol envelope" $ \value ->
    ProtocolEnvelope
      <$> value .: "protocol"
      <*> value .:? "requestId"
      <*> value .:? "workspace"
      <*> value .: "workspaceGeneration"
      <*> value .:? "session"
      <*> value .:? "document"
      <*> value .:? "revision"
      <*> value .:? "contentHash"
      <*> value .: "payload"

instance ToJSON AnalysisCapability where
  toJSON capability = toJSON (capabilityText capability)

instance FromJSON AnalysisCapability where
  parseJSON = withText "analysis capability" $ \value ->
    pure $
      maybe
        (UnsupportedCapability value)
        id
        (lookup value [(capabilityText capability, capability) | capability <- allCapabilities])

instance ToJSON TrustMode where
  toJSON mode = toJSON $ case mode of
    UntrustedWorkspace -> ("untrusted" :: Text)
    TrustedWorkspace -> "trusted"

instance FromJSON TrustMode where
  parseJSON = withText "trust mode" $ \value -> case value of
    "untrusted" -> pure UntrustedWorkspace
    "trusted" -> pure TrustedWorkspace
    _ -> fail ("unknown trust mode " <> Text.unpack value)

instance ToJSON ClientHello where
  toJSON hello = object
    [ "clientVersion" .= hello.clientVersion
    , "workspaceRoot" .= hello.clientRequestedWorkspaceRoot
    , "trustMode" .= hello.clientTrustMode
    , "requestedCapabilities" .= hello.clientRequestedCapabilities
    ]

instance FromJSON ClientHello where
  parseJSON = withObject "client hello" $ \value ->
    ClientHello <$> value .: "clientVersion" <*> value .:? "workspaceRoot"
      <*> value .: "trustMode" <*> value .: "requestedCapabilities"

instance ToJSON WorkerHello where
  toJSON hello = object
    [ "acceptedProtocol" .= hello.workerAcceptedProtocol
    , "workerVersion" .= hello.workerVersion
    , "compilerVersion" .= hello.workerCompilerVersion
    , "capabilities" .= hello.workerCapabilities
    , "maximumFrameBytes" .= hello.workerMaximumFrameBytes
    ]

instance FromJSON WorkerHello where
  parseJSON = withObject "worker hello" $ \value ->
    WorkerHello <$> value .: "acceptedProtocol" <*> value .: "workerVersion"
      <*> value .:? "compilerVersion" <*> value .: "capabilities"
      <*> value .: "maximumFrameBytes"

instance ToJSON WorkspaceRequest where
  toJSON request = object
    [ "workspace" .= request.workspaceRequestId
    , "root" .= request.workspaceRequestRoot
    , "trustMode" .= request.workspaceRequestTrust
    ]

instance FromJSON WorkspaceRequest where
  parseJSON = withObject "workspace request" $ \value ->
    WorkspaceRequest <$> value .: "workspace" <*> value .: "root" <*> value .: "trustMode"

instance ToJSON ClientMessage where
  toJSON message = case message of
    ClientHelloMessage hello -> tagged "client-hello" ["hello" .= hello]
    OpenWorkspace request -> tagged "open-workspace" ["workspace" .= request]
    SelectComponent component -> tagged "select-component" ["component" .= component]
    OpenDocument snapshot -> tagged "open-document" ["snapshot" .= snapshot]
    UpdateDocumentSnapshot snapshot -> tagged "update-document" ["snapshot" .= snapshot]
    CloseDocument document -> tagged "close-document" ["document" .= document]
    AnalyzeDocument document -> tagged "analyze-document" ["document" .= document]
    CancelRequest request -> tagged "cancel-request" ["request" .= request]
    ReloadConfiguration -> tagged "reload-configuration" []
    ShutdownWorker -> tagged "shutdown" []
    where tagged messageType fields = object (("type" .= (messageType :: Text)) : fields)

instance FromJSON ClientMessage where
  parseJSON = withObject "client message" $ \value -> do
    messageType <- value .: "type"
    case (messageType :: Text) of
      "client-hello" -> ClientHelloMessage <$> value .: "hello"
      "open-workspace" -> OpenWorkspace <$> value .: "workspace"
      "select-component" -> SelectComponent <$> value .: "component"
      "open-document" -> OpenDocument <$> value .: "snapshot"
      "update-document" -> UpdateDocumentSnapshot <$> value .: "snapshot"
      "close-document" -> CloseDocument <$> value .: "document"
      "analyze-document" -> AnalyzeDocument <$> value .: "document"
      "cancel-request" -> CancelRequest <$> value .: "request"
      "reload-configuration" -> pure ReloadConfiguration
      "shutdown" -> pure ShutdownWorker
      _ -> fail ("unknown client message " <> Text.unpack messageType)

instance ToJSON WorkerHealth where
  toJSON health = case health of
    WorkerHealthy -> object ["status" .= ("healthy" :: Text)]
    WorkerDegraded message -> object ["status" .= ("degraded" :: Text), "message" .= message]

instance FromJSON WorkerHealth where
  parseJSON = withObject "worker health" $ \value -> do
    status <- value .: "status"
    case (status :: Text) of
      "healthy" -> pure WorkerHealthy
      "degraded" -> WorkerDegraded <$> value .: "message"
      _ -> fail ("unknown worker health " <> Text.unpack status)

instance ToJSON RequestFailure where
  toJSON failure = object
    [ "code" .= failure.requestFailureCode
    , "message" .= failure.requestFailureMessage
    , "recoverable" .= failure.requestFailureRecoverable
    ]

instance FromJSON RequestFailure where
  parseJSON = withObject "request failure" $ \value ->
    RequestFailure <$> value .: "code" <*> value .: "message" <*> value .: "recoverable"

instance ToJSON WorkerMessage where
  toJSON message = case message of
    WorkerHelloMessage hello -> tagged "worker-hello" ["hello" .= hello]
    WorkspaceLoading workspace -> tagged "workspace-loading" ["workspace" .= workspace]
    WorkspaceReady workspace session -> tagged "workspace-ready" ["workspace" .= workspace, "session" .= session]
    WorkspaceFailed workspace failure -> tagged "workspace-failed" ["workspace" .= workspace, "failure" .= failure]
    ComponentDiscovered component -> tagged "component-discovered" ["component" .= component]
    ComponentSelected component -> tagged "component-selected" ["component" .= component]
    AnalysisCompleted snapshot -> tagged "analysis-completed" ["snapshot" .= snapshot]
    WorkerRequestFailed request failure -> tagged "request-failed" ["request" .= request, "failure" .= failure]
    WorkerHealthChanged health -> tagged "worker-health" ["health" .= health]
    where tagged messageType fields = object (("type" .= (messageType :: Text)) : fields)

instance FromJSON WorkerMessage where
  parseJSON = withObject "worker message" $ \value -> do
    messageType <- value .: "type"
    case (messageType :: Text) of
      "worker-hello" -> WorkerHelloMessage <$> value .: "hello"
      "workspace-loading" -> WorkspaceLoading <$> value .: "workspace"
      "workspace-ready" -> WorkspaceReady <$> value .: "workspace" <*> value .: "session"
      "workspace-failed" -> WorkspaceFailed <$> value .: "workspace" <*> value .: "failure"
      "component-discovered" -> ComponentDiscovered <$> value .: "component"
      "component-selected" -> ComponentSelected <$> value .: "component"
      "analysis-completed" -> AnalysisCompleted <$> value .: "snapshot"
      "request-failed" -> WorkerRequestFailed <$> value .:? "request" <*> value .: "failure"
      "worker-health" -> WorkerHealthChanged <$> value .: "health"
      _ -> fail ("unknown worker message " <> Text.unpack messageType)

capabilityText :: AnalysisCapability -> Text
capabilityText capability = case capability of
  WorkspaceLoadingCapability -> "workspace-loading"
  ComponentDiscoveryCapability -> "component-discovery"
  FullDocumentSnapshotsCapability -> "full-document-snapshots"
  DiagnosticsCapability -> "diagnostics"
  DocumentDeclarationsCapability -> "document-declarations"
  StructuredTypesCapability -> "structured-types"
  SemanticSpansCapability -> "semantic-spans"
  DefinitionLocationsCapability -> "definition-locations"
  CancellationCapability -> "cancellation"
  UnsupportedCapability name -> name

allCapabilities :: [AnalysisCapability]
allCapabilities =
  [ WorkspaceLoadingCapability, ComponentDiscoveryCapability, FullDocumentSnapshotsCapability, DiagnosticsCapability
  , DocumentDeclarationsCapability, StructuredTypesCapability, SemanticSpansCapability
  , DefinitionLocationsCapability, CancellationCapability
  ]
