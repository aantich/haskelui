{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module VisualHaskell.Analysis.Client
  ( AnalysisClient
  , AnalysisClientEvent (..)
  , WorkerGeneration (..)
  , WorkerLaunch (..)
  , defaultWorkerLaunch
  , restartAnalysisWorker
  , sendAnalysisMessage
  , startAnalysisClient
  , stopAnalysisClient
  , waitAnalysisClient
  ) where

import Control.Concurrent.Async
  ( Async
  , async
  , cancel
  , race_
  , wait
  )
import Control.Concurrent.STM
  ( TQueue
  , TMVar
  , TVar
  , atomically
  , modifyTVar'
  , newTQueueIO
  , newEmptyTMVarIO
  , newTVarIO
  , readTQueue
  , readTVar
  , readTMVar
  , tryPutTMVar
  , writeTQueue
  , writeTVar
  )
import Control.Exception
  ( IOException
  , displayException
  , finally
  , mask
  , onException
  , try
  )
import Control.Concurrent (threadDelay)
import System.Posix.Signals (signalProcessGroup, sigTERM, sigKILL)
import System.Posix.Types (ProcessID)
import Control.Monad (unless, void)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Char8 as ByteStringChar8
import qualified Data.Map.Strict as Map
import Data.Map.Strict (Map)
import Data.Maybe (catMaybes)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import Data.Text.Encoding.Error (lenientDecode)
import Data.Word (Word64)
import System.Exit (ExitCode)
import System.IO
  ( BufferMode (NoBuffering)
  , Handle
  , hClose
  , hSetBinaryMode
  , hSetBuffering
  )
import System.Process
  ( CreateProcess (..)
  , ProcessHandle
  , StdStream (CreatePipe)
  , createProcess
  , proc
  , terminateProcess
  , waitForProcess
  , getPid
  )
import System.Timeout (timeout)
import VisualHaskell.Analysis.Protocol
import VisualHaskell.Semantic

newtype WorkerGeneration = WorkerGeneration {unWorkerGeneration :: Word64}
  deriving stock (Eq, Ord, Show)

data WorkerLaunch = WorkerLaunch
  { workerExecutable :: !FilePath
  , workerArguments :: ![String]
  , workerWorkingDirectory :: !(Maybe FilePath)
  , workerEnvironment :: !(Maybe [(String, String)])
  , workerHandshakeTimeoutMicroseconds :: !Int
  , workerShutdownTimeoutMicroseconds :: !Int
  , workerMaximumRestarts :: !Int
  , workerFrameLimits :: !FrameLimits
  }
  deriving stock (Eq, Show)

defaultWorkerLaunch :: FilePath -> WorkerLaunch
defaultWorkerLaunch executable =
  WorkerLaunch
    { workerExecutable = executable
    , workerArguments = []
    , workerWorkingDirectory = Nothing
    , workerEnvironment = Nothing
    -- Cold GHC/dyld startup can exceed three seconds while another compiler
    -- is building. This remains bounded and cancellation bypasses the wait.
    , workerHandshakeTimeoutMicroseconds = 10000000
    , workerShutdownTimeoutMicroseconds = 500000
    , workerMaximumRestarts = 3
    , workerFrameLimits = defaultFrameLimits
    }

data AnalysisClientEvent
  = AnalysisWorkerStarting !WorkerGeneration
  | AnalysisWorkerReady !WorkerGeneration !WorkerHello
  | AnalysisWorkerMessage !WorkerGeneration !(ProtocolEnvelope WorkerMessage)
  | AnalysisWorkerLog !WorkerGeneration !Text
  | AnalysisWorkerProtocolFailure !WorkerGeneration !Text
  | AnalysisWorkerExited !WorkerGeneration !ExitCode
  | AnalysisWorkerRestarting !WorkerGeneration !Int
  | AnalysisWorkerStopped
  deriving stock (Eq, Show)

data AnalysisClient = AnalysisClient
  { analysisControl :: !(TQueue SupervisorCommand)
  , analysisReplay :: !(TVar ReplayState)
  , analysisNextSequence :: !(TVar Word64)
  , analysisSupervisor :: !(Async ())
  , analysisStopSignal :: !(TMVar ())
  }

data SupervisorCommand
  = SendCommand !Word64 !(ProtocolEnvelope ClientMessage)
  | RestartCommand
  | ProcessExitedCommand !WorkerGeneration !ExitCode
  | ReaderFailedCommand !WorkerGeneration !FrameError
  | WorkerMessageCommand !WorkerGeneration !(ProtocolEnvelope WorkerMessage)
  | WorkerLogCommand !WorkerGeneration !Text

data StoredCommand = StoredCommand
  { storedEnvelope :: !(ProtocolEnvelope ClientMessage)
  }

data ReplayState = ReplayState
  { replayWorkspace :: !(Maybe StoredCommand)
  , replayCompiler :: !(Maybe StoredCommand)
  , replayProject :: !(Maybe StoredCommand)
  , replayComponent :: !(Maybe StoredCommand)
  , replayDocuments :: !(Map DocumentId StoredCommand)
  , replayAnalyses :: !(Map DocumentId StoredCommand)
  }

emptyReplayState :: ReplayState
emptyReplayState = ReplayState Nothing Nothing Nothing Nothing Map.empty Map.empty

data WorkerSession = WorkerSession
  { sessionInput :: !Handle
  , sessionInputLimits :: !FrameLimits
  , sessionShutdownTimeout :: !Int
  , sessionOutput :: !Handle
  , sessionError :: !Handle
  , sessionProcess :: !ProcessHandle
  , sessionProcessGroup :: !(Maybe ProcessID)
  , sessionReader :: !(Async ())
  , sessionLogger :: !(Async ())
  , sessionWatcher :: !(Async ())
  }

startAnalysisClient
  :: WorkerLaunch
  -> ProtocolEnvelope ClientMessage
  -> (AnalysisClientEvent -> IO ())
  -> IO AnalysisClient
startAnalysisClient launch hello emit = do
  control <- newTQueueIO
  replay <- newTVarIO emptyReplayState
  nextSequence <- newTVarIO 0
  stopSignal <- newEmptyTMVarIO
  supervisor <- async (supervise launch hello emit control replay nextSequence stopSignal)
  pure
    AnalysisClient
      { analysisControl = control
      , analysisReplay = replay
      , analysisNextSequence = nextSequence
      , analysisSupervisor = supervisor
      , analysisStopSignal = stopSignal
      }

sendAnalysisMessage :: AnalysisClient -> ProtocolEnvelope ClientMessage -> IO ()
sendAnalysisMessage client envelope =
  atomically $ do
    sequenceNumber <- readTVar client.analysisNextSequence
    let next = sequenceNumber + 1
        stored = StoredCommand envelope
    writeTVar client.analysisNextSequence next
    modifyTVar' client.analysisReplay (retainForReplay stored)
    writeTQueue client.analysisControl (SendCommand next envelope)

restartAnalysisWorker :: AnalysisClient -> IO ()
restartAnalysisWorker client = atomically (writeTQueue client.analysisControl RestartCommand)

stopAnalysisClient :: AnalysisClient -> IO ()
-- Stopping must not wait behind a pipe write to an unresponsive compiler.
stopAnalysisClient client = atomically (void (tryPutTMVar client.analysisStopSignal ()))

waitAnalysisClient :: AnalysisClient -> IO ()
waitAnalysisClient = wait . analysisSupervisor

supervise
  :: WorkerLaunch
  -> ProtocolEnvelope ClientMessage
  -> (AnalysisClientEvent -> IO ())
  -> TQueue SupervisorCommand
  -> TVar ReplayState
  -> TVar Word64
  -> TMVar ()
  -> IO ()
supervise launch hello emit control replay nextSequence stopSignal = do
  race_ (atomically (readTMVar stopSignal)) (loop (WorkerGeneration 1) 0)
  emit AnalysisWorkerStopped
  where
    loop generation restartCount = do
      emit (AnalysisWorkerStarting generation)
      -- Acquire under a mask and establish cleanup before unmasking work.
      -- Startup also cleans up if cancellation interrupts handshake/replay.
      outcome <- mask $ \restore -> do
        started <- startWorkerSession launch hello emit control replay nextSequence generation
        case started of
          Left message -> pure (Left message)
          Right (session, replayedThrough) -> Right <$>
            (restore (runSession generation restartCount session replayedThrough)
              `finally` stopWorkerSession session)
      case outcome of
        Left message -> do
          emit (AnalysisWorkerProtocolFailure generation message)
          restartOrStop generation (restartCount + 1)
        Right attempt -> restartOrStop generation attempt

    restartOrStop generation attempt
      | attempt > launch.workerMaximumRestarts = pure ()
      | otherwise = do
          let next = nextWorkerGeneration generation
          emit (AnalysisWorkerRestarting next attempt)
          loop next attempt

    runSession :: WorkerGeneration -> Int -> WorkerSession -> Word64 -> IO Int
    runSession generation restartCount session replayedThrough = do
      command <- atomically (readTQueue control)
      case command of
        SendCommand sequenceNumber envelope
          | sequenceNumber <= replayedThrough
          , replayManaged envelope.envelopePayload ->
              runSession generation restartCount session replayedThrough
          | otherwise -> do
              written <- writeFrame session.sessionInputLimits session.sessionInput envelope
              case written of
                Right () -> runSession generation restartCount session (max replayedThrough sequenceNumber)
                Left failure -> do
                  emit (AnalysisWorkerProtocolFailure generation (Text.pack (show failure)))
                  pure (restartCount + 1)
        RestartCommand -> pure 1
        ProcessExitedCommand eventGeneration exitCode
          | eventGeneration /= generation ->
              runSession generation restartCount session replayedThrough
          | otherwise -> do
              emit (AnalysisWorkerExited generation exitCode)
              pure (restartCount + 1)
        ReaderFailedCommand eventGeneration failure
          | eventGeneration /= generation ->
              runSession generation restartCount session replayedThrough
          | otherwise -> do
              unless (failure == FrameEndOfInput) $
                emit (AnalysisWorkerProtocolFailure generation (Text.pack (show failure)))
              pure (restartCount + 1)
        WorkerMessageCommand eventGeneration envelope
          | eventGeneration == generation -> do
              emit (AnalysisWorkerMessage generation envelope)
              runSession generation restartCount session replayedThrough
          | otherwise -> runSession generation restartCount session replayedThrough
        WorkerLogCommand eventGeneration message
          | eventGeneration == generation -> do
              emit (AnalysisWorkerLog generation message)
              runSession generation restartCount session replayedThrough
          | otherwise -> runSession generation restartCount session replayedThrough

startWorkerSession
  :: WorkerLaunch
  -> ProtocolEnvelope ClientMessage
  -> (AnalysisClientEvent -> IO ())
  -> TQueue SupervisorCommand
  -> TVar ReplayState
  -> TVar Word64
  -> WorkerGeneration
  -> IO (Either Text (WorkerSession, Word64))
startWorkerSession launch hello emit control replay nextSequence generation = do
  created <- try (createProcess processSpec)
  case created of
    Left exception -> pure (Left (Text.pack (displayException (exception :: IOException))))
    Right (Just input, Just output, Just errorOutput, processHandle) -> do
      group <- getPid processHandle
      let handles = [input, output, errorOutput]
          initialize = do
            traverse_ prepareHandle handles
            helloWritten <- writeFrame launch.workerFrameLimits input hello
            case helloWritten of
              Left failure -> startupFailure group processHandle handles (Text.pack (show failure))
              Right () -> do
                helloResult <- timeout launch.workerHandshakeTimeoutMicroseconds (readFrame launch.workerFrameLimits output)
                case validateHello helloResult of
                  Left failure -> startupFailure group processHandle handles failure
                  Right workerHello -> do
                    let inputLimits = FrameLimits
                          (min launch.workerFrameLimits.maximumFrameBytes workerHello.workerMaximumFrameBytes)
                    reader <- async (readerLoop launch.workerFrameLimits control generation output)
                    logger <- async (logLoop control generation errorOutput)
                    watcher <- async (waitForProcess processHandle >>= atomically . writeTQueue control . ProcessExitedCommand generation)
                    let session = WorkerSession input inputLimits launch.workerShutdownTimeoutMicroseconds output errorOutput processHandle group reader logger watcher
                    (replayState, replayedThrough) <- atomically ((,) <$> readTVar replay <*> readTVar nextSequence)
                    replayResult <- replayCommands inputLimits input replayState
                    case replayResult of
                      Left failure -> do
                        stopWorkerSession session
                        pure (Left failure)
                      Right () -> do
                        emit (AnalysisWorkerReady generation workerHello)
                        pure (Right (session, replayedThrough))
      initialize `onException` (stopProcessGroup group processHandle >> traverse_ closeIgnoring handles)
    Right _ -> pure (Left "worker process did not expose all three standard streams")
  where
    processSpec =
      (proc launch.workerExecutable launch.workerArguments)
        { cwd = launch.workerWorkingDirectory
        , env = launch.workerEnvironment
        , std_in = CreatePipe
        , std_out = CreatePipe
        , std_err = CreatePipe
        , create_group = True
        }

validateHello
  :: Maybe (Either FrameError (ProtocolEnvelope WorkerMessage))
  -> Either Text WorkerHello
validateHello Nothing = Left "worker handshake timed out"
validateHello (Just (Left failure)) = Left ("worker handshake failed: " <> Text.pack (show failure))
validateHello (Just (Right envelope))
  | envelope.envelopeProtocolVersion.protocolMajor /= protocolV2.protocolMajor =
      Left "worker envelope uses an incompatible protocol major"
  | WorkerHelloMessage hello <- envelope.envelopePayload
  , hello.workerAcceptedProtocol.protocolMajor == protocolV2.protocolMajor
  , hello.workerMaximumFrameBytes > 0 = Right hello
  | otherwise = Left "worker did not return a compatible WorkerHello"

replayCommands :: FrameLimits -> Handle -> ReplayState -> IO (Either Text ())
replayCommands limits input replayState = go (replayCommandList replayState)
  where
    go :: [StoredCommand] -> IO (Either Text ())
    go [] = pure (Right ())
    go (stored : remaining) = do
      result <- writeFrame limits input (prepareForReplay stored.storedEnvelope)
      case result of
        Left failure -> pure (Left ("snapshot replay failed: " <> Text.pack (show failure)))
        Right () -> go remaining

replayCommandList :: ReplayState -> [StoredCommand]
replayCommandList replayState =
  catMaybes [replayState.replayWorkspace, replayState.replayCompiler, replayState.replayProject, replayState.replayComponent]
    <> Map.elems replayState.replayDocuments
    <> Map.elems replayState.replayAnalyses

prepareForReplay :: ProtocolEnvelope ClientMessage -> ProtocolEnvelope ClientMessage
prepareForReplay envelope =
  envelope
    { envelopeRequestId = Nothing
    , envelopeSession = Nothing
    }

readerLoop
  :: FrameLimits
  -> TQueue SupervisorCommand
  -> WorkerGeneration
  -> Handle
  -> IO ()
readerLoop limits control generation output = loop
  where
    loop = do
      result <- readFrame limits output
      case result of
        Left failure -> atomically (writeTQueue control (ReaderFailedCommand generation failure))
        Right envelope -> do
          atomically (writeTQueue control (WorkerMessageCommand generation envelope))
          loop

logLoop
  :: TQueue SupervisorCommand
  -> WorkerGeneration
  -> Handle
  -> IO ()
logLoop control generation errorOutput = loop
  where
    loop = do
      attempted <- try (ByteStringChar8.hGetLine errorOutput)
      case attempted of
        Left (_ :: IOException) -> pure ()
        Right bytes
          | ByteString.null bytes -> pure ()
          | otherwise -> do
              atomically $
                writeTQueue control
                  (WorkerLogCommand generation (TextEncoding.decodeUtf8With lenientDecode bytes))
              loop

retainForReplay :: StoredCommand -> ReplayState -> ReplayState
retainForReplay stored replayState
  | Just current <- replayState.replayWorkspace
  , stored.storedEnvelope.envelopeWorkspaceGeneration < current.storedEnvelope.envelopeWorkspaceGeneration = replayState
  | otherwise = case stored.storedEnvelope.envelopePayload of
    OpenWorkspace request
      | Just current <- replayState.replayWorkspace
      , current.storedEnvelope.envelopePayload == OpenWorkspace request
      , current.storedEnvelope.envelopeWorkspaceGeneration == stored.storedEnvelope.envelopeWorkspaceGeneration ->
          replayState {replayWorkspace = Just stored}
    OpenWorkspace _ ->
      ReplayState (Just stored) Nothing Nothing Nothing Map.empty Map.empty
    SelectCompiler _ -> replayState {replayCompiler = Just stored, replayComponent = Nothing}
    DiscoverProject _ -> replayState {replayProject = Just stored}
    PrepareComponent _ -> replayState {replayComponent = Just stored}
    ConfigureContext _ -> replayState {replayComponent = Just stored}
    SelectComponent _ ->
      replayState {replayComponent = Just stored}
    OpenDocument snapshot ->
      replayState
        { replayDocuments = Map.insert snapshot.snapshotDocumentId stored replayState.replayDocuments
        }
    UpdateDocumentSnapshot snapshot ->
      replayState
        { replayDocuments =
            Map.insert
              snapshot.snapshotDocumentId
              stored
                { storedEnvelope =
                    stored.storedEnvelope
                      { envelopePayload = OpenDocument snapshot
                      }
                }
              replayState.replayDocuments
        }
    CloseDocument document ->
      replayState
        { replayDocuments = Map.delete document replayState.replayDocuments
        , replayAnalyses = Map.delete document replayState.replayAnalyses
        }
    AnalyzeDocument document ->
      replayState {replayAnalyses = Map.singleton document stored}
    CancelRequest _ -> replayState {replayAnalyses = Map.empty, replayComponent = Nothing}
    _ -> replayState

replayManaged :: ClientMessage -> Bool
replayManaged message =
  case message of
    DiscoverProject _ -> True
    SelectCompiler _ -> True
    ConfigureContext _ -> True
    PrepareComponent _ -> True
    OpenWorkspace _ -> True
    SelectComponent _ -> True
    OpenDocument _ -> True
    UpdateDocumentSnapshot _ -> True
    CloseDocument _ -> True
    AnalyzeDocument _ -> True
    _ -> False

stopWorkerSession :: WorkerSession -> IO ()
stopWorkerSession session = do
  -- The serial writer has already been interrupted. Give a responsive
  -- coordinator a bounded chance to clean up its independently grouped tools;
  -- an unresponsive compiler must not block this cleanup on a protocol write.
  void $ timeout session.sessionShutdownTimeout $ do
    written <- writeFrame session.sessionInputLimits session.sessionInput
      (protocolEnvelope (WorkspaceGeneration 0) ShutdownWorker)
    case written of Right () -> void (waitForProcess session.sessionProcess); Left _ -> pure ()
  -- Kill before closing handles/cancelling readers. Startup failures use the
  -- same group cleanup even if no usable protocol session was established.
  stopProcessGroup session.sessionProcessGroup session.sessionProcess
  traverse_ cancel [session.sessionReader, session.sessionLogger, session.sessionWatcher]
  traverse_ closeIgnoring [session.sessionInput, session.sessionOutput, session.sessionError]

stopProcessGroup :: Maybe ProcessID -> ProcessHandle -> IO ()
stopProcessGroup group processHandle = do
  let signal sig = case group of
        Nothing -> void (try (terminateProcess processHandle) :: IO (Either IOException ()))
        Just identifier -> void (try (signalProcessGroup sig identifier) :: IO (Either IOException ()))
  signal sigTERM
  threadDelay 50000
  signal sigKILL
  void (timeout 1000000 (waitForProcess processHandle))

startupFailure
  :: Maybe ProcessID
  -> ProcessHandle
  -> [Handle]
  -> Text
  -> IO (Either Text value)
startupFailure group processHandle handles message = do
  stopProcessGroup group processHandle
  traverse_ closeIgnoring handles
  pure (Left message)

prepareHandle :: Handle -> IO ()
prepareHandle handle = hSetBinaryMode handle True >> hSetBuffering handle NoBuffering

closeIgnoring :: Handle -> IO ()
closeIgnoring handle = void (try (hClose handle) :: IO (Either IOException ()))

nextWorkerGeneration :: WorkerGeneration -> WorkerGeneration
nextWorkerGeneration (WorkerGeneration generation) = WorkerGeneration (generation + 1)

traverse_ :: Applicative f => (value -> f ()) -> [value] -> f ()
traverse_ action = foldr ((*>) . action) (pure ())
