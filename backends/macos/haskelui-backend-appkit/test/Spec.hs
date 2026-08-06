{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Main (main) where

import HaskeLUI.Backend.AppKit
import HaskeLUI.Backend.AppKit.Testing
  ( appKitResourcesReleased
  , queryAppKitDebugCounters
  )
import HaskeLUI.Core
import HaskeLUI.Runtime (runApp)

main :: IO ()
main = do
  capabilities <- queryAppKitCapabilities
  if capabilities.appKitVersion.macOSMajor > 0
    then pure ()
    else error "haskelui-backend-appkit: invalid macOS version"
  runApp appKitBackend asynchronousApplication
  counters <- queryAppKitDebugCounters
  if appKitResourcesReleased counters
    then
      putStrLn
        ( "haskelui-backend-appkit: task/service UI-thread delivery and clean shutdown passed on "
            <> show capabilities.appKitVersion
        )
    else error ("haskelui-backend-appkit: async runtime resources survived shutdown: " <> show counters)

asynchronousApplication :: App (Bool, Bool)
asynchronousApplication =
  (simpleApp (False, False) view (\_ _ -> noTransaction))
    { appInitialCommands =
        [ startTask
            (TaskKey "appkit.runtime.task")
            (WindowScope testWindowKey)
            ReplaceRunning
            "Deliver an AppKit task result"
            (const (pure ()))
            ( const $
                externalEvent "AppKit task delivered" $ \_ ->
                  transaction "Accept AppKit task" NoUndo (\(_, serviceDone) -> (True, serviceDone))
            )
        ]
    , appServices = [runtimeService]
    }
  where
    view (taskDone, serviceDone) =
      AppView
        [ WindowSpec testWindowKey "Runtime delivery" (Rect 120 120 320 180) []
        | not (taskDone && serviceDone)
        ]
        []

testWindowKey :: WindowKey
testWindowKey = WindowKey 88001

runtimeService :: Service (Bool, Bool)
runtimeService = worker
  where
    (worker, _endpoint :: ServiceEndpoint ()) =
      service
        (ServiceKey "appkit.runtime.service")
        "Deliver an AppKit service event"
        (defaultServiceOptions {serviceRestartPolicy = DoNotRestart})
        (\context ->
          emitExternalEvent context.serviceEvents $
            externalEvent "AppKit service delivered" $ \_ ->
              transaction "Accept AppKit service" NoUndo (\(taskDone, _) -> (taskDone, True))
        )
