{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.STM
  ( atomically
  , newTQueueIO
  , readTQueue
  , writeTQueue
  )
import Control.Exception (bracket)
import Control.Monad (void, unless)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import qualified Data.Text as Text
import HaskeLUI.Core
import HaskeLUI.Runtime
import System.Directory
  ( createDirectory
  , getTemporaryDirectory
  , removeFile
  , removePathForcibly
  )
import System.FilePath ((</>))
import System.IO (hClose, openTempFile)
import VisualHaskell
  ( applicationWithEnvironment
  , firstDocumentEditorKey
  , outlineListKey
  , functionsListKey
  , functionCanvasKey
  , addFunctionCommand
  , clearFunctionsCommand
  )
import VisualHaskell.TextMate (defaultTextMateConfiguration)

main :: IO ()
main =
  bracket createFixture removePathForcibly $ \fixture -> do
    configuration <- defaultTextMateConfiguration (fixture </> "home")
    let workspaceRoot = fixture </> "workspace"
        sourcePath = workspaceRoot </> "src" </> "Fixture.hs"
        applicationValue =
          applicationWithEnvironment (fixture </> "last-workspace") configuration
    latestView <- newIORef (applicationValue.appView applicationValue.appInitialModel)
    runApp
      ( scriptedBackend latestView $ \dispatch -> do
          -- Reproduce the production ordering where the worker handshake may
          -- finish before the user trusts/opens a workspace.
          threadDelay 500000
          dispatch (ProjectFolderChosen workspaceRoot)
          dispatch (CommandInvoked (CommandId 13))
          dispatch (TextFileRead sourcePath (Right sourceText))
          analyzed <- waitForCompilerAnalysis latestView 150
          if analyzed
            then do
              view <- readIORef latestView
              case [item.collectionItemKey | window <- view.appWindows, ListView list <- windowLeafControls window,
                    list.collectionControlKey == outlineListKey, item <- list.collectionControlItems, item.collectionItemLabel == "value"] of
                key : _ -> dispatch (CollectionSelectionChanged outlineListKey [key])
                [] -> error "The declaration outline did not present the GHC signature"
              let offset = Text.length (fst (Text.breakOn "useValue = value" sourceText)) + Text.length "useValue = "
                  request key kind = TextQueryRequested firstDocumentEditorKey (TextQueryRequest key (TextRevision 0) offset kind)
              dispatch (request 101 TextHoverQuery)
              hovered <- waitForEditor latestView 100 (\editor -> case editor.textEditorAssistance >>= (.textAssistanceHover) of
                Just hover -> hover.textHoverKey == 101 && "Int" `Text.isInfixOf` hover.textHoverContent
                Nothing -> False)
              unless hovered (error "Typed hover did not reach the native editor contract")
              dispatch (TextQueryRequested firstDocumentEditorKey (TextQueryRequest 102 (TextRevision 0) (offset + 2) TextCompletionQuery))
              completed <- waitForEditor latestView 100 (\editor -> case editor.textEditorAssistance >>= (.textAssistanceCompletion) of
                Just completion -> "value" `elem` completion.textCompletionItems && completion.textCompletionRange == TextRange offset 2
                Nothing -> False)
              unless completed (error "Completion did not reach the native editor contract")
              dispatch (request 103 TextDefinitionQuery)
              defined <- waitForEditor latestView 100 (\editor -> case editor.textEditorNavigation of
                Just navigation -> navigation.textNavigationKey /= TextNavigationKey 1
                Nothing -> False)
              unless defined (error "Definition query did not navigate the source editor")
              let add name = do
                    current <- readIORef latestView
                    case [item.collectionItemKey | window <- current.appWindows, ListView list <- windowLeafControls window,
                          list.collectionControlKey == functionsListKey, item <- list.collectionControlItems, item.collectionItemLabel == name] of
                      key : _ -> do
                        dispatch (CollectionSelectionChanged functionsListKey [key])
                        dispatch (CommandInvoked addFunctionCommand)
                      [] -> error ("Function palette did not present " <> Text.unpack name)
                  connect = do
                    dispatch (pointer DrawingPointerDown (Point 336 127))
                    dispatch (pointer DrawingPointerUp (Point 386 127))
              add "toText"
              add "textLength"
              connect
              valid <- waitForComposition latestView 100 "Composes ::"
              unless valid (error "Canvas connection did not receive a valid inferred composition type")
              dispatch (CommandInvoked clearFunctionsCommand)
              add "toText"
              add "negateInt"
              connect
              invalid <- waitForComposition latestView 100 "Type mismatch"
              unless invalid (error "Canvas connection did not receive the GHC type mismatch")
              invalidView <- readIORef latestView
              unless (any (hasRedWire . (.drawingSurfaceDrawing))
                [surface | window <- invalidView.appWindows, DrawingSurface surface <- windowLeafControls window,
                 surface.drawingSurfaceKey == functionCanvasKey])
                (error "A rejected composition did not render a red wire")
              -- A query and an immediate edit deliberately race. Old responses
              -- must never decorate the newly edited revision.
              dispatch (request 104 TextHoverQuery)
              dispatch (TextChanged firstDocumentEditorKey brokenSourceText)
              problem <- waitForCompilerProblem latestView 150
              staleHover <- waitForEditor latestView 1 (\editor -> case editor.textEditorAssistance of
                Just assistance -> assistance.textAssistanceHover /= Nothing || assistance.textAssistanceCompletion /= Nothing
                Nothing -> False)
              unless (not staleHover) (error "An old query decorated an edited document")
              case problem of
                Just (listKey, itemKey) -> do
                  dispatch (CollectionSelectionChanged listKey [itemKey])
                  navigated <- waitForProblemNavigation latestView 50
                  if navigated
                    then dispatch (WindowCloseRequested (WindowKey 10))
                    else error "Visual Haskell did not reveal the selected compiler problem"
                Nothing -> error "Visual Haskell did not render the current compiler problem"
            else do
              currentView <- readIORef latestView
              error
                ( "Visual Haskell did not accept a current direct-GHC result; labels: "
                    <> show (labelTexts currentView)
                )
      )
      applicationValue
    putStrLn "Visual Haskell typed service accepted a current direct-GHC result"
  where
    sourceText = Text.unlines
      ["module Fixture where", "value :: Int", "value = 42", "useValue = value",
       "toText :: Int -> String", "toText = show", "textLength :: String -> Int", "textLength = length",
       "negateInt :: Int -> Int", "negateInt = negate"]
    brokenSourceText = "module Fixture where\nvalue :: Int\nvalue = missingName\n"

pointer :: DrawingPointerPhase -> Point -> UIEvent
pointer phase position = DrawingInputReceived functionCanvasKey (DrawingPointerInput
  (DrawingPointerEvent (DrawingPointerId 1) phase position (Point 0 0) (Just PrimaryPointerButton)
    noDrawingPointerButtons noDrawingModifiers 1 Nothing))

hasRedWire :: Drawing -> Bool
hasRedWire (Stroke _ (Solid (RGBA red green blue _)) (PathGeometry _)) = red > 0.8 && green < 0.4 && blue < 0.4
hasRedWire (Group children) = any hasRedWire children
hasRedWire (Clip _ _ child) = hasRedWire child
hasRedWire (Transform _ child) = hasRedWire child
hasRedWire _ = False

waitForComposition :: IORef AppView -> Int -> Text.Text -> IO Bool
waitForComposition _ 0 _ = pure False
waitForComposition latest attempts expected = do
  view <- readIORef latest
  if or [expected `Text.isInfixOf` attributedTextValue rich.richTextValue |
         window <- view.appWindows, RichText rich <- windowLeafControls window, rich.richTextKey == ElementKey 234]
    then pure True
    else threadDelay 100000 >> waitForComposition latest (attempts - 1) expected

waitForCompilerAnalysis :: IORef AppView -> Int -> IO Bool
waitForCompilerAnalysis _ 0 = pure False
waitForCompilerAnalysis latestView attempts = do
  view <- readIORef latestView
  if any (Text.isInfixOf "GHC: clean") (labelTexts view)
    then pure True
    else threadDelay 100000 >> waitForCompilerAnalysis latestView (attempts - 1)

waitForEditor :: IORef AppView -> Int -> (TextEditorSpec -> Bool) -> IO Bool
waitForEditor _ 0 _ = pure False
waitForEditor latest attempts predicate = do
  view <- readIORef latest
  if any predicate [editor | window <- view.appWindows, TextEditor editor <- windowLeafControls window]
    then pure True
    else threadDelay 100000 >> waitForEditor latest (attempts - 1) predicate

waitForCompilerProblem :: IORef AppView -> Int -> IO (Maybe (ElementKey, CollectionItemKey))
waitForCompilerProblem _ 0 = pure Nothing
waitForCompilerProblem latestView attempts = do
  view <- readIORef latestView
  case
      [ (collection.collectionControlKey, item.collectionItemKey)
      | window <- view.appWindows
      , ListView collection <- windowLeafControls window
      , item <- collection.collectionControlItems
      ] of
    problem : _
      | hasDiagnosticUnderline view -> pure (Just problem)
    _ -> threadDelay 100000 >> waitForCompilerProblem latestView (attempts - 1)

waitForProblemNavigation :: IORef AppView -> Int -> IO Bool
waitForProblemNavigation _ 0 = pure False
waitForProblemNavigation latestView attempts = do
  view <- readIORef latestView
  if
      or
        [ editor.textEditorNavigation /= Nothing
        | window <- view.appWindows
        , TextEditor editor <- windowLeafControls window
        ]
    then pure True
    else threadDelay 100000 >> waitForProblemNavigation latestView (attempts - 1)

hasDiagnosticUnderline :: AppView -> Bool
hasDiagnosticUnderline view =
  or
    [ spanValue.textSpanValue.textUnderline /= Nothing
        && spanValue.textSpanValue.textUnderlineColor /= Nothing
    | window <- view.appWindows
    , TextEditor editor <- windowLeafControls window
    , layer <- editor.textEditorLayers
    , spanValue <- layer.textLayerSpans
    ]

labelTexts :: AppView -> [Text.Text]
labelTexts view =
  [ contents
  | window <- view.appWindows
  , Label _ _ contents <- windowLeafControls window
  ]

scriptedBackend
  :: IORef AppView
  -> ((UIEvent -> IO ()) -> IO ())
  -> Backend
scriptedBackend latestView script =
  Backend $ \dispatch -> do
    uiQueue <- newTQueueIO
    let schedule action = atomically (writeTQueue uiQueue (Just action))
        stop = atomically (writeTQueue uiQueue Nothing)
        runUI = do
          next <- atomically (readTQueue uiQueue)
          maybe (pure ()) (\action -> action >> runUI) next
    void (forkIO runUI)
    pure
      BackendSession
        { backendRender = writeIORef latestView
        , backendScheduleOnUI = schedule
        , backendRequestOpenTextFiles = pure ()
        , backendRequestOpenProjectFolder = pure ()
        , backendRun = script dispatch
        , backendStop = stop
        , backendShutdown = pure ()
        }

createFixture :: IO FilePath
createFixture = do
  temporary <- getTemporaryDirectory
  (fixture, handle) <- openTempFile temporary "visual-haskell-analysis-service-"
  hClose handle
  removeFile fixture
  createDirectory fixture
  createDirectory (fixture </> "home")
  createDirectory (fixture </> "workspace")
  createDirectory (fixture </> "workspace" </> "src")
  writeFile (fixture </> "workspace" </> "src" </> "Fixture.hs") sourceText
  writeFile
    (fixture </> "workspace" </> "hie.yaml")
    "cradle:\n  direct:\n    arguments:\n      - -isrc\n      - src/Fixture.hs\n"
  pure fixture
  where
    sourceText = "module Fixture where\nvalue :: Int\nvalue = 42\n"
