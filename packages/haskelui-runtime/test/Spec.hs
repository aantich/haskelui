{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Main (main) where

import Control.Concurrent
  ( readChan
  , newChan
  , threadDelay
  , writeChan
  )
import Control.Exception
  ( SomeException
  , bracket
  , catch
  , throwIO
  )
import Control.Monad (unless, when)
import Data.IORef
  ( atomicModifyIORef'
  , modifyIORef'
  , newIORef
  , readIORef
  , writeIORef
  )
import qualified Data.Text as Text
import System.Directory
  ( createDirectory
  , getTemporaryDirectory
  , listDirectory
  , removeDirectoryRecursive
  , removeFile
  )
import System.FilePath ((</>))
import System.IO
  ( hClose
  , hPutStr
  , openTempFile
  )
import System.Timeout (timeout)
import HaskeLUI.Core
import HaskeLUI.Runtime

main :: IO ()
main = do
  testRenderDispatch
  bracket createFixture removeFile testFileRead
  bracket createDirectoryFixture removeDirectoryRecursive $ \path -> do
    testDirectoryRead path
    testInitialOptionalReadAndAtomicWrite path
  testMicroBatchOrdering
  testTaskUsesCurrentModel
  testReplacedTaskIsRejected
  testClosedLifetimeRejectsTask
  testTaskException
  testTypedService
  testServiceCommandCoalescing
  testServiceRestart
  testSubscriptionLifecycle
  putStrLn "haskelui-runtime: serialized events, tasks, services, subscriptions, restart, effects, and micro-batching passed"

testRenderDispatch :: IO ()
testRenderDispatch = do
  renderCount <- newIORef (0 :: Int)
  let closeCommand = CommandId 1
      testBackend =
        Backend $ \dispatch ->
          pure
            BackendSession
              { backendRender = const (modifyIORef' renderCount (+ 1))
              , backendScheduleOnUI = id
              , backendRequestOpenTextFiles = pure ()
              , backendRequestOpenProjectFolder = pure ()
              , backendRun = dispatch (CommandInvoked closeCommand)
              , backendStop = pure ()
              , backendShutdown = pure ()
              }
      testApp =
        App
          { appInitialModel = True
          , appInitialEffects = []
          , appInitialCommands = []
          , appServices = []
          , appSubscriptions = const []
          , appView = \open -> AppView [testWindow | open] []
          , appHandleEvent = \event _ ->
              case event of
                CommandInvoked command
                  | command == closeCommand -> transaction "Close" NoUndo (const False)
                _ -> noTransaction
          }

  runApp testBackend testApp
  actual <- readIORef renderCount
  if actual == 2 then pure () else error ("haskelui-runtime: expected two renders, got " <> show actual)
  where
    testWindow = WindowSpec (WindowKey 1) "Test" (Rect 0 0 100 100) []

testFileRead :: FilePath -> IO ()
testFileRead path = do
  latestTitle <- newIORef ""
  let backend =
        Backend $ \dispatch ->
          pure
            BackendSession
              { backendRender = \view ->
                  case view.appWindows of
                    window : _ -> writeIORef latestTitle window.windowTitle
                    [] -> pure ()
              , backendScheduleOnUI = id
              , backendRequestOpenTextFiles = pure ()
              , backendRequestOpenProjectFolder = pure ()
              , backendRun = dispatch (TextFileChosen path)
              , backendStop = pure ()
              , backendShutdown = pure ()
              }
      application =
        App
          { appInitialModel = Nothing
          , appInitialEffects = []
          , appInitialCommands = []
          , appServices = []
          , appSubscriptions = const []
          , appView = \contents ->
              AppView
                [WindowSpec (WindowKey 2) (maybe "Waiting" id contents) (Rect 0 0 100 100) []]
                []
          , appHandleEvent = \event _ ->
              case event of
                TextFileChosen chosen -> requestEffect "Read fixture" (ReadTextFile chosen)
                TextFileRead _ (Right contents) -> transaction "Store fixture" NoUndo (const (Just contents))
                TextFileRead _ (Left message) -> transaction "Store read error" NoUndo (const (Just message))
                _ -> noTransaction
          }
  runApp backend application
  actual <- readIORef latestTitle
  if actual == "runtime file effect\n"
    then pure ()
    else error ("haskelui-runtime: unexpected file-effect result " <> show actual)

testDirectoryRead :: FilePath -> IO ()
testDirectoryRead path = do
  latestTitle <- newIORef ""
  let backend =
        Backend $ \dispatch ->
          pure
            BackendSession
              { backendRender = \view ->
                  case view.appWindows of
                    window : _ -> writeIORef latestTitle window.windowTitle
                    [] -> pure ()
              , backendScheduleOnUI = id
              , backendRequestOpenTextFiles = pure ()
              , backendRequestOpenProjectFolder = pure ()
              , backendRun = dispatch (ProjectFolderChosen path)
              , backendStop = pure ()
              , backendShutdown = pure ()
              }
      application =
        App
          { appInitialModel = "Waiting"
          , appInitialEffects = []
          , appInitialCommands = []
          , appServices = []
          , appSubscriptions = const []
          , appView = \title -> AppView [WindowSpec (WindowKey 3) title (Rect 0 0 100 100) []] []
          , appHandleEvent = \event _ ->
              case event of
                ProjectFolderChosen chosen -> requestEffect "Read folder" (ReadDirectory chosen)
                DirectoryRead _ (Right entries) ->
                  transaction "Show entries" NoUndo
                    (const (Text.intercalate "," (fmap (.fileSystemEntryName) entries)))
                DirectoryRead _ (Left message) -> transaction "Show error" NoUndo (const message)
                _ -> noTransaction
          }
  runApp backend application
  actual <- readIORef latestTitle
  if actual == "src,README.md"
    then pure ()
    else error ("haskelui-runtime: unexpected directory-effect result " <> show actual)

testInitialOptionalReadAndAtomicWrite :: FilePath -> IO ()
testInitialOptionalReadAndAtomicWrite directory = do
  latestTitle <- newIORef "Waiting"
  let statePath = directory </> ".vihs"
      effectKey = EffectKey 99
      backend =
        Backend $ \_ ->
          pure
            BackendSession
              { backendRender = \view ->
                  case view.appWindows of
                    window : _ -> writeIORef latestTitle window.windowTitle
                    [] -> pure ()
              , backendScheduleOnUI = id
              , backendRequestOpenTextFiles = pure ()
              , backendRequestOpenProjectFolder = pure ()
              , backendRun = pure ()
              , backendStop = pure ()
              , backendShutdown = pure ()
              }
      application =
        App
          { appInitialModel = "Waiting"
          , appInitialEffects = [ReadOptionalTextFile statePath]
          , appInitialCommands = []
          , appServices = []
          , appSubscriptions = const []
          , appView = \title -> AppView [WindowSpec (WindowKey 4) title (Rect 0 0 100 100) []] []
          , appHandleEvent = \event _ ->
              case event of
                OptionalTextFileRead path (Right Nothing)
                  | path == statePath ->
                      transactionWithEffects
                        "Create state"
                        NoUndo
                        [WriteTextFileAtomically effectKey statePath "atomic state\n"]
                        id
                TextFileWritten key path _ (Right ())
                  | key == effectKey && path == statePath ->
                      transaction "Finish state write" NoUndo (const "Written")
                OptionalTextFileRead _ (Left message) ->
                  transaction "Show optional read error" NoUndo (const message)
                TextFileWritten _ _ _ (Left message) ->
                  transaction "Show atomic write error" NoUndo (const message)
                _ -> noTransaction
          }
  runApp backend application
  title <- readIORef latestTitle
  contents <- readFile statePath
  names <- listDirectory directory
  if title == "Written" && contents == "atomic state\n" && all (not . (".tmp" `Text.isInfixOf`) . Text.pack) names
    then pure ()
    else
      error
        ( "haskelui-runtime: optional/atomic startup effect failed: "
            <> show (title, contents, names)
        )

testMicroBatchOrdering :: IO ()
testMicroBatchOrdering = do
  renders <- newIORef (0 :: Int)
  backend <-
    queuedBackend
      (\_view -> do
        modifyIORef' renders (+ 1)
        pure ()
      )
      (\dispatch -> do
        dispatch (CommandInvoked (CommandId 201))
        dispatch (CommandInvoked (CommandId 202))
        dispatch (CommandInvoked (CommandId 203))
      )
  let application =
        App
          { appInitialModel = (0 :: Int, True)
          , appInitialEffects = []
          , appInitialCommands = []
          , appServices = []
          , appSubscriptions = const []
          , appView = \(value, open) ->
              AppView [WindowSpec (WindowKey 20) (Text.pack (show value)) (Rect 0 0 100 100) [] | open] []
          , appHandleEvent = \event _ ->
              case event of
                CommandInvoked (CommandId 201) -> transaction "First" NoUndo (\(_, open) -> (1, open))
                CommandInvoked (CommandId 202) -> transaction "Second" NoUndo (\(value, open) -> (value + 2, open))
                CommandInvoked (CommandId 203) -> transaction "Third" NoUndo (\(value, _) -> (value * 3, False))
                _ -> noTransaction
          }
  runWithTimeout "micro-batch" backend application
  renderCount <- readIORef renders
  assertEqual "micro-batch renders initial and final views once" 2 renderCount

data TaskModel = TaskModel
  { taskValue :: !Int
  , taskObservedValue :: !(Maybe Int)
  , taskWindowOpen :: !Bool
  }
  deriving stock (Eq, Show)

testTaskUsesCurrentModel :: IO ()
testTaskUsesCurrentModel = do
  backend <-
    queuedBackend
      (const (pure ()))
      (\dispatch -> do
        dispatch (CommandInvoked (CommandId 301))
        dispatch (CommandInvoked (CommandId 302))
      )
  observed <- newIORef (Nothing :: Maybe Int)
  let taskCommand =
        startTask
          (TaskKey "test.current-model")
          (WindowScope (WindowKey 30))
          ReplaceRunning
          "Return a task result"
          (const (pure (7 :: Int)))
          (\outcome ->
            externalEvent "Accept current-model task" $ \model ->
              transactionWithCommands
                "Accept task"
                NoUndo
                [ startTask
                    (TaskKey "test.current-model.close")
                    ApplicationScope
                    ReplaceRunning
                    "Close task fixture"
                    (const (threadDelay 1000))
                    (const (externalEvent "Close task fixture" $ \_ -> transaction "Close" NoUndo (\current -> current {taskWindowOpen = False})))
                ]
                ( \current ->
                    case outcome of
                      TaskSucceeded _ -> current {taskObservedValue = Just model.taskValue}
                      _ -> current
                )
          )
      application =
        App
          { appInitialModel = TaskModel 0 Nothing True
          , appInitialEffects = []
          , appInitialCommands = []
          , appServices = []
          , appSubscriptions = const []
          , appView = \model ->
              AppView
                [ WindowSpec
                    (WindowKey 30)
                    (maybe "pending" (Text.pack . show) model.taskObservedValue)
                    (Rect 0 0 100 100)
                    []
                | model.taskWindowOpen
                ]
                []
          , appHandleEvent = \event _ ->
              case event of
                CommandInvoked (CommandId 301) ->
                  transactionWithCommands "Start task" NoUndo [taskCommand] id
                CommandInvoked (CommandId 302) ->
                  transaction "Advance model" NoUndo (\model -> model {taskValue = model.taskValue + 1})
                _ -> noTransaction
          }
  recordingBackend <-
    mapBackendRender backend $ \view ->
      case view.appWindows of
        window : _ | window.windowTitle == "1" -> writeIORef observed (Just 1)
        _ -> pure ()
  runWithTimeout "current-model task" recordingBackend application
  actual <- readIORef observed
  assertEqual "task callback observes latest model" (Just 1) actual

testReplacedTaskIsRejected :: IO ()
testReplacedTaskIsRejected = do
  renderedResult <- newIORef ""
  backend <- queuedBackend (const (pure ())) (const (pure ()))
  let acceptResult result =
        externalEvent "Accept replacement result" $ \_ ->
          transactionWithCommands
            "Show replacement result"
            NoUndo
            [ startTask
                (TaskKey "test.replace.close")
                ApplicationScope
                ReplaceRunning
                "Close replacement fixture"
                (const (threadDelay 1000))
                (const (externalEvent "Close replacement fixture" $ \_ -> transaction "Close" NoUndo (\(_, _) -> ("", False))))
            ]
            (const (result, True))
      oldTask =
        startTask
          (TaskKey "test.replace")
          ApplicationScope
          ReplaceRunning
          "Old generation"
          ( \_ ->
              (threadDelay 100000 >> pure "old")
                `catch` \(_ :: SomeException) -> pure "old"
          )
          (\outcome -> acceptResult (case outcome of TaskSucceeded value -> value; _ -> "old-cancelled"))
      newTask =
        startTask
          (TaskKey "test.replace")
          ApplicationScope
          ReplaceRunning
          "New generation"
          (const (pure "new"))
          (\outcome -> acceptResult (case outcome of TaskSucceeded value -> value; _ -> "new-failed"))
      application =
        App
          { appInitialModel = ("pending", True)
          , appInitialEffects = []
          , appInitialCommands = [oldTask, newTask]
          , appServices = []
          , appSubscriptions = const []
          , appView = \(result, open) -> AppView [WindowSpec (WindowKey 32) result (Rect 0 0 100 100) [] | open] []
          , appHandleEvent = \_ _ -> noTransaction
          }
  observingBackend <-
    mapBackendRender backend $ \view ->
      case view.appWindows of
        window : _ | window.windowTitle /= "pending" -> writeIORef renderedResult window.windowTitle
        _ -> pure ()
  runWithTimeout "replaced task" observingBackend application
  result <- readIORef renderedResult
  assertEqual "old task generation is rejected even when cancellation is caught" "new" result

testClosedLifetimeRejectsTask :: IO ()
testClosedLifetimeRejectsTask = do
  badResultRendered <- newIORef False
  backend <- queuedBackend (const (pure ())) (const (pure ()))
  let lifetime = LifetimeKey "test.document-lifetime"
      ownedTask =
        startTask
          (TaskKey "test.lifetime.owned")
          (LifetimeScope lifetime)
          ReplaceRunning
          "Lifetime-owned task"
          ( \_ ->
              (threadDelay 100000 >> pure ())
                `catch` \(_ :: SomeException) -> pure ()
          )
          ( const $
              externalEvent "Late lifetime result" $ \_ ->
                transaction "Incorrectly accept late result" NoUndo (\(_, open) -> ("BAD", open))
          )
      closer =
        startTask
          (TaskKey "test.lifetime.close")
          ApplicationScope
          ReplaceRunning
          "Close lifetime fixture"
          (const (threadDelay 20000))
          (const (externalEvent "Close lifetime fixture" $ \_ -> transaction "Close" NoUndo (\(title, _) -> (title, False))))
      application =
        App
          { appInitialModel = ("safe", True)
          , appInitialEffects = []
          , appInitialCommands =
              [ openLifetime lifetime
              , ownedTask
              , closeLifetime lifetime
              , closer
              ]
          , appServices = []
          , appSubscriptions = const []
          , appView = \(title, open) -> AppView [WindowSpec (WindowKey 33) title (Rect 0 0 100 100) [] | open] []
          , appHandleEvent = \_ _ -> noTransaction
          }
  observingBackend <-
    mapBackendRender backend $ \view ->
      case view.appWindows of
        window : _ | window.windowTitle == "BAD" -> writeIORef badResultRendered True
        _ -> pure ()
  runWithTimeout "closed lifetime" observingBackend application
  bad <- readIORef badResultRendered
  assertEqual "closed lifetime rejects a cancellation-resistant completion" False bad

testTaskException :: IO ()
testTaskException = do
  outcomeReference <- newIORef Nothing
  backend <- queuedBackend (const (pure ())) (const (pure ()))
  let failingTask =
        startTask
          (TaskKey "test.failure")
          ApplicationScope
          ReplaceRunning
          "Fail safely"
          (\_ -> throwIO (userError "expected task failure") :: IO ())
          (\outcome ->
            externalEvent "Record task failure" $ \_ ->
              transaction "Close after task failure" NoUndo $ \open ->
                case outcome of
                  TaskFailed (TaskException _) -> False
                  _ -> open
          )
      application =
        App
          { appInitialModel = True
          , appInitialEffects = []
          , appInitialCommands = [failingTask]
          , appServices = []
          , appSubscriptions = const []
          , appView = \open -> AppView [WindowSpec (WindowKey 31) "Failure" (Rect 0 0 100 100) [] | open] []
          , appHandleEvent = \_ _ -> noTransaction
          }
  observingBackend <-
    mapBackendRender backend $ \view ->
      whenNoWindows view (writeIORef outcomeReference (Just True))
  runWithTimeout "task exception" observingBackend application
  actual <- readIORef outcomeReference
  assertEqual "task exception becomes data" (Just True) actual

data TestServiceCommand = TestServiceCommand !Text.Text
  deriving stock (Eq, Show)

testTypedService :: IO ()
testTypedService = do
  resultReference <- newIORef ""
  backend <- queuedBackend (const (pure ())) (const (pure ()))
  let (worker, endpoint) =
        service
          (ServiceKey "test.typed")
          "Typed test worker"
          (defaultServiceOptions {serviceRestartPolicy = DoNotRestart, serviceCommandCapacity = 2})
          (\context -> do
            received <- context.receiveCommand
            case received of
              Just (TestServiceCommand value) ->
                do
                  writeIORef resultReference value
                  emitExternalEvent context.serviceEvents $
                    externalEvent "Typed service response" $ \_ ->
                      transaction "Accept typed service response" NoUndo (const (value, False))
              Nothing -> pure ()
          )
      application =
        App
          { appInitialModel = ("", True)
          , appInitialEffects = []
          , appInitialCommands = [sendService endpoint (TestServiceCommand "typed")]
          , appServices = [worker]
          , appSubscriptions = const []
          , appView = \(result, open) ->
              AppView [WindowSpec (WindowKey 40) result (Rect 0 0 100 100) [] | open] []
          , appHandleEvent = \_ _ -> noTransaction
          }
  runWithTimeout "typed service" backend application
  actual <- readIORef resultReference
  assertEqual "typed service endpoint delivers matching command" "typed" actual

data CoalescedCommand = CoalescedCommand !Text.Text !Int
  deriving stock (Eq, Show)

testServiceCommandCoalescing :: IO ()
testServiceCommandCoalescing = do
  receivedRevision <- newIORef (0 :: Int)
  backend <- queuedBackend (const (pure ())) (const (pure ()))
  let options =
        defaultServiceOptions
          { serviceRestartPolicy = DoNotRestart
          , serviceCommandCapacity = 1
          , serviceOverflowPolicy = ReplacePendingCommand (\(CoalescedCommand document _) -> document)
          }
      (worker, endpoint) =
        service
          (ServiceKey "test.coalescing")
          "Coalescing test worker"
          options
          (\context -> do
            threadDelay 10000
            received <- context.receiveCommand
            case received of
              Just (CoalescedCommand _ revision) -> do
                writeIORef receivedRevision revision
                emitExternalEvent context.serviceEvents $
                  externalEvent "Coalesced command handled" $ \_ ->
                    transaction "Close coalescing fixture" NoUndo (const False)
              Nothing -> pure ()
          )
      application =
        App
          { appInitialModel = True
          , appInitialEffects = []
          , appInitialCommands =
              [ sendService endpoint (CoalescedCommand "Main.hs" 1)
              , sendService endpoint (CoalescedCommand "Main.hs" 2)
              ]
          , appServices = [worker]
          , appSubscriptions = const []
          , appView = \open -> AppView [WindowSpec (WindowKey 42) "Coalesce" (Rect 0 0 100 100) [] | open] []
          , appHandleEvent = \_ _ -> noTransaction
          }
  runWithTimeout "service command coalescing" backend application
  revision <- readIORef receivedRevision
  assertEqual "service retains newest pending command for a coalescing key" 2 revision

testServiceRestart :: IO ()
testServiceRestart = do
  starts <- newIORef (0 :: Int)
  backend <- queuedBackend (const (pure ())) (const (pure ()))
  let options =
        defaultServiceOptions
          { serviceRestartPolicy =
              RestartOnFailure
                defaultBackoffPolicy
                  { backoffInitialMilliseconds = 1
                  , backoffMaximumMilliseconds = 1
                  , backoffMaximumRestarts = 2
                  }
          }
      (worker, _endpoint :: ServiceEndpoint ()) =
        serviceWithStatus
          (ServiceKey "test.restart")
          "Restarting test worker"
          options
          (\status ->
            externalEvent "Record service status" $ \_ ->
              transaction "Record status" NoUndo (\(open, history) -> (open, history <> [status]))
          )
          (\context -> do
            invocation <- atomicModifyIORef' starts (\count -> let next = count + 1 in (next, next))
            if invocation == 1
              then throwIO (userError "restart me")
              else
                emitExternalEvent context.serviceEvents $
                  externalEvent "Service recovered" $ \_ ->
                    transaction "Close recovered service" NoUndo (\(_, history) -> (False, history))
          )
      application =
        App
          { appInitialModel = (True, [])
          , appInitialEffects = []
          , appInitialCommands = []
          , appServices = [worker]
          , appSubscriptions = const []
          , appView = \(open, _) -> AppView [WindowSpec (WindowKey 41) "Restart" (Rect 0 0 100 100) [] | open] []
          , appHandleEvent = \_ _ -> noTransaction
          }
  runWithTimeout "service restart" backend application
  count <- readIORef starts
  assertEqual "failed service restarts once" 2 count

testSubscriptionLifecycle :: IO ()
testSubscriptionLifecycle = do
  stops <- newIORef (0 :: Int)
  backend <- queuedBackend (const (pure ())) (const (pure ()))
  let watch =
        subscription
          (SubscriptionKey "test.subscription")
          (SubscriptionFingerprint "fixture-v1")
          (\sink -> do
            emitExternalEvent sink $
              externalEvent "Subscription fired" $ \_ ->
                transaction "Close subscription fixture" NoUndo (const False)
            pure (modifyIORef' stops (+ 1))
          )
      application =
        App
          { appInitialModel = True
          , appInitialEffects = []
          , appInitialCommands = []
          , appServices = []
          , appSubscriptions = \open -> [watch | open]
          , appView = \open -> AppView [WindowSpec (WindowKey 50) "Subscription" (Rect 0 0 100 100) [] | open] []
          , appHandleEvent = \_ _ -> noTransaction
          }
  runWithTimeout "subscription lifecycle" backend application
  threadDelay 10000
  stopped <- readIORef stops
  assertEqual "removed subscription executes stop action once" 1 stopped

queuedBackend
  :: (AppView -> IO ())
  -> ((UIEvent -> IO ()) -> IO ())
  -> IO Backend
queuedBackend render script = do
  scheduled <- newChan
  stopped <- newIORef False
  pure $
    Backend $ \dispatch ->
      pure
        BackendSession
          { backendRender = render
          , backendScheduleOnUI = writeChan scheduled
          , backendRequestOpenTextFiles = pure ()
          , backendRequestOpenProjectFolder = pure ()
          , backendRun = do
              script dispatch
              let loop = do
                    operation <- readChan scheduled
                    operation
                    finished <- readIORef stopped
                    unless finished loop
              loop
          , backendStop = do
              writeIORef stopped True
              writeChan scheduled (pure ())
          , backendShutdown = pure ()
          }

mapBackendRender :: Backend -> (AppView -> IO ()) -> IO Backend
mapBackendRender backend observe =
  pure $
    Backend $ \dispatch -> do
      session <- backend.openBackend dispatch
      pure session {backendRender = \view -> session.backendRender view >> observe view}

whenNoWindows :: AppView -> IO () -> IO ()
whenNoWindows view operation = when (null view.appWindows) operation

runWithTimeout :: String -> Backend -> App model -> IO ()
runWithTimeout label backend application = do
  completed <- timeout 3000000 (runApp backend application)
  case completed of
    Nothing -> error ("haskelui-runtime: timed out in " <> label)
    Just () -> pure ()

assertEqual :: (Eq value, Show value) => String -> value -> value -> IO ()
assertEqual label expected actual =
  if expected == actual
    then pure ()
    else error (label <> ": expected " <> show expected <> ", got " <> show actual)

createFixture :: IO FilePath
createFixture = do
  temporaryDirectory <- getTemporaryDirectory
  (path, handle) <- openTempFile temporaryDirectory "haskelui-runtime.txt"
  hPutStr handle "runtime file effect\n"
  hClose handle
  pure path

createDirectoryFixture :: IO FilePath
createDirectoryFixture = do
  temporaryDirectory <- getTemporaryDirectory
  (path, handle) <- openTempFile temporaryDirectory "haskelui-runtime-directory"
  hClose handle
  removeFile path
  createDirectory path
  createDirectory (path </> "src")
  writeFile (path </> "README.md") "fixture\n"
  pure path
