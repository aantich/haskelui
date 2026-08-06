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
  , wait
  )
import Control.Concurrent.STM
  ( TQueue
  , TVar
  , atomically
  , modifyTVar'
  , newTQueueIO
  , newTVarIO
  , readTQueue
  , readTVar
  , writeTQueue
  , writeTVar
  )
import Control.Exception
  ( IOException
  , displayException
  , try
  )
import Control.Monad (unless, void, when)
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
  , getProcessExitCode
  , proc
  , terminateProcess
  , waitForProcess
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
    , workerHandshakeTimeoutMicroseconds = 3000000
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
  }

data SupervisorCommand
  = SendCommand !Word64 !(ProtocolEnvelope ClientMessage)
  | RestartCommand
  | StopCommand
  | ProcessExitedCommand !WorkerGeneration !ExitCode
  | ReaderFailedCommand !WorkerGeneration !FrameError
  | WorkerMessageCommand !WorkerGeneration !(ProtocolEnvelope WorkerMessage)
  | WorkerLogCommand !WorkerGeneration !Text

data StoredCommand = StoredCommand
  { storedEnvelope :: !(ProtocolEnvelope ClientMessage)
  }

data ReplayState = ReplayState
  { replayWorkspace :: !(Maybe StoredCommand)
  , replayComponent :: !(Maybe StoredCommand)
  , replayDocuments :: !(Map DocumentId StoredCommand)
  , replayAnalyses :: !(Map DocumentId StoredCommand)
  }

emptyReplayState :: ReplayState
emptyReplayState = ReplayState Nothing Nothing Map.empty Map.empty

data WorkerSession = WorkerSession
  { sessionInput :: !Handle
  , sessionInputLimits :: !FrameLimits
  , sessionOutput :: !Handle
  , sessionError :: !Handle
  , sessionProcess :: !ProcessHandle
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
  supervisor <- async (supervise launch hello emit control replay nextSequence)
  pure
    AnalysisClient
      { analysisControl = control
      , analysisReplay = replay
      , analysisNextSequence = nextSequence
      , analysisSupervisor = supervisor
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
stopAnalysisClient client = atomically (writeTQueue client.analysisControl StopCommand)

waitAnalysisClient :: AnalysisClient -> IO ()
waitAnalysisClient = wait . analysisSupervisor

supervise
  :: WorkerLaunch
  -> ProtocolEnvelope ClientMessage
  -> (AnalysisClientEvent -> IO ())
  -> TQueue SupervisorCommand
  -> TVar ReplayState
  -> TVar Word64
  -> IO ()
supervise launch hello emit control replay nextSequence = do
  loop (WorkerGeneration 1) 0
  where
    loop generation restartCount = do
      emit (AnalysisWorkerStarting generation)
      started <- startWorkerSession launch hello emit control replay nextSequence generation
      case started of
        Left message -> do
          emit (AnalysisWorkerProtocolFailure generation message)
          restartOrStop generation (restartCount + 1)
        Right (session, replayedThrough) ->
          runSession generation restartCount session replayedThrough

    restartOrStop generation attempt
      | attempt > launch.workerMaximumRestarts = emit AnalysisWorkerStopped
      | otherwise = do
          let next = nextWorkerGeneration generation
          emit (AnalysisWorkerRestarting next attempt)
          loop next attempt

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
                  stopWorkerSession session
                  restartOrStop generation (restartCount + 1)
        RestartCommand -> do
          stopWorkerSession session
          restartOrStop generation 1
        StopCommand -> do
          gracefulStop session
          emit AnalysisWorkerStopped
        ProcessExitedCommand eventGeneration exitCode
          | eventGeneration /= generation ->
              runSession generation restartCount session replayedThrough
          | otherwise -> do
              emit (AnalysisWorkerExited generation exitCode)
              stopWorkerSession session
              restartOrStop generation (restartCount + 1)
        ReaderFailedCommand eventGeneration failure
          | eventGeneration /= generation ->
              runSession generation restartCount session replayedThrough
          | otherwise -> do
              unless (failure == FrameEndOfInput) $
                emit (AnalysisWorkerProtocolFailure generation (Text.pack (show failure)))
              stopWorkerSession session
              restartOrStop generation (restartCount + 1)
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
      traverse_ prepareHandle [input, output, errorOutput]
      helloWritten <- writeFrame launch.workerFrameLimits input hello
      case helloWritten of
        Left failure -> startupFailure processHandle [input, output, errorOutput] (Text.pack (show failure))
        Right () -> do
          helloResult <- timeout launch.workerHandshakeTimeoutMicroseconds (readFrame launch.workerFrameLimits output)
          case validateHello helloResult of
            Left failure -> startupFailure processHandle [input, output, errorOutput] failure
            Right workerHello -> do
              let inputLimits =
                    FrameLimits
                      (min launch.workerFrameLimits.maximumFrameBytes workerHello.workerMaximumFrameBytes)
              reader <- async (readerLoop launch.workerFrameLimits control generation output)
              logger <- async (logLoop control generation errorOutput)
              watcher <- async (waitForProcess processHandle >>= atomically . writeTQueue control . ProcessExitedCommand generation)
              let session =
                    WorkerSession
                      input
                      inputLimits
                      output
                      errorOutput
                      processHandle
                      reader
                      logger
                      watcher
              (replayState, replayedThrough) <- atomically ((,) <$> readTVar replay <*> readTVar nextSequence)
              replayResult <- replayCommands inputLimits input replayState
              case replayResult of
                Left failure -> do
                  stopWorkerSession session
                  pure (Left failure)
                Right () -> do
                  emit (AnalysisWorkerReady generation workerHello)
                  pure (Right (session, replayedThrough))
    Right _ -> pure (Left "worker process did not expose all three standard streams")
  where
    processSpec =
      (proc launch.workerExecutable launch.workerArguments)
        { cwd = launch.workerWorkingDirectory
        , env = launch.workerEnvironment
        , std_in = CreatePipe
        , std_out = CreatePipe
        , std_err = CreatePipe
        }

validateHello
  :: Maybe (Either FrameError (ProtocolEnvelope WorkerMessage))
  -> Either Text WorkerHello
validateHello Nothing = Left "worker handshake timed out"
validateHello (Just (Left failure)) = Left ("worker handshake failed: " <> Text.pack (show failure))
validateHello (Just (Right envelope))
  | envelope.envelopeProtocolVersion.protocolMajor /= protocolV1.protocolMajor =
      Left "worker envelope uses an incompatible protocol major"
  | WorkerHelloMessage hello <- envelope.envelopePayload
  , hello.workerAcceptedProtocol.protocolMajor == protocolV1.protocolMajor
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
  catMaybes [replayState.replayWorkspace, replayState.replayComponent]
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
retainForReplay stored replayState =
  case stored.storedEnvelope.envelopePayload of
    OpenWorkspace _ ->
      ReplayState (Just stored) Nothing Map.empty Map.empty
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
      replayState {replayAnalyses = Map.insert document stored replayState.replayAnalyses}
    _ -> replayState

replayManaged :: ClientMessage -> Bool
replayManaged message =
  case message of
    OpenWorkspace _ -> True
    SelectComponent _ -> True
    OpenDocument _ -> True
    UpdateDocumentSnapshot _ -> True
    CloseDocument _ -> True
    AnalyzeDocument _ -> True
    _ -> False

gracefulStop :: WorkerSession -> IO ()
gracefulStop session = do
  let shutdown = protocolEnvelope (WorkspaceGeneration 0) ShutdownWorker
  void (writeFrame session.sessionInputLimits session.sessionInput shutdown)
  exited <- timeout 500000 (waitForProcess session.sessionProcess)
  when (exited == Nothing) (terminateProcess session.sessionProcess)
  stopWorkerSession session

stopWorkerSession :: WorkerSession -> IO ()
stopWorkerSession session = do
  traverse_ cancel [session.sessionReader, session.sessionLogger, session.sessionWatcher]
  exitCode <- getProcessExitCode session.sessionProcess
  when (exitCode == Nothing) $ do
    terminateProcess session.sessionProcess
    void (waitForProcess session.sessionProcess)
  traverse_ closeIgnoring [session.sessionInput, session.sessionOutput, session.sessionError]

startupFailure
  :: ProcessHandle
  -> [Handle]
  -> Text
  -> IO (Either Text value)
startupFailure processHandle handles message = do
  terminateProcess processHandle
  void (waitForProcess processHandle)
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
