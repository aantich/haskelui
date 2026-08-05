{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

module UIH.Backend.AppKit
  ( AppKitCapabilities (..)
  , MacOSVersion (..)
  , appKitBackend
  , queryAppKitCapabilities
  ) where

import Control.Monad
  ( foldM
  , forM_
  , unless
  , when
  )
import qualified Data.ByteString as ByteString
import Data.Char (ord)
import Data.IORef
  ( IORef
  , newIORef
  , readIORef
  , writeIORef
  )
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import Data.Text.Encoding.Error (lenientDecode)
import Data.Word (Word64)
import Foreign.C (CInt, CString)
import Foreign.Ptr
  ( FunPtr
  , Ptr
  , freeHaskellFunPtr
  , nullPtr
  )
import UIH.Backend.AppKit.Internal.Capabilities
  ( AppKitCapabilities (..)
  , MacOSVersion (..)
  , queryAppKitCapabilities
  )
import UIH.Backend.AppKit.Internal.FFI
import UIH.Core
import UIH.Runtime
  ( Backend (..)
  , BackendSession (..)
  )

data NativeControl = NativeControl
  { nativeControlHandle :: !(Ptr MacControlHandle)
  , nativeControlSpec :: !Control
  }

data NativeWindow = NativeWindow
  { nativeWindowHandle :: !(Ptr MacWindowHandle)
  , nativeWindowSpec :: !WindowSpec
  , nativeWindowControls :: !(Map ElementKey NativeControl)
  }

data AppKitState = AppKitState
  { nativeWindows :: !(Map WindowKey NativeWindow)
  , nativeCommands :: !(Map CommandId CommandSpec)
  }

appKitBackend :: Backend
appKitBackend = Backend openAppKit

openAppKit :: (UIEvent -> IO ()) -> IO BackendSession
openAppKit dispatch = do
  callback <- makeEventCallback (receiveEvent dispatch)
  initialized <- c_initialize callback nullPtr
  unless (initialized /= 0) $ do
    freeHaskellFunPtr callback
    error "UIH AppKit backend could not initialize NSApplication"

  stateReference <- newIORef (AppKitState Map.empty Map.empty)
  pure
    BackendSession
      { backendRender = reconcile stateReference
      , backendRequestOpenTextFiles = c_openTextFiles
      , backendRun = c_run
      , backendStop = c_stop
      , backendShutdown = shutdown stateReference callback
      }

receiveEvent
  :: (UIEvent -> IO ())
  -> Ptr ()
  -> CInt
  -> Word64
  -> CString
  -> IO ()
receiveEvent dispatch _ eventKind identity textPointer =
  case eventKind of
    1 -> dispatch (CommandInvoked (CommandId identity))
    2 -> do
      changedText <- decodeText textPointer
      dispatch (TextChanged (ElementKey identity) changedText)
    3 -> dispatch (WindowCloseRequested (WindowKey identity))
    4 -> dispatch (WindowActivated (WindowKey identity))
    5 -> do
      path <- decodeText textPointer
      dispatch (TextFileChosen (Text.unpack path))
    _ -> pure ()

reconcile :: IORef AppKitState -> AppView -> IO ()
reconcile stateReference desired = do
  current <- readIORef stateReference
  commands <- reconcileCommands current.nativeCommands desired.appCommands
  windows <- reconcileWindows current.nativeWindows desired.appWindows
  writeIORef
    stateReference
    AppKitState
      { nativeWindows = windows
      , nativeCommands = commands
      }

reconcileCommands
  :: Map CommandId CommandSpec
  -> [CommandSpec]
  -> IO (Map CommandId CommandSpec)
reconcileCommands current desiredList = do
  let desired = Map.fromList [(spec.commandId, spec) | spec <- desiredList]
  forM_ (Map.keys current) $ \identifier ->
    unless (Map.member identifier desired) $
      c_commandRemove identifier.unCommandId
  forM_ (Map.elems desired) setCommand
  pure desired

setCommand :: CommandSpec -> IO ()
setCommand spec =
  withText spec.commandTitle $ \title ->
    withText (fromMaybe "" spec.commandKeyEquivalent) $ \keyEquivalent ->
      c_commandSet
        spec.commandId.unCommandId
        title
        keyEquivalent
        (booleanInt spec.commandEnabled)

reconcileWindows
  :: Map WindowKey NativeWindow
  -> [WindowSpec]
  -> IO (Map WindowKey NativeWindow)
reconcileWindows current desiredList = do
  let desired = Map.fromList [(spec.windowKey, spec) | spec <- desiredList]
  forM_ (Map.toList current) $ \(key, native) ->
    unless (Map.member key desired) (destroyWindow native)
  foldM reconcileOne Map.empty (Map.elems desired)
  where
    reconcileOne accumulated spec = do
      native <-
        case Map.lookup spec.windowKey current of
          Nothing -> createWindow spec
          Just existing -> updateWindow existing spec
      pure (Map.insert spec.windowKey native accumulated)

createWindow :: WindowSpec -> IO NativeWindow
createWindow spec =
  withText spec.windowTitle $ \title ->
    withMacRect spec.windowFrame $ \frame -> do
      handle <- c_createWindow spec.windowKey.unWindowKey title frame
      when (handle == nullPtr) (error "UIH AppKit failed to create NSWindow")
      controls <- foldM (createAndInsertControl handle) Map.empty spec.windowControls
      c_windowShow handle
      configureControlNavigation handle controls spec.windowControls
      pure
        NativeWindow
          { nativeWindowHandle = handle
          , nativeWindowSpec = spec
          , nativeWindowControls = controls
          }

updateWindow :: NativeWindow -> WindowSpec -> IO NativeWindow
updateWindow native desired = do
  when (native.nativeWindowSpec.windowTitle /= desired.windowTitle) $
    withText desired.windowTitle (c_windowSetTitle native.nativeWindowHandle)
  controls <-
    reconcileControls
      native.nativeWindowHandle
      native.nativeWindowControls
      desired.windowControls
  configureControlNavigation native.nativeWindowHandle controls desired.windowControls
  pure
    native
      { nativeWindowSpec = desired
      , nativeWindowControls = controls
      }

destroyWindow :: NativeWindow -> IO ()
destroyWindow native = do
  forM_ (Map.elems native.nativeWindowControls) destroyControl
  c_windowDestroy native.nativeWindowHandle

reconcileControls
  :: Ptr MacWindowHandle
  -> Map ElementKey NativeControl
  -> [Control]
  -> IO (Map ElementKey NativeControl)
reconcileControls window current desiredList = do
  let desired = Map.fromList [(controlKey spec, spec) | spec <- desiredList]
  forM_ (Map.toList current) $ \(key, native) ->
    unless (Map.member key desired) (destroyControl native)
  foldM reconcileOne Map.empty (Map.elems desired)
  where
    reconcileOne accumulated spec = do
      native <-
        case Map.lookup (controlKey spec) current of
          Nothing -> createControl window spec
          Just existing
            | controlsCompatible existing.nativeControlSpec spec ->
                updateControl window existing spec
            | otherwise -> do
                destroyControl existing
                createControl window spec
      pure (Map.insert (controlKey spec) native accumulated)

createAndInsertControl
  :: Ptr MacWindowHandle
  -> Map ElementKey NativeControl
  -> Control
  -> IO (Map ElementKey NativeControl)
createAndInsertControl window controls spec = do
  native <- createControl window spec
  pure (Map.insert (controlKey spec) native controls)

createControl :: Ptr MacWindowHandle -> Control -> IO NativeControl
createControl window spec = do
  handle <-
    case spec of
      Label key frame labelText ->
        withText labelText $ \text ->
          withMacRect frame (c_createLabel window key.unElementKey text)
      Button key frame title command enabled -> do
        created <-
          withText title $ \text ->
            withMacRect frame $
              c_createButton window key.unElementKey text command.unCommandId
        c_controlSetEnabled created (booleanInt enabled)
        pure created
      TextField key frame fieldText placeholderText focused -> do
        created <-
          withText fieldText $ \text ->
            withText placeholderText $ \placeholder ->
              withMacRect frame $
                c_createTextField window key.unElementKey text placeholder
        when focused (c_controlFocus window created)
        pure created
      TextEditor editor -> do
        created <-
          withText editor.textEditorText $ \text ->
            withMacRect editor.textEditorFrame $
              c_createTextEditor window editor.textEditorKey.unElementKey text
        when editor.textEditorFocused (c_controlFocus window created)
        pure created
  when (handle == nullPtr) (error "UIH AppKit failed to create native control")
  case spec of
    TextEditor editor -> applyTextEditorPresentation handle editor
    _ -> pure ()
  pure (NativeControl handle spec)

updateControl
  :: Ptr MacWindowHandle
  -> NativeControl
  -> Control
  -> IO NativeControl
updateControl window native desired = do
  withMacRect (controlFrame desired) (c_controlSetFrame native.nativeControlHandle)
  withText (controlText desired) (c_controlSetText native.nativeControlHandle)
  when (textEditorPresentationChanged native.nativeControlSpec desired) $
    case desired of
      TextEditor editor -> applyTextEditorPresentation native.nativeControlHandle editor
      _ -> pure ()
  case desired of
    Button _ _ _ _ enabled ->
      c_controlSetEnabled native.nativeControlHandle (booleanInt enabled)
    TextField _ _ _ _ focused ->
      when focused (c_controlFocus window native.nativeControlHandle)
    TextEditor editor ->
      when editor.textEditorFocused (c_controlFocus window native.nativeControlHandle)
    Label {} -> pure ()
  pure native {nativeControlSpec = desired}

destroyControl :: NativeControl -> IO ()
destroyControl = c_controlDestroy . nativeControlHandle

configureControlNavigation
  :: Ptr MacWindowHandle
  -> Map ElementKey NativeControl
  -> [Control]
  -> IO ()
configureControlNavigation window controls desired = do
  case navigationHandles of
    [] -> pure ()
    [_] -> pure ()
    handles ->
      forM_ (zip handles (drop 1 handles <> take 1 handles)) $ \(current, next) ->
        c_controlSetNextKey current next
  forM_ desired $ \case
    TextField key _ _ _ True ->
      forM_ (Map.lookup key controls) $ \native ->
        c_controlFocus window native.nativeControlHandle
    TextEditor editor
      | editor.textEditorFocused ->
          forM_ (Map.lookup editor.textEditorKey controls) $ \native ->
            c_controlFocus window native.nativeControlHandle
    _ -> pure ()
  where
    navigationHandles =
      [ native.nativeControlHandle
      | control <- desired
      , isKeyboardControl control
      , Just native <- [Map.lookup (controlKey control) controls]
      ]

isKeyboardControl :: Control -> Bool
isKeyboardControl Button {} = True
isKeyboardControl TextField {} = True
isKeyboardControl TextEditor {} = True
isKeyboardControl Label {} = False

controlKey :: Control -> ElementKey
controlKey = \case
  Label key _ _ -> key
  Button key _ _ _ _ -> key
  TextField key _ _ _ _ -> key
  TextEditor editor -> editor.textEditorKey

controlFrame :: Control -> Rect
controlFrame = \case
  Label _ frame _ -> frame
  Button _ frame _ _ _ -> frame
  TextField _ frame _ _ _ -> frame
  TextEditor editor -> editor.textEditorFrame

controlText :: Control -> Text
controlText = \case
  Label _ _ text -> text
  Button _ _ text _ _ -> text
  TextField _ _ text _ _ -> text
  TextEditor editor -> editor.textEditorText

controlsCompatible :: Control -> Control -> Bool
controlsCompatible (Label {}) (Label {}) = True
controlsCompatible (Button _ _ _ oldCommand _) (Button _ _ _ newCommand _) =
  oldCommand == newCommand
controlsCompatible (TextField _ _ _ oldPlaceholder _) (TextField _ _ _ newPlaceholder _) =
  oldPlaceholder == newPlaceholder
controlsCompatible (TextEditor {}) (TextEditor {}) = True
controlsCompatible _ _ = False

textEditorPresentationChanged :: Control -> Control -> Bool
textEditorPresentationChanged (TextEditor old) (TextEditor new) =
  old.textEditorText /= new.textEditorText
    || old.textEditorRevision /= new.textEditorRevision
    || old.textEditorBaseStyle /= new.textEditorBaseStyle
    || old.textEditorLayers /= new.textEditorLayers
textEditorPresentationChanged _ _ = False

applyTextEditorPresentation :: Ptr MacControlHandle -> TextEditorSpec -> IO ()
applyTextEditorPresentation handle editor = do
  c_textEditorBeginPresentation handle
  withCTextStyle editor.textEditorBaseStyle (c_textEditorSetBaseStyle handle)
  let scalarLength = Text.length editor.textEditorText
      offsets =
        Map.fromDistinctAscList $
          zip [0 ..] (scanl advanceUtf16 0 (Text.unpack editor.textEditorText))
      resolved =
        resolveTextLayers
          scalarLength
          editor.textEditorBaseStyle
          editor.textEditorRevision
          editor.textEditorLayers
  forM_ resolved $ \textSpan -> do
    let range = textSpan.textSpanRange
        start = range.textRangeStart
        end = start + range.textRangeLength
    case (Map.lookup start offsets, Map.lookup end offsets) of
      (Just utf16Start, Just utf16End) ->
        withCTextStyle textSpan.textSpanValue $ \style -> do
          applied <-
            c_textEditorApplyStyle
              handle
              utf16Start
              (utf16End - utf16Start)
              style
          unless (applied /= 0) $
            error "UIH AppKit rejected a validated text presentation range"
      _ -> error "UIH AppKit could not translate a validated Unicode text range"
  c_textEditorEndPresentation handle
  where
    advanceUtf16 offset character =
      offset + if ord character > 0xFFFF then 2 else 1

shutdown :: IORef AppKitState -> FunPtr EventCallback -> IO ()
shutdown stateReference callback = do
  state <- readIORef stateReference
  forM_ (Map.elems state.nativeWindows) destroyWindow
  forM_ (Map.keys state.nativeCommands) (c_commandRemove . unCommandId)
  writeIORef stateReference (AppKitState Map.empty Map.empty)
  c_shutdown
  freeHaskellFunPtr callback

withText :: Text -> (CString -> IO result) -> IO result
withText value = ByteString.useAsCString (TextEncoding.encodeUtf8 value)

decodeText :: CString -> IO Text
decodeText pointer
  | pointer == nullPtr = pure ""
  | otherwise =
        TextEncoding.decodeUtf8With lenientDecode <$> ByteString.packCString pointer

booleanInt :: Bool -> CInt
booleanInt True = 1
booleanInt False = 0
