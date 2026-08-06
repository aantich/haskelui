{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module HaskeLUI.Runtime
  ( Backend (..)
  , BackendSession (..)
  , RuntimeOptions (..)
  , defaultRuntimeOptions
  , runApp
  , runAppWith
  ) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async
  ( Async
  , AsyncCancelled
  , async
  , cancel
  , waitCatch
  )
import Control.Concurrent.STM
  ( STM
  , TBQueue
  , TQueue
  , TVar
  , atomically
  , check
  , flushTBQueue
  , isEmptyTQueue
  , isFullTBQueue
  , newTBQueueIO
  , newTQueueIO
  , newTVarIO
  , readTBQueue
  , readTVar
  , tryReadTQueue
  , writeTBQueue
  , writeTQueue
  , writeTVar
  )
import Control.Exception
  ( AsyncException
  , IOException
  , SomeException
  , bracket
  , bracketOnError
  , displayException
  , finally
  , fromException
  , throwIO
  , try
  )
import Control.Monad
  ( forM
  , forM_
  , unless
  , void
  , when
  )
import qualified Data.ByteString as ByteString
import Data.Foldable (traverse_)
import Data.IORef
  ( IORef
  , atomicModifyIORef'
  , modifyIORef'
  , newIORef
  , readIORef
  , writeIORef
  )
import Data.List (sortOn)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (catMaybes, isJust)
import Data.Set (Set)
import qualified Data.Set as Set
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import Data.Typeable (Typeable, cast)
import Data.Word (Word64)
import System.Directory
  ( doesDirectoryExist
  , doesFileExist
  , listDirectory
  , removeFile
  , renameFile
  )
import System.FilePath
  ( (</>)
  , normalise
  , takeDirectory
  , takeFileName
  )
import System.IO
  ( Handle
  , hClose
  , hFlush
  , openBinaryTempFile
  )
import System.Timeout (timeout)
import HaskeLUI.Core

-- | A backend normalizes native callbacks to 'UIEvent' and provides a
-- platform-thread scheduler. Backends must run scheduled actions serially on
-- the same UI thread that owns rendering.
newtype Backend = Backend
  { openBackend :: (UIEvent -> IO ()) -> IO BackendSession
  }

data BackendSession = BackendSession
  { backendRender :: AppView -> IO ()
  , backendScheduleOnUI :: IO () -> IO ()
  , backendRequestOpenTextFiles :: IO ()
  , backendRequestOpenProjectFolder :: IO ()
  , backendRun :: IO ()
  , backendStop :: IO ()
  , backendShutdown :: IO ()
  }

data RuntimeOptions = RuntimeOptions
  { runtimeMaximumBatchSize :: !Int
  , runtimeShutdownGraceMilliseconds :: !Word64
  , runtimeTraceSink :: !TraceSink
  }

-- Trace destinations are operational capabilities, not configuration
-- identity. Equality and rendering deliberately compare/show only policy.
instance Eq RuntimeOptions where
  left == right =
    left.runtimeMaximumBatchSize == right.runtimeMaximumBatchSize
      && left.runtimeShutdownGraceMilliseconds == right.runtimeShutdownGraceMilliseconds

instance Show RuntimeOptions where
  show options =
    "RuntimeOptions {runtimeMaximumBatchSize = "
      <> show options.runtimeMaximumBatchSize
      <> ", runtimeShutdownGraceMilliseconds = "
      <> show options.runtimeShutdownGraceMilliseconds
      <> ", runtimeTraceSink = <trace-sink>}"

defaultRuntimeOptions :: RuntimeOptions
defaultRuntimeOptions =
  RuntimeOptions
    { runtimeMaximumBatchSize = 128
    , runtimeShutdownGraceMilliseconds = 2000
    , runtimeTraceSink = noTrace
    }

runtimeTrace :: RuntimeOptions -> TraceSeverity -> Text.Text -> [(Text.Text, Text.Text)] -> IO ()
runtimeTrace options severity operation =
  trace options.runtimeTraceSink severity "haskelui.runtime" operation

traceRuntime :: Runtime model -> TraceSeverity -> Text.Text -> [(Text.Text, Text.Text)] -> IO ()
traceRuntime runtime = runtimeTrace runtime.runtimeOptions

countText :: [value] -> Text.Text
countText = Text.pack . show . length

data EventSource
  = RuntimeSource
  | TaskSource !TaskKey !RuntimeGeneration !TaskScope
  | ServiceSource !ServiceKey !RuntimeGeneration
  | SubscriptionSource !SubscriptionKey !RuntimeGeneration

data RuntimeEnvelope model
  = BackendEnvelope !UIEvent
  | ExternalEnvelope !EventSource !(ExternalEvent model)
  | ServiceExitedEnvelope !ServiceKey !RuntimeGeneration !ServiceExit
  | RestartServiceEnvelope !ServiceKey !RuntimeGeneration !Int

data QueuedEnvelope model
  = QueuedDirect !(RuntimeEnvelope model)
  | QueuedLatest !EventCoalescingKey

data AliveScopes = AliveScopes
  { aliveWindows :: !(Set WindowKey)
  , aliveElements :: !(Set ElementKey)
  }

data ActiveTask = ActiveTask
  { activeTaskGeneration :: !RuntimeGeneration
  , activeTaskScope :: !TaskScope
  , activeTaskCancellation :: !(TVar Bool)
  , activeTaskThread :: !(Maybe (Async ()))
  }

data ActiveSubscription = ActiveSubscription
  { activeSubscriptionFingerprint :: !SubscriptionFingerprint
  , activeSubscriptionGeneration :: !RuntimeGeneration
  , activeSubscriptionCancellation :: !(TVar Bool)
  , activeSubscriptionThread :: !(Maybe (Async ()))
  }

data RunningService model where
  RunningService
    :: Typeable command
    => Service model
    -> ServiceOptions command
    -> TBQueue command
    -> RuntimeGeneration
    -> Int
    -> TVar Bool
    -> Maybe (Async ())
    -> RunningService model

data ServiceSlot model
  = ServiceRunningSlot !(RunningService model)
  | ServiceRestartPendingSlot
      !(Service model)
      !RuntimeGeneration
      !Int
      !(Async ())
  | ServiceStoppedSlot !(Service model) !Int

data Runtime model = Runtime
  { runtimeApplication :: !(App model)
  , runtimeOptions :: !RuntimeOptions
  , runtimeModel :: !(IORef model)
  , runtimeDesiredView :: !(IORef AppView)
  , runtimeSession :: !(IORef (Maybe BackendSession))
  , runtimeInbox :: !(TQueue (QueuedEnvelope model))
  , runtimeLatestEvents :: !(TVar (Map EventCoalescingKey (RuntimeEnvelope model)))
  , runtimeDrainScheduled :: !(TVar Bool)
  , runtimeDraining :: !(TVar Bool)
  , runtimeGenerationCounter :: !(IORef Word64)
  , runtimeTasks :: !(IORef (Map TaskKey ActiveTask))
  , runtimeServiceSpecs :: !(Map ServiceKey (Service model))
  , runtimeServices :: !(IORef (Map ServiceKey (ServiceSlot model)))
  , runtimeSubscriptions :: !(IORef (Map SubscriptionKey ActiveSubscription))
  , runtimeOpenLifetimes :: !(IORef (Set LifetimeKey))
  , runtimeAliveScopes :: !(IORef AliveScopes)
  , runtimePendingEffects :: !(IORef [Effect])
  , runtimeShuttingDown :: !(IORef Bool)
  }

-- | Run an application until the backend event loop returns. All reducer,
-- model, view, and render work is serialized through the backend UI thread.
runApp :: Backend -> App model -> IO ()
runApp = runAppWith defaultRuntimeOptions

runAppWith :: RuntimeOptions -> Backend -> App model -> IO ()
runAppWith options backend application = do
  runtimeTrace options TraceInfo "runtime.start"
    [ ("initialEffects", countText application.appInitialEffects)
    , ("initialCommands", countText application.appInitialCommands)
    , ("services", countText application.appServices)
    ]
  let initialRawView = application.appView application.appInitialModel
  runtime <- newRuntime options application initialRawView
  session <- openBackend backend (postBackendEvent runtime)
  writeIORef runtime.runtimeSession (Just session)
  traceRuntime runtime TraceInfo "backend.opened" []

  let initialResolved = fst (resolveAppViewLayouts initialRawView)
  session.backendRender initialResolved
  traceRuntime runtime TraceDebug "render.initial"
    [("windows", countText initialResolved.appWindows)]
  when (null initialResolved.appWindows) session.backendStop
  synchronizeViewOwnership runtime initialRawView
  startApplicationServices runtime
  executeRuntimeCommands runtime application.appInitialCommands
  forM_ application.appInitialEffects (interpretEffect runtime session (postBackendEvent runtime))
  wakePendingRuntime runtime

  traceRuntime runtime TraceInfo "backend.event-loop.start" []
  session.backendRun
    `finally`
      ( traceRuntime runtime TraceInfo "backend.event-loop.stop" []
          >> (shutdownRuntime runtime `finally` session.backendShutdown)
          >> traceRuntime runtime TraceInfo "runtime.stop" []
      )

newRuntime :: RuntimeOptions -> App model -> AppView -> IO (Runtime model)
newRuntime options application initialView = do
  modelReference <- newIORef application.appInitialModel
  desiredReference <- newIORef initialView
  sessionReference <- newIORef Nothing
  inbox <- newTQueueIO
  latestEvents <- newTVarIO Map.empty
  drainScheduled <- newTVarIO False
  draining <- newTVarIO False
  generationCounter <- newIORef 0
  tasks <- newIORef Map.empty
  services <- newIORef Map.empty
  subscriptions <- newIORef Map.empty
  lifetimes <- newIORef Set.empty
  aliveScopes <- newIORef (scopesFromView initialView)
  pendingEffects <- newIORef []
  shuttingDown <- newIORef False
  pure
    Runtime
      { runtimeApplication = application
      , runtimeOptions = options
      , runtimeModel = modelReference
      , runtimeDesiredView = desiredReference
      , runtimeSession = sessionReference
      , runtimeInbox = inbox
      , runtimeLatestEvents = latestEvents
      , runtimeDrainScheduled = drainScheduled
      , runtimeDraining = draining
      , runtimeGenerationCounter = generationCounter
      , runtimeTasks = tasks
      , runtimeServiceSpecs = Map.fromList [(serviceKey spec, spec) | spec <- application.appServices]
      , runtimeServices = services
      , runtimeSubscriptions = subscriptions
      , runtimeOpenLifetimes = lifetimes
      , runtimeAliveScopes = aliveScopes
      , runtimePendingEffects = pendingEffects
      , runtimeShuttingDown = shuttingDown
      }

postBackendEvent :: Runtime model -> UIEvent -> IO ()
postBackendEvent runtime = enqueueEnvelope runtime . QueuedDirect . BackendEnvelope

postExternalEvent :: Runtime model -> EventSource -> ExternalEvent model -> IO ()
postExternalEvent runtime source event =
  case externalEventDelivery event of
    DeliverEvery -> enqueueEnvelope runtime (QueuedDirect (ExternalEnvelope source event))
    KeepLatest key -> postLatestEnvelope runtime key (ExternalEnvelope source event)

postLatestExternalEvent
  :: Runtime model
  -> EventSource
  -> EventCoalescingKey
  -> ExternalEvent model
  -> IO ()
postLatestExternalEvent runtime source key event =
  postLatestEnvelope runtime key (ExternalEnvelope source event)

postLatestEnvelope
  :: Runtime model
  -> EventCoalescingKey
  -> RuntimeEnvelope model
  -> IO ()
postLatestEnvelope runtime key envelope = do
  shuttingDown <- readIORef runtime.runtimeShuttingDown
  unless shuttingDown $ do
    shouldWake <- atomically $ do
      pending <- readTVar runtime.runtimeLatestEvents
      let firstForKey = Map.notMember key pending
      writeTVar runtime.runtimeLatestEvents (Map.insert key envelope pending)
      when firstForKey (writeTQueue runtime.runtimeInbox (QueuedLatest key))
      requestDrain runtime
    when shouldWake (scheduleDrain runtime)

enqueueEnvelope :: Runtime model -> QueuedEnvelope model -> IO ()
enqueueEnvelope runtime envelope = do
  shuttingDown <- readIORef runtime.runtimeShuttingDown
  unless shuttingDown $ do
    shouldWake <- atomically $ do
      writeTQueue runtime.runtimeInbox envelope
      requestDrain runtime
    when shouldWake (scheduleDrain runtime)

requestDrain :: Runtime model -> STM Bool
requestDrain runtime = do
  scheduled <- readTVar runtime.runtimeDrainScheduled
  draining <- readTVar runtime.runtimeDraining
  if scheduled || draining
    then pure False
    else do
      writeTVar runtime.runtimeDrainScheduled True
      pure True

scheduleDrain :: Runtime model -> IO ()
scheduleDrain runtime = do
  maybeSession <- readIORef runtime.runtimeSession
  traverse_ (\session -> session.backendScheduleOnUI (drainRuntime runtime)) maybeSession

wakePendingRuntime :: Runtime model -> IO ()
wakePendingRuntime runtime = do
  shouldWake <- atomically $ do
    empty <- isEmptyTQueue runtime.runtimeInbox
    scheduled <- readTVar runtime.runtimeDrainScheduled
    pure (not empty && scheduled)
  when shouldWake (scheduleDrain runtime)

drainRuntime :: Runtime model -> IO ()
drainRuntime runtime = do
  acquired <- atomically $ do
    active <- readTVar runtime.runtimeDraining
    if active
      then pure False
      else do
        writeTVar runtime.runtimeDraining True
        writeTVar runtime.runtimeDrainScheduled False
        pure True
  when acquired $ do
    (do
        envelopes <- takeEnvelopeBatch runtime (max 1 runtime.runtimeOptions.runtimeMaximumBatchSize)
        accepted <- fmap or (mapM (processEnvelope runtime) envelopes)
        when accepted $ do
          renderCurrentView runtime
          executePendingEffects runtime
      ) `finally` finishDrain runtime

finishDrain :: Runtime model -> IO ()
finishDrain runtime = do
  shouldWake <- atomically $ do
    writeTVar runtime.runtimeDraining False
    empty <- isEmptyTQueue runtime.runtimeInbox
    if empty
      then pure False
      else requestDrain runtime
  when shouldWake (scheduleDrain runtime)

takeEnvelopeBatch :: Runtime model -> Int -> IO [RuntimeEnvelope model]
takeEnvelopeBatch runtime limit = go limit []
  where
    go remaining accumulated
      | remaining <= 0 = pure (reverse accumulated)
      | otherwise = do
          next <- atomically (takeOneEnvelope runtime)
          case next of
            Nothing -> pure (reverse accumulated)
            Just envelope -> go (remaining - 1) (envelope : accumulated)

takeOneEnvelope :: Runtime model -> STM (Maybe (RuntimeEnvelope model))
takeOneEnvelope runtime = do
  queued <- tryReadTQueue runtime.runtimeInbox
  case queued of
    Nothing -> pure Nothing
    Just (QueuedDirect envelope) -> pure (Just envelope)
    Just (QueuedLatest key) -> do
      pending <- readTVar runtime.runtimeLatestEvents
      writeTVar runtime.runtimeLatestEvents (Map.delete key pending)
      pure (Map.lookup key pending)

processEnvelope :: Runtime model -> RuntimeEnvelope model -> IO Bool
processEnvelope runtime = \case
  BackendEnvelope event -> do
    traceRuntime runtime TraceDebug "event.backend" (uiEventTraceFields event)
    model <- readIORef runtime.runtimeModel
    commitTransaction runtime (runtime.runtimeApplication.appHandleEvent event model)
    pure True
  ExternalEnvelope source event -> do
    accepted <- acceptExternalSource runtime source
    traceRuntime runtime (if accepted then TraceDebug else TraceWarning) "event.external"
      [ ("description", externalEventDescription event)
      , ("source", eventSourceText source)
      , ("accepted", boolText accepted)
      ]
    if not accepted
      then pure False
      else do
        model <- readIORef runtime.runtimeModel
        commitTransaction runtime (handleExternalEvent event model)
        pure True
  ServiceExitedEnvelope key generation serviceExit ->
    handleServiceExit runtime key generation serviceExit
  RestartServiceEnvelope key generation attempt ->
    handleServiceRestart runtime key generation attempt

acceptExternalSource :: Runtime model -> EventSource -> IO Bool
acceptExternalSource runtime source = do
  shuttingDown <- readIORef runtime.runtimeShuttingDown
  if shuttingDown
    then pure False
    else case source of
      RuntimeSource -> pure True
      TaskSource key generation scope -> do
        tasks <- readIORef runtime.runtimeTasks
        alive <- taskScopeAlive runtime scope
        case Map.lookup key tasks of
          Just active
            | active.activeTaskGeneration == generation && alive -> do
                writeIORef runtime.runtimeTasks (Map.delete key tasks)
                pure True
          _ -> pure False
      ServiceSource key generation -> do
        services <- readIORef runtime.runtimeServices
        pure $ case Map.lookup key services of
          Just (ServiceRunningSlot running) -> runningServiceGeneration running == generation
          _ -> False
      SubscriptionSource key generation -> do
        subscriptions <- readIORef runtime.runtimeSubscriptions
        pure $ case Map.lookup key subscriptions of
          Just active -> active.activeSubscriptionGeneration == generation
          Nothing -> False

commitTransaction :: Runtime model -> Transaction model -> IO ()
commitTransaction runtime update = do
  traceRuntime runtime TraceDebug "transaction.commit"
    [ ("description", maybe "<none>" id update.transactionDescription)
    , ("action", actionDescription update.transactionAction)
    , ( "properties"
      , Text.intercalate "," (fmap unPropertyId (actionPropertyIds update.transactionAction))
      )
    , ("effects", countText update.transactionEffects)
    , ("commands", countText update.transactionCommands)
    , ("undo", Text.pack (show update.transactionUndo))
    ]
  model <- readIORef runtime.runtimeModel
  let updated = applyTransaction update model
      desired = runtime.runtimeApplication.appView updated
  writeIORef runtime.runtimeModel updated
  writeIORef runtime.runtimeDesiredView desired
  synchronizeViewOwnership runtime desired
  executeRuntimeCommands runtime update.transactionCommands
  modifyIORef' runtime.runtimePendingEffects (<> update.transactionEffects)

executePendingEffects :: Runtime model -> IO ()
executePendingEffects runtime = do
  pending <- atomicModifyIORef' runtime.runtimePendingEffects (\effects -> ([], effects))
  maybeSession <- readIORef runtime.runtimeSession
  forM_ maybeSession $ \session ->
    traverse_ (interpretEffect runtime session (postBackendEvent runtime)) pending

renderCurrentView :: Runtime model -> IO ()
renderCurrentView runtime = do
  desired <- readIORef runtime.runtimeDesiredView
  maybeSession <- readIORef runtime.runtimeSession
  forM_ maybeSession $ \session -> do
    let resolved = fst (resolveAppViewLayouts desired)
    traceRuntime runtime TraceDebug "render.commit"
      [ ("windows", countText resolved.appWindows)
      , ( "controls"
        , Text.pack . show . sum $
            [ length (windowLeafControls window)
            | window <- resolved.appWindows
            ]
        )
      ]
    session.backendRender resolved
    when (null resolved.appWindows) session.backendStop

synchronizeViewOwnership :: Runtime model -> AppView -> IO ()
synchronizeViewOwnership runtime desired = do
  let currentScopes = scopesFromView desired
  writeIORef runtime.runtimeAliveScopes currentScopes
  tasks <- readIORef runtime.runtimeTasks
  let (dead, live) = Map.partition (not . scopeInView currentScopes . (.activeTaskScope)) tasks
  writeIORef runtime.runtimeTasks live
  traverse_ invalidateActiveTask dead
  synchronizeSubscriptions runtime

scopesFromView :: AppView -> AliveScopes
scopesFromView view =
  AliveScopes
    { aliveWindows = Set.fromList (fmap (.windowKey) view.appWindows)
    , aliveElements = Set.fromList [controlKey control | window <- view.appWindows, control <- windowLeafControls window]
    }

scopeInView :: AliveScopes -> TaskScope -> Bool
scopeInView _ ApplicationScope = True
scopeInView scopes (WindowScope key) = Set.member key scopes.aliveWindows
scopeInView scopes (ElementScope key) = Set.member key scopes.aliveElements
scopeInView _ (LifetimeScope _) = True

taskScopeAlive :: Runtime model -> TaskScope -> IO Bool
taskScopeAlive _ ApplicationScope = pure True
taskScopeAlive runtime (WindowScope key) =
  Set.member key . (.aliveWindows) <$> readIORef runtime.runtimeAliveScopes
taskScopeAlive runtime (ElementScope key) =
  Set.member key . (.aliveElements) <$> readIORef runtime.runtimeAliveScopes
taskScopeAlive runtime (LifetimeScope key) =
  Set.member key <$> readIORef runtime.runtimeOpenLifetimes

executeRuntimeCommands :: Runtime model -> [RuntimeCommand model] -> IO ()
executeRuntimeCommands runtime = traverse_ (executeRuntimeCommand runtime)

executeRuntimeCommand :: Runtime model -> RuntimeCommand model -> IO ()
executeRuntimeCommand runtime = \case
  StartTaskCommand key options description run onOutcome -> do
    traceRuntime runtime TraceDebug "command.task.start"
      [ ("key", key.unTaskKey)
      , ("description", description)
      , ("scope", Text.pack (show options.taskScope))
      , ("policy", Text.pack (show options.taskStartPolicy))
      ]
    startRuntimeTask runtime key options description run onOutcome
  CancelTaskCommand key -> do
    traceRuntime runtime TraceDebug "command.task.cancel" [("key", key.unTaskKey)]
    cancelTaskByKey runtime key
  CancelScopeCommand scope -> do
    traceRuntime runtime TraceDebug "command.scope.cancel" [("scope", Text.pack (show scope))]
    cancelTasksInScope runtime scope
  SendServiceCommand endpoint command onResult -> do
    result <- enqueueServiceCommand runtime endpoint command
    traceRuntime runtime (serviceSendSeverity result) "command.service.send"
      [ ("service", (serviceEndpointKey endpoint).unServiceKey)
      , ("result", Text.pack (show result))
      ]
    traverse_ (postExternalEvent runtime RuntimeSource . ($ result)) onResult
  RestartServiceCommand key -> do
    traceRuntime runtime TraceInfo "command.service.restart" [("service", key.unServiceKey)]
    restartServiceNow runtime key
  OpenLifetimeCommand key -> do
    traceRuntime runtime TraceDebug "command.lifetime.open" [("key", key.unLifetimeKey)]
    modifyIORef' runtime.runtimeOpenLifetimes (Set.insert key)
  CloseLifetimeCommand key -> do
    traceRuntime runtime TraceDebug "command.lifetime.close" [("key", key.unLifetimeKey)]
    modifyIORef' runtime.runtimeOpenLifetimes (Set.delete key)
    cancelTasksInScope runtime (LifetimeScope key)

startRuntimeTask
  :: Runtime model
  -> TaskKey
  -> TaskOptions
  -> Text.Text
  -> (CancellationToken -> IO result)
  -> (TaskOutcome result -> ExternalEvent model)
  -> IO ()
startRuntimeTask runtime key options description run onOutcome = do
  alive <- taskScopeAlive runtime options.taskScope
  unless alive $
    traceRuntime runtime TraceWarning "task.skipped"
      [("key", key.unTaskKey), ("reason", "scope-not-alive")]
  when alive $ do
    tasks <- readIORef runtime.runtimeTasks
    let existing = Map.lookup key tasks
    shouldStart <-
      case (options.taskStartPolicy, existing) of
        (ReplaceRunning, Just active) -> invalidateActiveTask active >> pure True
        (KeepRunning, Just _) -> pure False
        (RequireIdle, Just _) -> pure False
        (_, Nothing) -> pure True
    when shouldStart $ do
      generation <- nextGeneration runtime
      traceRuntime runtime TraceInfo "task.started"
        [ ("key", key.unTaskKey)
        , ("description", description)
        , ("generation", generationText generation)
        ]
      cancellation <- newTVarIO False
      let pending = ActiveTask generation options.taskScope cancellation Nothing
      writeIORef runtime.runtimeTasks (Map.insert key pending tasks)
      worker <- async $ do
        outcome <- runTask options cancellation run
        traceRuntime runtime (taskOutcomeSeverity outcome) "task.finished"
          [ ("key", key.unTaskKey)
          , ("generation", generationText generation)
          , ("outcome", taskOutcomeText outcome)
          ]
        postExternalEvent runtime (TaskSource key generation options.taskScope) (onOutcome outcome)
      current <- readIORef runtime.runtimeTasks
      case Map.lookup key current of
        Just active
          | active.activeTaskGeneration == generation ->
              writeIORef runtime.runtimeTasks (Map.insert key (active {activeTaskThread = Just worker}) current)
        _ -> cancel worker

runTask
  :: TaskOptions
  -> TVar Bool
  -> (CancellationToken -> IO result)
  -> IO (TaskOutcome result)
runTask options cancellation run = do
  let token = cancellationToken cancellation
      operation = run token
      timed = case options.taskTimeoutMilliseconds of
        Nothing -> Just <$> operation
        Just milliseconds -> timeout (millisecondsToMicroseconds milliseconds) operation
  attempted <- try timed
  case attempted of
    Right Nothing -> pure (TaskFailed TaskTimedOut)
    Right (Just result) -> pure (TaskSucceeded result)
    Left exception
      | isTaskCancellation exception -> pure TaskCancelled
      | isExecutorCancellation exception -> pure TaskCancelled
      | isAsyncException exception -> throwIO exception
      | otherwise ->
          pure (TaskFailed (TaskException (ExceptionSummary (Text.pack (displayException exception)))))

millisecondsToMicroseconds :: Word64 -> Int
millisecondsToMicroseconds milliseconds =
  fromIntegral (min maximumMicroseconds requestedMicroseconds)
  where
    maximumMicroseconds = fromIntegral (maxBound :: Int)
    requestedMicroseconds
      | milliseconds > maximumMicroseconds `div` 1000 = maximumMicroseconds
      | otherwise = milliseconds * 1000

isTaskCancellation :: SomeException -> Bool
isTaskCancellation exception =
  isJust (fromException exception :: Maybe TaskCancellationRequested)

isExecutorCancellation :: SomeException -> Bool
isExecutorCancellation exception =
  isJust (fromException exception :: Maybe AsyncCancelled)

isAsyncException :: SomeException -> Bool
isAsyncException exception =
  isJust (fromException exception :: Maybe AsyncException)

cancellationToken :: TVar Bool -> CancellationToken
cancellationToken requested =
  CancellationToken
    { cancellationRequested = atomically (readTVar requested)
    , waitForCancellation = atomically (readTVar requested >>= check)
    }

cancelTaskByKey :: Runtime model -> TaskKey -> IO ()
cancelTaskByKey runtime key = do
  tasks <- readIORef runtime.runtimeTasks
  case Map.lookup key tasks of
    Nothing -> pure ()
    Just active -> do
      writeIORef runtime.runtimeTasks (Map.delete key tasks)
      invalidateActiveTask active

cancelTasksInScope :: Runtime model -> TaskScope -> IO ()
cancelTasksInScope runtime scope = do
  tasks <- readIORef runtime.runtimeTasks
  let (owned, remaining) = Map.partition ((== scope) . (.activeTaskScope)) tasks
  writeIORef runtime.runtimeTasks remaining
  traverse_ invalidateActiveTask owned

invalidateActiveTask :: ActiveTask -> IO ()
invalidateActiveTask active = do
  atomically (writeTVar active.activeTaskCancellation True)
  traverse_ requestThreadCancellation active.activeTaskThread

requestThreadCancellation :: Async () -> IO ()
requestThreadCancellation worker = void (async (cancel worker))

nextGeneration :: Runtime model -> IO RuntimeGeneration
nextGeneration runtime =
  RuntimeGeneration <$> atomicModifyIORef' runtime.runtimeGenerationCounter (\value -> let next = value + 1 in (next, next))

startApplicationServices :: Runtime model -> IO ()
startApplicationServices runtime =
  traverse_ (\spec -> startServiceSpec runtime spec 0) (Map.elems runtime.runtimeServiceSpecs)

startServiceSpec :: Runtime model -> Service model -> Int -> IO ()
startServiceSpec runtime spec@(Service key description options onStatus run) restartCount = do
  generation <- nextGeneration runtime
  traceRuntime runtime TraceInfo "service.started"
    [ ("service", key.unServiceKey)
    , ("description", description)
    , ("generation", generationText generation)
    , ("restartCount", Text.pack (show restartCount))
    ]
  cancellation <- newTVarIO False
  queue <- newTBQueueIO (fromIntegral (max 1 options.serviceCommandCapacity))
  let source = ServiceSource key generation
      sink =
        ExternalSink
          { emitEvery = postExternalEvent runtime source
          , emitLatest = postLatestExternalEvent runtime source
          }
      report health =
        traverse_ (postExternalEvent runtime source . ($ ServiceHealthChanged health)) onStatus
      context =
        ServiceContext
          { receiveCommand = receiveServiceCommand cancellation queue
          , serviceEvents = sink
          , serviceCancellation = cancellationToken cancellation
          , reportServiceHealth = report
          }
      pending = RunningService spec options queue generation restartCount cancellation Nothing
  modifyIORef' runtime.runtimeServices (Map.insert key (ServiceRunningSlot pending))
  traverse_ (postExternalEvent runtime source . ($ ServiceStarting)) onStatus
  worker <- async $ do
    traverse_ (postExternalEvent runtime source . ($ ServiceRunning)) onStatus
    serviceExit <- runService context run
    enqueueEnvelope runtime (QueuedDirect (ServiceExitedEnvelope key generation serviceExit))
  services <- readIORef runtime.runtimeServices
  case Map.lookup key services of
    Just (ServiceRunningSlot running)
      | runningServiceGeneration running == generation ->
          writeIORef runtime.runtimeServices (Map.insert key (ServiceRunningSlot (setRunningServiceThread worker running)) services)
    _ -> cancel worker

receiveServiceCommand :: TVar Bool -> TBQueue command -> IO (Maybe command)
receiveServiceCommand cancellation queue =
  atomically $ do
    requested <- readTVar cancellation
    if requested then pure Nothing else Just <$> readTBQueue queue

runService
  :: ServiceContext model command
  -> (ServiceContext model command -> IO ())
  -> IO ServiceExit
runService context run = do
  attempted <- try (run context)
  case attempted of
    Right () -> pure ServiceStoppedNormally
    Left exception
      | isTaskCancellation exception || isExecutorCancellation exception || isAsyncException exception ->
          pure ServiceCancelled
      | otherwise ->
          pure (ServiceFailed (ExceptionSummary (Text.pack (displayException exception))))

runningServiceGeneration :: RunningService model -> RuntimeGeneration
runningServiceGeneration (RunningService _ _ _ generation _ _ _) = generation

setRunningServiceThread :: Async () -> RunningService model -> RunningService model
setRunningServiceThread worker (RunningService spec options queue generation restarts cancellation _) =
  RunningService spec options queue generation restarts cancellation (Just worker)

invalidateRunningService :: RunningService model -> IO ()
invalidateRunningService (RunningService _ _ _ _ _ cancellation worker) = do
  atomically (writeTVar cancellation True)
  traverse_ requestThreadCancellation worker

enqueueServiceCommand
  :: Typeable command
  => Runtime model
  -> ServiceEndpoint command
  -> command
  -> IO ServiceSendResult
enqueueServiceCommand runtime endpoint command = do
  services <- readIORef runtime.runtimeServices
  case Map.lookup (serviceEndpointKey endpoint) services of
    Just (ServiceRunningSlot (RunningService _ options queue _ _ _ _)) ->
      case cast command of
        Nothing -> pure ServiceEndpointMismatch
        Just typed -> atomically (writeServiceCommand options queue typed)
    _ -> pure ServiceUnavailable

writeServiceCommand
  :: ServiceOptions command
  -> TBQueue command
  -> command
  -> STM ServiceSendResult
writeServiceCommand options queue command =
  case options.serviceOverflowPolicy of
    RejectNewCommand -> do
      full <- isFullTBQueue queue
      if full
        then pure ServiceCommandRejected
        else writeTBQueue queue command >> pure ServiceCommandQueued
    DropOldestCommand -> do
      full <- isFullTBQueue queue
      when full (void (readTBQueue queue))
      writeTBQueue queue command
      pure (if full then ServiceCommandDroppedOldest else ServiceCommandQueued)
    ReplacePendingCommand commandKey -> do
      pending <- flushTBQueue queue
      let requestedKey = commandKey command
          hasMatching = any ((== requestedKey) . commandKey) pending
          retained = filter ((/= requestedKey) . commandKey) pending
      if hasMatching
        then traverse_ (writeTBQueue queue) (retained <> [command]) >> pure ServiceCommandCoalesced
        else do
          let capacity = options.serviceCommandCapacity
          if length pending >= max 1 capacity
            then traverse_ (writeTBQueue queue) pending >> pure ServiceCommandRejected
            else traverse_ (writeTBQueue queue) (pending <> [command]) >> pure ServiceCommandQueued

handleServiceExit
  :: Runtime model
  -> ServiceKey
  -> RuntimeGeneration
  -> ServiceExit
  -> IO Bool
handleServiceExit runtime key generation serviceExit = do
  traceRuntime runtime (serviceExitSeverity serviceExit) "service.exited"
    [ ("service", key.unServiceKey)
    , ("generation", generationText generation)
    , ("exit", Text.pack (show serviceExit))
    ]
  services <- readIORef runtime.runtimeServices
  case Map.lookup key services of
    Just (ServiceRunningSlot running)
      | runningServiceGeneration running == generation -> do
          let (spec, restartCount) = runningServiceSpecAndRestarts running
          case serviceRestartDecision spec serviceExit restartCount of
            Just (attempt, delayMilliseconds) -> do
              traceRuntime runtime TraceWarning "service.restart.scheduled"
                [ ("service", key.unServiceKey)
                , ("attempt", Text.pack (show attempt))
                , ("delayMilliseconds", Text.pack (show delayMilliseconds))
                ]
              timer <- async $ do
                threadDelay (millisecondsToMicroseconds delayMilliseconds)
                enqueueEnvelope runtime (QueuedDirect (RestartServiceEnvelope key generation attempt))
              writeIORef runtime.runtimeServices
                (Map.insert key (ServiceRestartPendingSlot spec generation attempt timer) services)
              emitServiceStatusNow runtime spec (ServiceExited serviceExit)
              emitServiceStatusNow runtime spec (ServiceRestartScheduled attempt delayMilliseconds)
            Nothing -> do
              let stoppedCount = restartCount
              writeIORef runtime.runtimeServices (Map.insert key (ServiceStoppedSlot spec stoppedCount) services)
              emitServiceStatusNow runtime spec (ServiceExited serviceExit)
              when (serviceExitFailed serviceExit && serviceCircuitExceeded spec restartCount) $
                emitServiceStatusNow runtime spec (ServiceCircuitOpen restartCount serviceExit)
          pure True
    _ -> pure False

runningServiceSpecAndRestarts :: RunningService model -> (Service model, Int)
runningServiceSpecAndRestarts (RunningService spec _ _ _ restarts _ _) = (spec, restarts)

serviceRestartDecision :: Service model -> ServiceExit -> Int -> Maybe (Int, Word64)
serviceRestartDecision (Service key _ options _ _) serviceExit restartCount =
  case (serviceExit, options.serviceRestartPolicy) of
    (ServiceFailed _, RestartOnFailure policy)
      | restartCount < policy.backoffMaximumRestarts ->
          let attempt = restartCount + 1
           in Just (attempt, backoffDelay key policy attempt)
    _ -> Nothing

serviceCircuitExceeded :: Service model -> Int -> Bool
serviceCircuitExceeded (Service _ _ options _ _) restartCount =
  case options.serviceRestartPolicy of
    RestartOnFailure policy -> restartCount >= policy.backoffMaximumRestarts
    DoNotRestart -> False

serviceExitFailed :: ServiceExit -> Bool
serviceExitFailed (ServiceFailed _) = True
serviceExitFailed _ = False

backoffDelay :: ServiceKey -> BackoffPolicy -> Int -> Word64
backoffDelay key policy attempt =
  min maximumDelay (round (baseDelay * jitterFactor))
  where
    maximumDelay = max policy.backoffInitialMilliseconds policy.backoffMaximumMilliseconds
    multiplier = max 1 policy.backoffMultiplier
    baseDelay =
      min
        (fromIntegral maximumDelay)
        (fromIntegral policy.backoffInitialMilliseconds * (multiplier ** fromIntegral (max 0 (attempt - 1))))
    jitterRatio = max 0 (min 1 policy.backoffJitterRatio)
    jitterFactor = 1 + jitterRatio * deterministicJitter key attempt

deterministicJitter :: ServiceKey -> Int -> Double
deterministicJitter (ServiceKey key) attempt =
  (fromIntegral bucket / 500) - 1
  where
    seed = Text.foldl' (\value character -> value * 33 + fromEnum character) attempt key
    bucket = abs seed `mod` 1001

emitServiceStatusNow :: Runtime model -> Service model -> ServiceStatus -> IO ()
emitServiceStatusNow runtime (Service _ _ _ onStatus _) status =
  forM_ onStatus $ \makeEvent -> do
    model <- readIORef runtime.runtimeModel
    commitTransaction runtime (handleExternalEvent (makeEvent status) model)

handleServiceRestart
  :: Runtime model
  -> ServiceKey
  -> RuntimeGeneration
  -> Int
  -> IO Bool
handleServiceRestart runtime key oldGeneration attempt = do
  services <- readIORef runtime.runtimeServices
  case Map.lookup key services of
    Just (ServiceRestartPendingSlot spec generation _ _)
      | generation == oldGeneration -> do
          startServiceSpec runtime spec attempt
          pure True
    _ -> pure False

restartServiceNow :: Runtime model -> ServiceKey -> IO ()
restartServiceNow runtime key = do
  traceRuntime runtime TraceInfo "service.restart.requested" [("service", key.unServiceKey)]
  services <- readIORef runtime.runtimeServices
  let maybeSpec =
        case Map.lookup key services of
          Just (ServiceRunningSlot running) -> Just (fst (runningServiceSpecAndRestarts running))
          Just (ServiceRestartPendingSlot spec _ _ _) -> Just spec
          Just (ServiceStoppedSlot spec _) -> Just spec
          Nothing -> Map.lookup key runtime.runtimeServiceSpecs
  forM_ (Map.lookup key services) $ \case
    ServiceRunningSlot running -> invalidateRunningService running
    ServiceRestartPendingSlot _ _ _ timer -> requestThreadCancellation timer
    ServiceStoppedSlot _ _ -> pure ()
  modifyIORef' runtime.runtimeServices (Map.delete key)
  traverse_ (\spec -> startServiceSpec runtime spec 0) maybeSpec

synchronizeSubscriptions :: Runtime model -> IO ()
synchronizeSubscriptions runtime = do
  model <- readIORef runtime.runtimeModel
  active <- readIORef runtime.runtimeSubscriptions
  let desired = Map.fromList [(subscriptionKey spec, spec) | spec <- runtime.runtimeApplication.appSubscriptions model]
      removedOrChanged =
        Map.filterWithKey
          (\key current -> case Map.lookup key desired of
            Nothing -> True
            Just spec -> current.activeSubscriptionFingerprint /= subscriptionFingerprint spec
          )
          active
      retained = Map.withoutKeys active (Map.keysSet removedOrChanged)
  traverse_ invalidateActiveSubscription removedOrChanged
  writeIORef runtime.runtimeSubscriptions retained
  forM_ (Map.toList desired) $ \(key, spec) ->
    case Map.lookup key retained of
      Just _ -> pure ()
      Nothing -> startSubscriptionSpec runtime spec

startSubscriptionSpec :: Runtime model -> Subscription model -> IO ()
startSubscriptionSpec runtime (Subscription key fingerprint start) = do
  generation <- nextGeneration runtime
  traceRuntime runtime TraceInfo "subscription.started"
    [ ("subscription", key.unSubscriptionKey)
    , ("fingerprint", fingerprint.unSubscriptionFingerprint)
    , ("generation", generationText generation)
    ]
  cancellation <- newTVarIO False
  let source = SubscriptionSource key generation
      sink =
        ExternalSink
          { emitEvery = postExternalEvent runtime source
          , emitLatest = postLatestExternalEvent runtime source
          }
      pending = ActiveSubscription fingerprint generation cancellation Nothing
  modifyIORef' runtime.runtimeSubscriptions (Map.insert key pending)
  worker <- async $
    bracket
      (start sink)
      id
      (const (atomically (readTVar cancellation >>= check)))
  subscriptions <- readIORef runtime.runtimeSubscriptions
  case Map.lookup key subscriptions of
    Just active
      | active.activeSubscriptionGeneration == generation ->
          writeIORef runtime.runtimeSubscriptions
            (Map.insert key (active {activeSubscriptionThread = Just worker}) subscriptions)
    _ -> cancel worker

invalidateActiveSubscription :: ActiveSubscription -> IO ()
invalidateActiveSubscription active = do
  atomically (writeTVar active.activeSubscriptionCancellation True)
  traverse_ requestThreadCancellation active.activeSubscriptionThread

shutdownRuntime :: Runtime model -> IO ()
shutdownRuntime runtime = do
  traceRuntime runtime TraceInfo "shutdown.begin" []
  writeIORef runtime.runtimeShuttingDown True
  atomically $ do
    writeTVar runtime.runtimeDrainScheduled False
    writeTVar runtime.runtimeLatestEvents Map.empty
  tasks <- readIORef runtime.runtimeTasks
  writeIORef runtime.runtimeTasks Map.empty
  subscriptions <- readIORef runtime.runtimeSubscriptions
  writeIORef runtime.runtimeSubscriptions Map.empty
  services <- readIORef runtime.runtimeServices
  writeIORef runtime.runtimeServices Map.empty
  atomically $ do
    traverse_ (\active -> writeTVar active.activeTaskCancellation True) tasks
    traverse_ (\active -> writeTVar active.activeSubscriptionCancellation True) subscriptions
    traverse_ markServiceCancelled services
  let workers =
        catMaybes (fmap (.activeTaskThread) (Map.elems tasks))
          <> catMaybes (fmap (.activeSubscriptionThread) (Map.elems subscriptions))
          <> foldMap serviceSlotThreads (Map.elems services)
  traceRuntime runtime TraceDebug "shutdown.cancel"
    [ ("tasks", Text.pack (show (Map.size tasks)))
    , ("subscriptions", Text.pack (show (Map.size subscriptions)))
    , ("services", Text.pack (show (Map.size services)))
    , ("threads", countText workers)
    ]
  cancellationJobs <- traverse (async . cancel) workers
  void $
    timeout
      (millisecondsToMicroseconds runtime.runtimeOptions.runtimeShutdownGraceMilliseconds)
      (traverse_ waitCatch cancellationJobs)
  traceRuntime runtime TraceInfo "shutdown.complete" []

markServiceCancelled :: ServiceSlot model -> STM ()
markServiceCancelled (ServiceRunningSlot (RunningService _ _ _ _ _ cancellation _)) =
  writeTVar cancellation True
markServiceCancelled _ = pure ()

serviceSlotThreads :: ServiceSlot model -> [Async ()]
serviceSlotThreads (ServiceRunningSlot (RunningService _ _ _ _ _ _ worker)) = maybe [] pure worker
serviceSlotThreads (ServiceRestartPendingSlot _ _ _ timer) = [timer]
serviceSlotThreads (ServiceStoppedSlot _ _) = []

eventSourceText :: EventSource -> Text.Text
eventSourceText source =
  case source of
    RuntimeSource -> "runtime"
    TaskSource key generation scope ->
      "task:" <> key.unTaskKey <> ":" <> generationText generation <> ":" <> Text.pack (show scope)
    ServiceSource key generation ->
      "service:" <> key.unServiceKey <> ":" <> generationText generation
    SubscriptionSource key generation ->
      "subscription:" <> key.unSubscriptionKey <> ":" <> generationText generation

generationText :: RuntimeGeneration -> Text.Text
generationText = Text.pack . show . (.unRuntimeGeneration)

boolText :: Bool -> Text.Text
boolText True = "true"
boolText False = "false"

serviceSendSeverity :: ServiceSendResult -> TraceSeverity
serviceSendSeverity result =
  case result of
    ServiceCommandQueued -> TraceDebug
    ServiceCommandCoalesced -> TraceDebug
    ServiceCommandDroppedOldest -> TraceWarning
    ServiceCommandRejected -> TraceWarning
    ServiceEndpointMismatch -> TraceError
    ServiceUnavailable -> TraceWarning

serviceExitSeverity :: ServiceExit -> TraceSeverity
serviceExitSeverity exit =
  case exit of
    ServiceStoppedNormally -> TraceInfo
    ServiceCancelled -> TraceDebug
    ServiceFailed _ -> TraceError

taskOutcomeSeverity :: TaskOutcome result -> TraceSeverity
taskOutcomeSeverity outcome =
  case outcome of
    TaskSucceeded _ -> TraceInfo
    TaskCancelled -> TraceDebug
    TaskFailed _ -> TraceError

taskOutcomeText :: TaskOutcome result -> Text.Text
taskOutcomeText outcome =
  case outcome of
    TaskSucceeded _ -> "succeeded"
    TaskCancelled -> "cancelled"
    TaskFailed TaskTimedOut -> "timed-out"
    TaskFailed TaskExecutorStopped -> "executor-stopped"
    TaskFailed (TaskException _) -> "exception"

uiEventTraceFields :: UIEvent -> [(Text.Text, Text.Text)]
uiEventTraceFields event =
  ("kind", uiEventKind event) :
    case event of
      CommandInvoked key -> [("command", Text.pack (show key.unCommandId))]
      TextChanged key value -> keyFields key <> [("characters", Text.pack (show (Text.length value)))]
      ControlInvoked key -> keyFields key
      ToggleChanged key value -> keyFields key <> [("value", Text.pack (show value))]
      ChoiceChanged key value -> keyFields key <> [("value", Text.pack (show value))]
      NumberChanged key value -> keyFields key <> [("value", Text.pack (show value))]
      DateChanged key value -> keyFields key <> [("value", Text.pack (show value))]
      TimeChanged key value -> keyFields key <> [("value", Text.pack (show value))]
      ColorChanged key value -> keyFields key <> [("value", Text.pack (show value))]
      CollectionSelectionChanged key values ->
        keyFields key <> [("selected", Text.pack (show (length values)))]
      CollectionExpansionChanged key item expanded ->
        keyFields key
          <> [ ("item", Text.pack (show item.unCollectionItemKey))
             , ("expanded", boolText expanded)
             ]
      DisclosureChanged key expanded -> keyFields key <> [("expanded", boolText expanded)]
      PresentationClosed key result -> keyFields key <> [("result", Text.pack (show result))]
      TabSelected key -> [("tab", Text.pack (show key.unTabKey))]
      TabCloseRequested key -> [("tab", Text.pack (show key.unTabKey))]
      PaneStateChanged key value -> [("pane", Text.pack (show key.unPaneKey)), ("state", Text.pack (show value))]
      WindowCloseRequested key -> [("window", Text.pack (show key.unWindowKey))]
      WindowActivated key -> [("window", Text.pack (show key.unWindowKey))]
      SystemColorSchemeChanged scheme -> [("scheme", Text.pack (show scheme))]
      TextFileChosen path -> [("path", Text.pack path)]
      ProjectFolderChosen path -> [("path", Text.pack path)]
      DirectoryRead path result ->
        [("path", Text.pack path), ("result", either (const "error") (Text.pack . show . length) result)]
      TextFileRead path result ->
        [("path", Text.pack path), ("result", textReadResult result)]
      OptionalTextFileRead path result ->
        [("path", Text.pack path), ("result", optionalTextReadResult result)]
      TextFileWritten key path contents result ->
        [ ("effectKey", Text.pack (show key.unEffectKey))
        , ("path", Text.pack path)
        , ("characters", Text.pack (show (Text.length contents)))
        , ("result", either (const "error") (const "ok") result)
        ]
  where
    keyFields :: ElementKey -> [(Text.Text, Text.Text)]
    keyFields key = [("element", Text.pack (show key.unElementKey))]
    textReadResult = either (const "error") (\contents -> "ok:" <> Text.pack (show (Text.length contents)))
    optionalTextReadResult =
      either
        (const "error")
        (maybe "missing" (\contents -> "ok:" <> Text.pack (show (Text.length contents))))

uiEventKind :: UIEvent -> Text.Text
uiEventKind event =
  case event of
    CommandInvoked {} -> "command-invoked"
    TextChanged {} -> "text-changed"
    ControlInvoked {} -> "control-invoked"
    ToggleChanged {} -> "toggle-changed"
    ChoiceChanged {} -> "choice-changed"
    NumberChanged {} -> "number-changed"
    DateChanged {} -> "date-changed"
    TimeChanged {} -> "time-changed"
    ColorChanged {} -> "color-changed"
    CollectionSelectionChanged {} -> "collection-selection-changed"
    CollectionExpansionChanged {} -> "collection-expansion-changed"
    DisclosureChanged {} -> "disclosure-changed"
    PresentationClosed {} -> "presentation-closed"
    TabSelected {} -> "tab-selected"
    TabCloseRequested {} -> "tab-close-requested"
    PaneStateChanged {} -> "pane-state-changed"
    WindowCloseRequested {} -> "window-close-requested"
    WindowActivated {} -> "window-activated"
    SystemColorSchemeChanged {} -> "system-color-scheme-changed"
    TextFileChosen {} -> "text-file-chosen"
    ProjectFolderChosen {} -> "project-folder-chosen"
    DirectoryRead {} -> "directory-read"
    TextFileRead {} -> "text-file-read"
    OptionalTextFileRead {} -> "optional-text-file-read"
    TextFileWritten {} -> "text-file-written"

interpretEffect :: Runtime model -> BackendSession -> (UIEvent -> IO ()) -> Effect -> IO ()
interpretEffect runtime session dispatch effect = do
  traceRuntime runtime TraceDebug "effect.start" (effectTraceFields effect)
  attempted <- try (interpretEffectUnchecked session dispatch effect)
  case attempted of
    Right () -> traceRuntime runtime TraceDebug "effect.complete" (effectTraceFields effect)
    Left (exception :: SomeException) -> do
      traceRuntime runtime TraceError "effect.exception"
        (effectTraceFields effect <> [("exception", Text.pack (displayException exception))])
      throwIO exception

interpretEffectUnchecked :: BackendSession -> (UIEvent -> IO ()) -> Effect -> IO ()
interpretEffectUnchecked session dispatch = \case
  RequestOpenTextFiles -> session.backendRequestOpenTextFiles
  RequestOpenProjectFolder -> session.backendRequestOpenProjectFolder
  ReadDirectory path -> do
    result <- try (readDirectoryEntries path) :: IO (Either IOException [FileSystemEntry])
    dispatch $
      DirectoryRead path $
        case result of
          Left exception -> Left (Text.pack (displayException exception))
          Right entries -> Right entries
  ReadTextFile path -> do
    result <- try (ByteString.readFile path) :: IO (Either IOException ByteString.ByteString)
    dispatch $
      TextFileRead path $
        case result of
          Left exception -> Left (Text.pack (displayException exception))
          Right bytes ->
            case TextEncoding.decodeUtf8' (dropUtf8Bom bytes) of
              Left exception -> Left (Text.pack (displayException exception))
              Right contents -> Right contents
  ReadOptionalTextFile path -> do
    exists <- doesFileExist path
    if not exists
      then dispatch (OptionalTextFileRead path (Right Nothing))
      else do
        result <- try (ByteString.readFile path) :: IO (Either IOException ByteString.ByteString)
        dispatch $
          OptionalTextFileRead path $
            case result of
              Left exception -> Left (Text.pack (displayException exception))
              Right bytes ->
                case TextEncoding.decodeUtf8' (dropUtf8Bom bytes) of
                  Left exception -> Left (Text.pack (displayException exception))
                  Right contents -> Right (Just contents)
  WriteTextFile key path contents -> do
    result <- try (ByteString.writeFile path (TextEncoding.encodeUtf8 contents)) :: IO (Either IOException ())
    dispatch $
      TextFileWritten key path contents $
        case result of
          Left exception -> Left (Text.pack (displayException exception))
          Right () -> Right ()
  WriteTextFileAtomically key path contents -> do
    result <-
      try (writeTextFileAtomically path (TextEncoding.encodeUtf8 contents))
        :: IO (Either IOException ())
    dispatch $
      TextFileWritten key path contents $
        case result of
          Left exception -> Left (Text.pack (displayException exception))
          Right () -> Right ()

effectTraceFields :: Effect -> [(Text.Text, Text.Text)]
effectTraceFields effect =
  ("kind", effectKind effect) :
    case effect of
      RequestOpenTextFiles -> []
      RequestOpenProjectFolder -> []
      ReadDirectory path -> [("path", Text.pack path)]
      ReadTextFile path -> [("path", Text.pack path)]
      ReadOptionalTextFile path -> [("path", Text.pack path)]
      WriteTextFile key path contents -> writeFields key path contents
      WriteTextFileAtomically key path contents -> writeFields key path contents
  where
    writeFields :: EffectKey -> FilePath -> Text.Text -> [(Text.Text, Text.Text)]
    writeFields key path contents =
      [ ("effectKey", Text.pack (show key.unEffectKey))
      , ("path", Text.pack path)
      , ("characters", Text.pack (show (Text.length contents)))
      ]

effectKind :: Effect -> Text.Text
effectKind effect =
  case effect of
    RequestOpenTextFiles -> "request-open-text-files"
    RequestOpenProjectFolder -> "request-open-project-folder"
    ReadDirectory {} -> "read-directory"
    ReadTextFile {} -> "read-text-file"
    ReadOptionalTextFile {} -> "read-optional-text-file"
    WriteTextFile {} -> "write-text-file"
    WriteTextFileAtomically {} -> "write-text-file-atomically"

writeTextFileAtomically :: FilePath -> ByteString.ByteString -> IO ()
writeTextFileAtomically path bytes =
  bracketOnError
    (openBinaryTempFile (takeDirectory path) (takeFileName path <> ".tmp"))
    cleanupTemporaryFile
    (\(temporaryPath, handle) -> do
      ByteString.hPut handle bytes
      hFlush handle
      hClose handle
      renameFile temporaryPath path
    )

cleanupTemporaryFile :: (FilePath, Handle) -> IO ()
cleanupTemporaryFile (temporaryPath, handle) = do
  ignoreIOException (hClose handle)
  ignoreIOException (removeFile temporaryPath)

ignoreIOException :: IO () -> IO ()
ignoreIOException operation = do
  result <- try operation :: IO (Either IOException ())
  case result of
    Left _ -> pure ()
    Right () -> pure ()

dropUtf8Bom :: ByteString.ByteString -> ByteString.ByteString
dropUtf8Bom bytes =
  maybe bytes id (ByteString.stripPrefix (ByteString.pack [0xEF, 0xBB, 0xBF]) bytes)

readDirectoryEntries :: FilePath -> IO [FileSystemEntry]
readDirectoryEntries directory = do
  names <- listDirectory directory
  entries <- forM names $ \name -> do
    let path = normalise (directory </> name)
    isDirectory <- doesDirectoryExist path
    pure
      FileSystemEntry
        { fileSystemEntryPath = path
        , fileSystemEntryName = Text.pack name
        , fileSystemEntryKind =
            if isDirectory then FileSystemDirectory else FileSystemFile
        }
  pure (sortOn entryOrder entries)
  where
    entryOrder :: FileSystemEntry -> (Int, Text.Text)
    entryOrder entry =
      ( case entry.fileSystemEntryKind of
          FileSystemDirectory -> (0 :: Int)
          FileSystemFile -> 1
      , Text.toCaseFold entry.fileSystemEntryName
      )
