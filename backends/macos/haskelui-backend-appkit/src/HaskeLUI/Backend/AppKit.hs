{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

module HaskeLUI.Backend.AppKit
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
import Control.Applicative ((<|>))
import Data.Bits (testBit)
import qualified Data.ByteString as ByteString
import Data.Char (ord)
import Data.Foldable (traverse_)
import Data.IORef
  ( IORef
  , atomicModifyIORef'
  , newIORef
  , readIORef
  , writeIORef
  )
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe, isJust)
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import Data.Text.Encoding.Error (lenientDecode)
import Data.Word (Word64)
import Foreign (alloca, peek)
import Foreign.C (CDouble, CInt, CString)
import Foreign.Marshal.Array (withArray)
import Foreign.Ptr
  ( FunPtr
  , Ptr
  , freeHaskellFunPtr
  , nullPtr
  )
import HaskeLUI.Backend.AppKit.Internal.Capabilities
  ( AppKitCapabilities (..)
  , MacOSVersion (..)
  , queryAppKitCapabilities
  )
import HaskeLUI.Backend.AppKit.Internal.FFI
import HaskeLUI.Core
import HaskeLUI.Runtime
  ( Backend (..)
  , BackendSession (..)
  )
import Text.Read (readMaybe)

data CatalogItem = CatalogItem
  { catalogItemIdentity :: !Word64
  , catalogItemLabel :: !Text
  , catalogItemDetail :: !Text
  , catalogItemIcon :: !Text
  , catalogItemDepth :: !Int
  , catalogItemEnabled :: !Bool
  , catalogItemSelected :: !Bool
  , catalogItemExpanded :: !Bool
  , catalogItemExpandable :: !Bool
  , catalogItemSeparator :: !Bool
  , catalogItemCommand :: !(Maybe CommandId)
  }

data NativeControl = NativeControl
  { nativeControlHandle :: !(Ptr MacControlHandle)
  , nativeControlSpec :: !Control
  , nativeControlMetrics :: !(Maybe IntrinsicMetrics)
  }

data NativeWindow = NativeWindow
  { nativeWindowHandle :: !(Ptr MacWindowHandle)
  , nativeWindowSpec :: !WindowSpec
  , nativeWindowControls :: !(Map ElementKey NativeControl)
  , nativeLayoutAllocations :: !(Map ElementKey Size)
  }

data AppKitState = AppKitState
  { nativeWindows :: !(Map WindowKey NativeWindow)
  , nativeCommands :: !(Map CommandId CommandSpec)
  }

appKitBackend :: Backend
appKitBackend = Backend openAppKit

openAppKit :: (UIEvent -> IO ()) -> IO BackendSession
openAppKit dispatch = do
  scheduledActions <- newIORef []
  stateReference <- newIORef (AppKitState Map.empty Map.empty)
  callback <- makeEventCallback (receiveEvent dispatch (drainScheduledActions scheduledActions))
  drawingInputCallback <- makeDrawingInputCallback (receiveDrawingInput dispatch)
  layoutAllocationCallback <-
    makeLayoutAllocationCallback (receiveLayoutAllocation stateReference)
  initialized <- c_initialize callback nullPtr
  unless (initialized /= 0) $ do
    freeHaskellFunPtr callback
    freeHaskellFunPtr drawingInputCallback
    freeHaskellFunPtr layoutAllocationCallback
    error "HaskeLUI AppKit backend could not initialize NSApplication"
  c_setDrawingInputCallback drawingInputCallback nullPtr
  c_setLayoutAllocationCallback layoutAllocationCallback nullPtr

  pure
    BackendSession
      { backendRender = reconcile stateReference
      , backendScheduleOnUI = scheduleOnUI scheduledActions
      , backendRequestOpenTextFiles = c_openTextFiles
      , backendRequestOpenProjectFolder = c_openProjectFolder
      , backendRun = c_run
      , backendStop = c_stop
      , backendShutdown =
          shutdown
            stateReference
            callback
            drawingInputCallback
            layoutAllocationCallback
      }

scheduleOnUI :: IORef [IO ()] -> IO () -> IO ()
scheduleOnUI scheduledActions operation = do
  atomicModifyIORef' scheduledActions $ \pending -> (operation : pending, ())
  c_scheduleRuntimeWake

drainScheduledActions :: IORef [IO ()] -> IO ()
drainScheduledActions scheduledActions = do
  pending <- atomicModifyIORef' scheduledActions $ \operations -> ([], reverse operations)
  sequence_ pending

receiveEvent
  :: (UIEvent -> IO ())
  -> IO ()
  -> Ptr ()
  -> CInt
  -> Word64
  -> CString
  -> IO ()
receiveEvent dispatch drainRuntime _ eventKind identity textPointer =
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
    6 -> dispatch (TabSelected (TabKey identity))
    7 -> dispatch (TabCloseRequested (TabKey identity))
    8 -> dispatch (ControlInvoked (ElementKey identity))
    9 -> do
      payload <- decodeText textPointer
      dispatch (ToggleChanged (ElementKey identity) (decodeToggle payload))
    10 -> do
      payload <- decodeText textPointer
      dispatch
        ( ChoiceChanged
            (ElementKey identity)
            (ChoiceKey <$> readText payload)
        )
    11 -> do
      payload <- decodeText textPointer
      forM_ (readText payload) $ \value ->
        dispatch (NumberChanged (ElementKey identity) value)
    12 -> do
      payload <- decodeText textPointer
      forM_ (decodeDateTime payload) $ \(date, _) ->
        dispatch (DateChanged (ElementKey identity) date)
    13 -> do
      payload <- decodeText textPointer
      forM_ (decodeDateTime payload) $ \(_, time) ->
        dispatch (TimeChanged (ElementKey identity) time)
    14 -> do
      payload <- decodeText textPointer
      forM_ (decodeColor payload) $ \color ->
        dispatch (ColorChanged (ElementKey identity) color)
    15 -> do
      payload <- decodeText textPointer
      dispatch
        ( CollectionSelectionChanged
            (ElementKey identity)
            (CollectionItemKey <$> decodeWords payload)
        )
    16 -> do
      payload <- decodeText textPointer
      dispatch (DisclosureChanged (ElementKey identity) (payload /= "0"))
    17 -> do
      payload <- decodeText textPointer
      dispatch (PresentationClosed (ElementKey identity) (decodePresentationResult payload))
    18 -> do
      payload <- decodeText textPointer
      forM_ (decodeExpansion payload) $ \(item, expanded) ->
        dispatch
          (CollectionExpansionChanged (ElementKey identity) (CollectionItemKey item) expanded)
    19 -> do
      path <- decodeText textPointer
      dispatch (ProjectFolderChosen (Text.unpack path))
    20 -> drainRuntime
    21 -> do
      payload <- decodeText textPointer
      dispatch
        ( SystemColorSchemeChanged $
            if payload == "dark" then DarkColorScheme else LightColorScheme
        )
    22 -> do
      payload <- decodeText textPointer
      forM_ (decodePaneState payload) $ \paneState ->
        dispatch (PaneStateChanged (PaneKey identity) paneState)
    _ -> pure ()

receiveDrawingInput
  :: (UIEvent -> IO ())
  -> Ptr ()
  -> Word64
  -> Ptr CDrawingInput
  -> IO ()
receiveDrawingInput dispatch _ identity inputPointer
  | inputPointer == nullPtr = pure ()
  | otherwise = do
      input <- peek inputPointer
      let position = Point (realToFrac input.cDrawingX) (realToFrac input.cDrawingY)
          delta = Point (realToFrac input.cDrawingDeltaX) (realToFrac input.cDrawingDeltaY)
          modifiers =
            DrawingModifiers
              (testBit input.cDrawingModifiers 0)
              (testBit input.cDrawingModifiers 1)
              (testBit input.cDrawingModifiers 2)
              (testBit input.cDrawingModifiers 3)
          buttons =
            DrawingPointerButtons
              (testBit input.cDrawingButtons 0)
              (testBit input.cDrawingButtons 1)
              (testBit input.cDrawingButtons 2)
              (testBit input.cDrawingButtons 3)
              (testBit input.cDrawingButtons 4)
          emit payload = dispatch (DrawingInputReceived (ElementKey identity) payload)
      if input.cDrawingInputKind == 7
        then
          emit . DrawingScrollInput $
            DrawingScrollEvent
              { drawingScrollPosition = position
              , drawingScrollDelta = delta
              , drawingScrollIsPrecise = input.cDrawingPrecise /= 0
              , drawingScrollModifiers = modifiers
              , drawingScrollTarget = Nothing
              }
        else
          traverse_
            (\phase ->
              emit . DrawingPointerInput $
                DrawingPointerEvent
                  { drawingPointerId = DrawingPointerId input.cDrawingPointerIdentity
                  , drawingPointerPhase = phase
                  , drawingPointerPosition = position
                  , drawingPointerDelta = delta
                  , drawingPointerChangedButton = decodeDrawingButton input.cDrawingChangedButton
                  , drawingPointerButtons = buttons
                  , drawingPointerModifiers = modifiers
                  , drawingPointerClickCount = fromIntegral input.cDrawingClickCount
                  , drawingPointerTarget = Nothing
                  }
            )
            (decodeDrawingPhase input.cDrawingInputKind)

-- Native allocation changes are backend bookkeeping, not application events.
-- Re-solving here keeps the declarative model independent of window sizes and
-- preserves focus because only the resulting frames are committed.
receiveLayoutAllocation
  :: IORef AppKitState
  -> Ptr ()
  -> Word64
  -> Word64
  -> CDouble
  -> CDouble
  -> IO ()
receiveLayoutAllocation stateReference _ windowIdentity controlIdentity nativeWidth nativeHeight = do
  let width = realToFrac nativeWidth :: Double
      height = realToFrac nativeHeight :: Double
  when
    ( width > 0
        && height > 0
        && not (isNaN width || isInfinite width || isNaN height || isInfinite height)
    ) $ do
      state <- readIORef stateReference
      let nativeWindowKey = WindowKey windowIdentity
          elementKey = ElementKey controlIdentity
          allocation = Size (Dp width) (Dp height)
      case Map.lookup nativeWindowKey state.nativeWindows of
        Just native
          | Just control <- Map.lookup elementKey native.nativeWindowControls
          , LayoutContainer {} <- control.nativeControlSpec
          , Map.lookup elementKey native.nativeLayoutAllocations /= Just allocation -> do
              updated <-
                reflowNativeWindow
                  native
                    { nativeLayoutAllocations =
                        Map.insert elementKey allocation native.nativeLayoutAllocations
                    }
              writeIORef
                stateReference
                state
                  { nativeWindows = Map.insert nativeWindowKey updated state.nativeWindows
                  }
        _ -> pure ()

decodeDrawingPhase :: CInt -> Maybe DrawingPointerPhase
decodeDrawingPhase 1 = Just DrawingPointerDown
decodeDrawingPhase 2 = Just DrawingPointerMoved
decodeDrawingPhase 3 = Just DrawingPointerUp
decodeDrawingPhase 4 = Just DrawingPointerCancelled
decodeDrawingPhase 5 = Just DrawingPointerEntered
decodeDrawingPhase 6 = Just DrawingPointerExited
decodeDrawingPhase _ = Nothing

decodeDrawingButton :: CInt -> Maybe DrawingPointerButton
decodeDrawingButton 0 = Just PrimaryPointerButton
decodeDrawingButton 1 = Just SecondaryPointerButton
decodeDrawingButton 2 = Just MiddlePointerButton
decodeDrawingButton 3 = Just BackPointerButton
decodeDrawingButton 4 = Just ForwardPointerButton
decodeDrawingButton _ = Nothing

readText :: Read value => Text -> Maybe value
readText = readMaybe . Text.unpack

decodeToggle :: Text -> ToggleValue
decodeToggle "0" = ToggleOff
decodeToggle "-1" = ToggleMixed
decodeToggle _ = ToggleOn

decodePaneState :: Text -> Maybe PaneState
decodePaneState payload =
  case Text.splitOn "|" payload of
    [visibilityText, extentText] -> do
      visibility <-
        case visibilityText of
          "visible" -> Just PaneVisible
          "collapsed" -> Just PaneCollapsed
          _ -> Nothing
      extent <- readText extentText
      pure (PaneState visibility (Just extent))
    _ -> Nothing

decodeWords :: Text -> [Word64]
decodeWords value =
  [ parsed
  | component <- Text.splitOn "," value
  , not (Text.null component)
  , Just parsed <- [readText component]
  ]

decodeDateTime :: Text -> Maybe (DateComponents, TimeComponents)
decodeDateTime value =
  case Text.splitOn "T" value of
    [dateText, timeText] -> do
      [year, month, day] <- traverse readText (Text.splitOn "-" dateText)
      [hour, minute, second] <- traverse readText (Text.splitOn ":" timeText)
      pure
        ( DateComponents year month day
        , TimeComponents hour minute second
        )
    _ -> Nothing

decodeColor :: Text -> Maybe Color
decodeColor value =
  case traverse readText (Text.splitOn "," value) of
    Just [red, green, blue, alpha] -> Just (RGBA red green blue alpha)
    _ -> Nothing

decodePresentationResult :: Text -> PresentationResult
decodePresentationResult value
  | Just encodedIdentity <- Text.stripPrefix "action:" value
  , Just identity <- readMaybe (Text.unpack encodedIdentity) =
      PresentationActionSelected (PresentationActionId identity)
decodePresentationResult "accepted" = PresentationAccepted
decodePresentationResult "cancelled" = PresentationCancelled
decodePresentationResult _ = PresentationDismissed

decodeExpansion :: Text -> Maybe (Word64, Bool)
decodeExpansion value =
  case Text.splitOn "," value of
    [item, expanded] -> do
      parsed <- readText item
      pure (parsed, expanded /= "0")
    _ -> Nothing

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
          Just existing
            | windowKindsCompatible existing.nativeWindowSpec spec ->
                updateWindow existing spec
            | otherwise -> do
                destroyWindow existing
                createWindow spec
      pure (Map.insert spec.windowKey native accumulated)

windowKindsCompatible :: WindowSpec -> WindowSpec -> Bool
windowKindsCompatible old new =
  isJust (windowWorkspace old) == isJust (windowWorkspace new)

createWindow :: WindowSpec -> IO NativeWindow
createWindow spec =
  withText spec.windowTitle $ \title ->
    withMacRect spec.windowFrame $ \frame -> do
      handle <- c_createWindow spec.windowKey.unWindowKey title frame
      when (handle == nullPtr) (error "HaskeLUI AppKit failed to create NSWindow")
      forM_ (windowWorkspace spec) (configureWorkspaceStructure handle)
      let desiredControls = windowLeafControls spec
      created <- foldM (createAndInsertControl handle) Map.empty desiredControls
      (resolvedSpec, measured) <- resolveNativeLayouts created Map.empty spec
      controls <- commitPortableLayoutFrames handle measured resolvedSpec
      forM_ (windowWorkspace resolvedSpec) (configureWorkspaceParents handle controls)
      configureNestedControlParents controls (windowRootControls resolvedSpec)
      c_windowShow handle
      configureControlNavigation handle controls (windowLeafControls resolvedSpec)
      pure
        NativeWindow
          { nativeWindowHandle = handle
          , nativeWindowSpec = resolvedSpec
          , nativeWindowControls = controls
          , nativeLayoutAllocations = Map.empty
          }

updateWindow :: NativeWindow -> WindowSpec -> IO NativeWindow
updateWindow native desired = do
  when (native.nativeWindowSpec.windowTitle /= desired.windowTitle) $
    withText desired.windowTitle (c_windowSetTitle native.nativeWindowHandle)
  forM_ (windowWorkspace desired) (configureWorkspaceStructure native.nativeWindowHandle)
  let desiredControls = windowLeafControls desired
  reconciled <-
    reconcileControls
      native.nativeWindowHandle
      native.nativeWindowControls
      desiredControls
  (resolvedDesired, measured) <-
    resolveNativeLayouts reconciled native.nativeLayoutAllocations desired
  controls <- commitPortableLayoutFrames native.nativeWindowHandle measured resolvedDesired
  forM_ (windowWorkspace resolvedDesired) (configureWorkspaceParents native.nativeWindowHandle controls)
  configureNestedControlParents controls (windowRootControls resolvedDesired)
  configureControlNavigation native.nativeWindowHandle controls (windowLeafControls resolvedDesired)
  pure
    native
      { nativeWindowSpec = resolvedDesired
      , nativeWindowControls = controls
      }

data ControlParent
  = ParentItem !WorkspaceItemKey !Bool
  | ParentTab !TabGroupKey !TabKey !Bool
  | ParentStatus !Bool
  | ParentControl !ElementKey !Word64 !Bool

windowRootControls :: WindowSpec -> [Control]
windowRootControls WindowSpec {windowControls = controls} = controls
windowRootControls WorkspaceWindowSpec {windowWorkspaceSpec = spec} = workspaceControlsForParents spec

workspaceControlsForParents :: WorkspaceSpec -> [Control]
workspaceControlsForParents spec =
  paneTreeRootControls spec.workspaceRoot <> spec.workspaceStatusControls

paneTreeRootControls :: PaneTree -> [Control]
paneTreeRootControls (WorkspacePane pane) =
  case pane.workspacePaneItem.workspaceItemContent of
    WorkspaceItemControls controls -> controls
    WorkspaceItemTabGroup group -> foldMap workspaceTabControls group.workspaceTabs
paneTreeRootControls (WorkspaceSplit _ _ first second rest) =
  foldMap paneTreeRootControls (first : second : rest)

configureWorkspaceStructure :: Ptr MacWindowHandle -> WorkspaceSpec -> IO ()
configureWorkspaceStructure window spec = do
  case validateWorkspaceSpec spec of
    [] -> pure ()
    diagnostics ->
      error ("Invalid HaskeLUI workspace: " <> Text.unpack (Text.intercalate "; " diagnostics))
  (orientation, panes) <-
    either (error . Text.unpack) pure (flattenWorkspaceRoot spec.workspaceRoot)
  c_workspaceBegin window (booleanInt (orientation == SideBySide)) 28
  forM_ panes $ \pane -> do
    c_workspacePaneSet
      window
      pane.workspacePaneKey.unPaneKey
      (encodePaneRole pane.workspacePaneRole)
      (encodeOptionalExtent pane.workspacePaneSizing.paneMinimumExtent)
      (realToFrac (paneExtentForLayout pane))
      (encodeOptionalExtent pane.workspacePaneSizing.paneMaximumExtent)
      (realToFrac pane.workspacePaneSizing.paneStretchWeight)
      (booleanInt (pane.workspacePaneState.paneVisibility == PaneCollapsed))
    c_workspaceItemSet
      window
      pane.workspacePaneKey.unPaneKey
      pane.workspacePaneItem.workspaceItemKey.unWorkspaceItemKey
    case pane.workspacePaneItem.workspaceItemContent of
      WorkspaceItemControls _ -> pure ()
      WorkspaceItemTabGroup tabGroup -> do
        c_workspaceTabGroupSet
          window
          pane.workspacePaneItem.workspaceItemKey.unWorkspaceItemKey
          tabGroup.workspaceTabGroupKey.unTabGroupKey
        forM_ tabGroup.workspaceTabs $ \tab ->
          withText tab.workspaceTabTitle $ \title ->
            c_workspaceTabSet
              window
              tabGroup.workspaceTabGroupKey.unTabGroupKey
              tab.workspaceTabKey.unTabKey
              title
              (booleanInt tab.workspaceTabModified)
              (booleanInt tab.workspaceTabCloseable)
              (booleanInt (tabGroup.workspaceSelectedTab == Just tab.workspaceTabKey))
  c_workspaceEnd window

flattenWorkspaceRoot
  :: PaneTree
  -> Either Text (SplitOrientation, [WorkspacePaneSpec])
flattenWorkspaceRoot (WorkspacePane pane) = Right (SideBySide, [pane])
flattenWorkspaceRoot (WorkspaceSplit _ orientation first second rest) =
  case traverse directPane (first : second : rest) of
    Just panes -> Right (orientation, panes)
    Nothing ->
      Left
        "The AppKit vertical slice currently supports one split level; nested PaneTree rendering is not implemented"

directPane :: PaneTree -> Maybe WorkspacePaneSpec
directPane (WorkspacePane pane) = Just pane
directPane WorkspaceSplit {} = Nothing

paneExtentForLayout :: WorkspacePaneSpec -> Double
paneExtentForLayout pane =
  fromMaybe 0 $
    pane.workspacePaneState.paneExtent
      <|> pane.workspacePaneSizing.panePreferredExtent

encodeOptionalExtent :: Maybe Double -> CDouble
encodeOptionalExtent = realToFrac . fromMaybe (-1)

encodePaneRole :: PaneRole -> CInt
encodePaneRole SidebarPane = 0
encodePaneRole ContentPane = 1
encodePaneRole InspectorPane = 2
encodePaneRole AuxiliaryPane = 3

configureWorkspaceParents
  :: Ptr MacWindowHandle
  -> Map ElementKey NativeControl
  -> WorkspaceSpec
  -> IO ()
configureWorkspaceParents window controls spec =
  forM_ (Map.toList (workspaceControlParents spec)) $ \(key, parent) ->
    forM_ (Map.lookup key controls) $ \native ->
      case parent of
        ParentItem item fill ->
          c_controlSetParentItem
            window
            native.nativeControlHandle
            item.unWorkspaceItemKey
            (booleanInt fill)
        ParentTab tabGroup tab fill ->
          c_controlSetParentTab
            window
            native.nativeControlHandle
            tabGroup.unTabGroupKey
            tab.unTabKey
            (booleanInt fill)
        ParentStatus fill ->
          c_controlSetParentStatus window native.nativeControlHandle (booleanInt fill)
        ParentControl {} -> pure ()

configureNestedControlParents
  :: Map ElementKey NativeControl
  -> [Control]
  -> IO ()
configureNestedControlParents controls roots =
  forM_ (nestedControlParents roots) $ \(childKey, parentKey, slot, fill) ->
    case (Map.lookup parentKey controls, Map.lookup childKey controls) of
      (Just parent, Just child) ->
        c_controlSetParentControl
          parent.nativeControlHandle
          child.nativeControlHandle
          slot
          (booleanInt fill)
      _ -> pure ()

nestedControlParents :: [Control] -> [(ElementKey, ElementKey, Word64, Bool)]
nestedControlParents = foldMap descendants
  where
    descendants control =
      case control of
        Container spec ->
          childRelations spec.containerKey 0 spec.containerChildren
            <> foldMap descendants spec.containerChildren
        LayoutContainer spec ->
          [ (controlKey child, spec.layoutContainerKey, 0, False)
          | child <- spec.layoutContainerChildren
          ]
            <> foldMap descendants spec.layoutContainerChildren
        TabView spec ->
          foldMap
            (\page ->
              childRelations
                spec.tabViewKey
                page.tabPageKey.unChoiceKey
                page.tabPageControls
                <> foldMap descendants page.tabPageControls
            )
            spec.tabViewPages
        _ -> []
    childRelations parent slot children =
      let fill = singleFillControl children
       in [(controlKey child, parent, slot, fill) | child <- children]

workspaceControlParents :: WorkspaceSpec -> Map ElementKey ControlParent
workspaceControlParents spec =
  Map.fromList
    (paneTreeControlParents spec.workspaceRoot <> statusParents)
  where
    statusParents =
      [ (controlKey control, ParentStatus False)
      | control <- spec.workspaceStatusControls
      ]

paneTreeControlParents :: PaneTree -> [(ElementKey, ControlParent)]
paneTreeControlParents (WorkspacePane pane) =
  case pane.workspacePaneItem.workspaceItemContent of
    WorkspaceItemControls controls ->
      let fill = singleFillControl controls
       in [ (controlKey control, ParentItem pane.workspacePaneItem.workspaceItemKey fill)
          | control <- controls
          ]
    WorkspaceItemTabGroup tabGroup ->
      concatMap
        (\tab ->
          let fill = singleFillControl tab.workspaceTabControls
           in [ ( controlKey control
                , ParentTab tabGroup.workspaceTabGroupKey tab.workspaceTabKey fill
                )
              | control <- tab.workspaceTabControls
              ]
        )
        tabGroup.workspaceTabs
paneTreeControlParents (WorkspaceSplit _ _ first second rest) =
  foldMap paneTreeControlParents (first : second : rest)

singleFillControl :: [Control] -> Bool
singleFillControl [TextEditor {}] = True
singleFillControl [RichTextEditor {}] = True
singleFillControl [Container {}] = True
singleFillControl [LayoutContainer {}] = True
singleFillControl [TabView {}] = True
singleFillControl [ListView {}] = True
singleFillControl [CollectionView {}] = True
singleFillControl [TreeView {}] = True
singleFillControl [TableView {}] = True
singleFillControl [ItemRepeater {}] = True
singleFillControl [NavigationSidebar {}] = True
singleFillControl [DrawingSurface {}] = True
singleFillControl _ = False

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
      DrawingSurface surface ->
        withText surface.drawingSurfaceAccessibleLabel $ \label ->
          withMacRect surface.drawingSurfaceFrame $
            c_createDrawingSurface
              window
              surface.drawingSurfaceKey.unElementKey
              label
      _ ->
        case controlCatalogKind spec of
          Nothing -> error "HaskeLUI AppKit encountered an unclassified Core control"
          Just kind ->
            withMacRect (controlFrame spec) $
              c_catalogCreate
                window
                (controlKey spec).unElementKey
                (fromIntegral (fromEnum kind + 1))
  when (handle == nullPtr) (error "HaskeLUI AppKit failed to create native control")
  case spec of
    TextEditor editor -> do
      applyTextEditorPresentation handle editor
      applyTextEditorNavigation handle editor
    RichTextEditor editor -> do
      configureCatalogControl handle spec
      applyTextEditorPresentation handle editor
      applyTextEditorNavigation handle editor
    DrawingSurface surface -> do
      applyDrawingPresentation handle surface
      applyDrawingInputPresentation handle surface
    _ -> when (isJust (controlCatalogKind spec)) (configureCatalogControl handle spec)
  pure (NativeControl handle spec Nothing)

updateControl
  :: Ptr MacWindowHandle
  -> NativeControl
  -> Control
  -> IO NativeControl
updateControl window native desired = do
  withMacRect (controlFrame desired) (c_controlSetFrame native.nativeControlHandle)
  case desired of
    Label _ _ value -> withText value (c_controlSetText native.nativeControlHandle)
    Button _ _ value _ _ -> withText value (c_controlSetText native.nativeControlHandle)
    TextField _ _ value _ _ -> withText value (c_controlSetText native.nativeControlHandle)
    TextEditor editor -> withText editor.textEditorText (c_controlSetText native.nativeControlHandle)
    DrawingSurface surface -> do
      case native.nativeControlSpec of
        DrawingSurface previous
          | previous.drawingSurfaceRevision /= surface.drawingSurfaceRevision ->
              applyDrawingPresentation native.nativeControlHandle surface
          | otherwise -> pure ()
        _ -> applyDrawingPresentation native.nativeControlHandle surface
      case native.nativeControlSpec of
        DrawingSurface previous
          | previous.drawingSurfaceAccessibleLabel /= surface.drawingSurfaceAccessibleLabel ->
              withText surface.drawingSurfaceAccessibleLabel (c_drawingSetAccessibleLabel native.nativeControlHandle)
        _ -> pure ()
      case native.nativeControlSpec of
        DrawingSurface previous
          | previous.drawingSurfaceInputMode /= surface.drawingSurfaceInputMode
              || previous.drawingSurfaceCursor /= surface.drawingSurfaceCursor ->
              applyDrawingInputPresentation native.nativeControlHandle surface
        _ -> applyDrawingInputPresentation native.nativeControlHandle surface
    _ ->
      when (catalogConfigurationChanged native.nativeControlSpec desired) $
        configureCatalogControl native.nativeControlHandle desired
  when (textEditorPresentationChanged native.nativeControlSpec desired) $
    case desired of
      TextEditor editor -> applyTextEditorPresentation native.nativeControlHandle editor
      RichTextEditor editor -> applyTextEditorPresentation native.nativeControlHandle editor
      _ -> pure ()
  when (textEditorNavigationChanged native.nativeControlSpec desired) $
    case desired of
      TextEditor editor -> applyTextEditorNavigation native.nativeControlHandle editor
      RichTextEditor editor -> applyTextEditorNavigation native.nativeControlHandle editor
      _ -> pure ()
  case desired of
    Button _ _ _ _ enabled ->
      c_controlSetEnabled native.nativeControlHandle (booleanInt enabled)
    TextField _ _ _ _ focused ->
      when focused (c_controlFocus window native.nativeControlHandle)
    TextEditor editor ->
      when editor.textEditorFocused (c_controlFocus window native.nativeControlHandle)
    RichTextEditor editor ->
      when editor.textEditorFocused (c_controlFocus window native.nativeControlHandle)
    _ -> pure ()
  let retainedMetrics =
        if measurementAffectingChanged native.nativeControlSpec desired
          then Nothing
          else native.nativeControlMetrics
  pure native {nativeControlSpec = desired, nativeControlMetrics = retainedMetrics}

measurementAffectingChanged :: Control -> Control -> Bool
measurementAffectingChanged (LayoutContainer old) (LayoutContainer new) =
  old.layoutContainerPresentation /= new.layoutContainerPresentation
measurementAffectingChanged (Container old) (Container new) =
  old.containerKind /= new.containerKind
measurementAffectingChanged (DrawingSurface old) (DrawingSurface new) =
  old.drawingSurfaceIntrinsicMetrics /= new.drawingSurfaceIntrinsicMetrics
measurementAffectingChanged old new =
  setControlFrame (Rect 0 0 0 0) old /= setControlFrame (Rect 0 0 0 0) new

resolveNativeLayouts
  :: Map ElementKey NativeControl
  -> Map ElementKey Size
  -> WindowSpec
  -> IO (WindowSpec, Map ElementKey NativeControl)
resolveNativeLayouts controls allocations desired = do
  (measurements, measuredControls) <-
    ensureNativeMeasurements (portableMeasurementKeys desired) controls
  let (resolvedView, diagnostics) =
        resolveAppViewLayoutsWithAllocations measurements allocations (AppView [desired] [])
      errors =
        [ diagnosticMessage diagnostic
        | diagnostic <- diagnostics
        , diagnosticSeverity diagnostic == DiagnosticError
        ]
  unless (null errors) $
    error ("Invalid HaskeLUI portable layout: " <> Text.unpack (Text.intercalate "; " errors))
  case resolvedView.appWindows of
    [resolved] -> pure (resolved, measuredControls)
    _ -> error "HaskeLUI AppKit failed to resolve a single-window layout"

reflowNativeWindow :: NativeWindow -> IO NativeWindow
reflowNativeWindow native = do
  (resolved, measured) <-
    resolveNativeLayouts
      native.nativeWindowControls
      native.nativeLayoutAllocations
      native.nativeWindowSpec
  controls <- commitResolvedLayoutFrames measured resolved
  pure
    native
      { nativeWindowSpec = resolved
      , nativeWindowControls = controls
      }

ensureNativeMeasurements
  :: Set ElementKey
  -> Map ElementKey NativeControl
  -> IO (Map ElementKey IntrinsicMetrics, Map ElementKey NativeControl)
ensureNativeMeasurements requested controls =
  foldM measureOne (Map.empty, Map.empty) (Map.toList controls)
  where
    measureOne (metrics, updated) (key, native) = do
      if key `Set.notMember` requested
        then pure (metrics, Map.insert key native updated)
        else do
          intrinsic <-
            case native.nativeControlMetrics of
              Just cached -> pure cached
              Nothing -> measureNativeControl native
          pure
            ( Map.insert key intrinsic metrics
            , Map.insert key native {nativeControlMetrics = Just intrinsic} updated
            )

portableMeasurementKeys :: WindowSpec -> Set ElementKey
portableMeasurementKeys desired =
  Set.fromList
    [ key
    | LayoutContainer spec <- windowLeafControls desired
    , key <- layoutLeafKeys spec.layoutContainerLayout
    ]

commitPortableLayoutFrames
  :: Ptr MacWindowHandle
  -> Map ElementKey NativeControl
  -> WindowSpec
  -> IO (Map ElementKey NativeControl)
commitPortableLayoutFrames window controls resolved =
  foldM commitOne controls (Set.toList (portableMeasurementKeys resolved))
  where
    desired = Map.fromList [(controlKey control, control) | control <- windowLeafControls resolved]
    commitOne updated key =
      case (Map.lookup key updated, Map.lookup key desired) of
        (Just native, Just control) -> do
          committed <- updateControl window native control
          pure (Map.insert key committed updated)
        _ -> pure updated

-- A native resize must not replay text values, focus requests, presentation
-- state, or other control configuration.  It commits geometry only, while
-- retaining the resolved control forest for the next incremental reflow.
commitResolvedLayoutFrames
  :: Map ElementKey NativeControl
  -> WindowSpec
  -> IO (Map ElementKey NativeControl)
commitResolvedLayoutFrames controls resolved =
  Map.traverseWithKey commitOne controls
  where
    desired = Map.fromList [(controlKey control, control) | control <- windowLeafControls resolved]
    layoutKeys = portableMeasurementKeys resolved

    commitOne key native =
      case Map.lookup key desired of
        Nothing -> pure native
        Just control -> do
          when
            ( key `Set.member` layoutKeys
                && controlFrame native.nativeControlSpec /= controlFrame control
            ) $
              withMacRect (controlFrame control) (c_controlSetFrame native.nativeControlHandle)
          pure native {nativeControlSpec = control}

measureNativeControl :: NativeControl -> IO IntrinsicMetrics
measureNativeControl native
  | DrawingSurface surface <- native.nativeControlSpec =
      pure surface.drawingSurfaceIntrinsicMetrics
measureNativeControl native =
  alloca $ \result -> do
    c_controlMeasure native.nativeControlHandle 0 0 result
    CMacRect _ _ nativeWidth nativeHeight <- peek result
    let fallback = controlIntrinsicMetrics native.nativeControlSpec
        fallbackSize = fallback.intrinsicIdeal
        width = positiveOr fallbackSize.sizeWidth nativeWidth
        height = positiveOr fallbackSize.sizeHeight nativeHeight
        ideal = Size width height
        baseline = Just (height * 0.75)
    pure (IntrinsicMetrics (Size 0 0) ideal ideal baseline baseline)
  where
    positiveOr :: Dp -> CDouble -> Dp
    positiveOr fallback value
      | realToFrac value > (0 :: Double) = Dp (realToFrac value)
      | otherwise = fallback

-- Child content is reconciled independently. Rebuilding a tab's native page
-- slots or a container merely because one descendant changed detaches the
-- first responder and also invalidates anchored presentations.
catalogConfigurationChanged :: Control -> Control -> Bool
catalogConfigurationChanged (TabView old) (TabView new) =
  old.tabViewSelected /= new.tabViewSelected
    || tabShells old /= tabShells new
  where
    tabShells = fmap (\page -> (page.tabPageKey, page.tabPageTitle)) . tabViewPages
catalogConfigurationChanged (Container old) (Container new) =
  old.containerKind /= new.containerKind
catalogConfigurationChanged (LayoutContainer old) (LayoutContainer new) =
  old.layoutContainerPresentation /= new.layoutContainerPresentation
catalogConfigurationChanged old new = old /= new

configureCatalogControl :: Ptr MacControlHandle -> Control -> IO ()
configureCatalogControl handle = \case
  RichText spec -> do
    setPrimary handle (attributedTextValue spec.richTextValue)
    applyAttributedTextPresentation handle spec.richTextValue
  Image spec -> configureImage spec
  Icon spec -> configureImage spec
  Separator {} -> pure ()
  RepeatButton spec -> configureAction spec
  ToggleButton spec -> configureToggle spec
  CheckBox spec -> configureToggle spec
  RadioGroup spec -> configureChoice spec
  Switch spec -> configureToggle spec
  SegmentedChoice spec -> configureChoice spec
  Link spec -> configureAction spec
  MenuButton spec -> configureChoice spec
  SplitButton spec -> configureSplit spec
  ToggleSplitButton spec -> configureSplit spec
  TextArea spec -> configureTextInput spec
  RichTextEditor spec -> setPrimary handle spec.textEditorText
  SecureField spec -> configureTextInput spec
  SearchField spec -> configureTextInput spec
  SuggestField spec -> configureTextInput spec
  ChoicePicker spec -> configureChoice spec
  EditableComboBox spec -> configureTextInput spec
  NumberField spec -> configureNumeric spec
  Stepper spec -> configureNumeric spec
  Slider spec -> configureNumeric spec
  DatePicker spec -> configureDate spec
  TimePicker spec -> configureTime spec
  CalendarView spec -> configureDate spec
  ColorPicker spec -> configureColor spec
  Rating spec -> configureNumeric spec
  ListView spec -> configureCollection spec
  CollectionView spec -> configureCollection spec
  TreeView spec -> configureCollection spec
  TableView spec -> configureCollection spec
  ItemRepeater spec -> configureCollection spec
  TabView spec ->
    setCatalogItems handle
      [ catalogItem page.tabPageKey.unChoiceKey page.tabPageTitle "" "" 0 True
          (Just page.tabPageKey == spec.tabViewSelected) False False False Nothing
      | page <- spec.tabViewPages
      ]
  Breadcrumb spec ->
    configureChoice
      ChoiceControlSpec
        { choiceControlKey = spec.breadcrumbKey
        , choiceControlFrame = spec.breadcrumbFrame
        , choiceControlItems = spec.breadcrumbItems
        , choiceControlSelected = spec.breadcrumbSelected
        , choiceControlEnabled = True
        }
  NavigationSidebar spec -> configureCollection spec
  MenuBar spec -> configureMenu spec
  ContextMenu spec -> configureMenu spec
  Toolbar spec ->
    setCatalogItems handle
      [ catalogItem command.unCommandId "" "" "" 0 True False False False False (Just command)
      | command <- spec.toolbarCommands
      ]
  Dialog spec -> configurePresentation spec
  Alert spec -> configurePresentation spec
  Popover spec -> configurePresentation spec
  Tooltip spec -> configureMessage spec
  ProgressBar spec -> configureProgress spec
  ActivityIndicator _ _ active -> c_catalogSetState handle (booleanInt active)
  Meter spec -> configureProgress spec
  Badge spec -> configureMessage spec
  InlineNotice spec -> configureMessage spec
  Container spec -> configureContainer spec
  LayoutContainer spec -> configureLayoutContainer spec
  control ->
    error ("HaskeLUI AppKit received a non-catalog control in catalog configuration: " <> show control)
  where
    configureImage :: ImageControlSpec -> IO ()
    configureImage spec = do
      setPrimary handle (encodeImageSource spec.imageControlSource)
      setSecondary handle spec.imageControlDescription
      setTooltip handle spec.imageControlDescription

    configureAction :: ActionControlSpec -> IO ()
    configureAction spec = do
      configureLabel handle spec.actionControlLabel
      c_catalogSetCommand handle spec.actionControlCommand.unCommandId
      c_controlSetEnabled handle (booleanInt spec.actionControlEnabled)

    configureToggle :: ToggleControlSpec -> IO ()
    configureToggle spec = do
      configureLabel handle spec.toggleControlLabel
      c_catalogSetState handle (toggleInt spec.toggleControlValue)
      c_controlSetEnabled handle (booleanInt spec.toggleControlEnabled)

    configureChoice :: ChoiceControlSpec -> IO ()
    configureChoice spec = do
      setCatalogItems handle
        [ catalogItem item.choiceItemKey.unChoiceKey
            item.choiceItemLabel.controlLabelText
            ""
            (maybe "" encodeImageSource item.choiceItemLabel.controlLabelIcon)
            0 item.choiceItemEnabled
            (Just item.choiceItemKey == spec.choiceControlSelected)
            False False False Nothing
        | item <- spec.choiceControlItems
        ]
      c_controlSetEnabled handle (booleanInt spec.choiceControlEnabled)

    configureSplit :: SplitButtonSpec -> IO ()
    configureSplit spec = do
      configureLabel handle spec.splitButtonLabel
      c_catalogSetCommand handle spec.splitButtonCommand.unCommandId
      forM_ spec.splitButtonToggleValue $ \selected ->
        c_catalogSetState handle (booleanInt selected)
      setCatalogItems handle (menuCatalogItems spec.splitButtonItems)
      c_controlSetEnabled handle (booleanInt spec.splitButtonEnabled)

    configureTextInput :: TextInputSpec -> IO ()
    configureTextInput spec = do
      setPrimary handle spec.textInputText
      setSecondary handle spec.textInputPlaceholder
      unless (null spec.textInputSuggestions) $
        setCatalogItems handle
          [ catalogItem item.choiceItemKey.unChoiceKey
              item.choiceItemLabel.controlLabelText
              "" "" 0 item.choiceItemEnabled False False False False Nothing
          | item <- spec.textInputSuggestions
          ]
      c_controlSetEnabled handle (booleanInt spec.textInputEnabled)

    configureNumeric :: NumericControlSpec -> IO ()
    configureNumeric spec = do
      c_catalogSetNumeric handle
        (realToFrac spec.numericControlValue)
        (realToFrac spec.numericControlMinimum)
        (realToFrac spec.numericControlMaximum)
        (realToFrac spec.numericControlStep)
      c_controlSetEnabled handle (booleanInt spec.numericControlEnabled)

    configureDate :: DateControlSpec -> IO ()
    configureDate spec = do
      let date = spec.dateControlValue
      c_catalogSetDateTime handle
        (fromIntegral date.dateYear) (fromIntegral date.dateMonth) (fromIntegral date.dateDay)
        0 0 0
      c_controlSetEnabled handle (booleanInt spec.dateControlEnabled)

    configureTime :: TimeControlSpec -> IO ()
    configureTime spec = do
      let time = spec.timeControlValue
      c_catalogSetDateTime handle 2001 1 1
        (fromIntegral time.timeHour) (fromIntegral time.timeMinute) (fromIntegral time.timeSecond)
      c_controlSetEnabled handle (booleanInt spec.timeControlEnabled)

    configureColor :: ColorControlSpec -> IO ()
    configureColor spec = do
      let color = spec.colorControlValue
      c_catalogSetColor handle
        (realToFrac color.colorRed) (realToFrac color.colorGreen)
        (realToFrac color.colorBlue) (realToFrac color.colorAlpha)
      c_controlSetEnabled handle (booleanInt spec.colorControlEnabled)

    configureCollection :: CollectionControlSpec -> IO ()
    configureCollection spec = do
      c_catalogSetState handle (selectionModeInt spec.collectionControlSelectionMode)
      let (sizing, fixedHeight) = collectionRowSizingNative spec.collectionControlRowSizing
      c_catalogSetRowSizing handle sizing fixedHeight
      setCatalogItems handle
        [ catalogItem item.collectionItemKey.unCollectionItemKey
            item.collectionItemLabel item.collectionItemDetail
            (maybe "" encodeImageSource item.collectionItemIcon)
            item.collectionItemDepth True
            (item.collectionItemKey `elem` spec.collectionControlSelection)
            item.collectionItemExpanded item.collectionItemExpandable False Nothing
        | item <- spec.collectionControlItems
        ]
      c_controlSetEnabled handle (booleanInt spec.collectionControlEnabled)

    configureMenu :: MenuControlSpec -> IO ()
    configureMenu spec = do
      setPrimary handle spec.menuControlTitle
      setCatalogItems handle (menuCatalogItems spec.menuControlEntries)

    configurePresentation :: PresentationSpec -> IO ()
    configurePresentation spec = do
      setPrimary handle spec.presentationTitle
      setSecondary handle spec.presentationMessage
      setCatalogItems handle
        [ catalogItem
            presentationAction.presentationActionId.unPresentationActionId
            presentationAction.presentationActionTitle
            (presentationActionRoleText presentationAction.presentationActionRole)
            ""
            0
            presentationAction.presentationActionEnabled
            False
            False
            False
            False
            Nothing
        | presentationAction <- spec.presentationActions
        ]
      c_catalogSetPresentation handle
        (booleanInt spec.presentationVisible)
        (case spec.presentationKind of
          PopoverPresentation anchor -> anchor.unElementKey
          _ -> 0)

    configureMessage :: MessageControlSpec -> IO ()
    configureMessage spec = do
      setPrimary handle spec.messageControlTitle
      setSecondary handle spec.messageControlMessage

    configureProgress :: ProgressControlSpec -> IO ()
    configureProgress spec =
      c_catalogSetNumeric handle
        (realToFrac spec.progressControlValue)
        (realToFrac spec.progressControlMinimum)
        (realToFrac spec.progressControlMaximum)
        0

    configureContainer :: ContainerSpec -> IO ()
    configureContainer spec =
      case spec.containerKind of
        StackContainer axis spacing -> do
          setPrimary handle ""
          c_catalogSetState handle (containerState axis spacing)
        GridContainer columns spacing -> do
          setPrimary handle ""
          c_catalogSetState handle (1000 + fromIntegral columns * 100 + roundedSpacing spacing)
        OverlayContainer -> c_catalogSetState handle 2000
        CanvasContainer -> c_catalogSetState handle 2001
        GroupContainer title -> do
          setPrimary handle title
          c_catalogSetState handle 3000
        ScrollContainer -> c_catalogSetState handle 4000
        DisclosureContainer title expanded -> do
          setPrimary handle title
          c_catalogSetState handle (if expanded then 5001 else 5000)

    configureLayoutContainer :: LayoutContainerSpec -> IO ()
    configureLayoutContainer spec =
      case spec.layoutContainerPresentation of
        PlainLayoutContainer -> do
          setPrimary handle ""
          c_catalogSetState handle 6000
        ScrollLayoutContainer _ -> do
          setPrimary handle ""
          c_catalogSetState handle 6100
        GroupLayoutContainer title -> do
          setPrimary handle title
          c_catalogSetState handle 6300
        DisclosureLayoutContainer title expanded -> do
          setPrimary handle title
          c_catalogSetState handle (if expanded then 6501 else 6500)

configureLabel :: Ptr MacControlHandle -> ControlLabel -> IO ()
configureLabel handle label = do
  setPrimary handle label.controlLabelText
  setSecondary handle (maybe "" encodeImageSource label.controlLabelIcon)

setPrimary :: Ptr MacControlHandle -> Text -> IO ()
setPrimary handle value = withText value (c_catalogSetPrimaryText handle)

setSecondary :: Ptr MacControlHandle -> Text -> IO ()
setSecondary handle value = withText value (c_catalogSetSecondaryText handle)

setTooltip :: Ptr MacControlHandle -> Text -> IO ()
setTooltip handle value = withText value (c_catalogSetTooltip handle)

encodeImageSource :: ImageSource -> Text
encodeImageSource (SystemSymbol value) = "system:" <> value
encodeImageSource (NamedImage value) = "named:" <> value
encodeImageSource (FileImage value) = "file:" <> Text.pack value

toggleInt :: ToggleValue -> CInt
toggleInt ToggleOff = 0
toggleInt ToggleOn = 1
toggleInt ToggleMixed = -1

selectionModeInt :: CollectionSelectionMode -> CInt
selectionModeInt NoCollectionSelection = 0
selectionModeInt SingleCollectionSelection = 1
selectionModeInt MultipleCollectionSelection = 2

collectionRowSizingNative :: CollectionRowSizing -> (CInt, CDouble)
collectionRowSizingNative PlatformDefaultRows = (0, 0)
collectionRowSizingNative CompactRows = (1, 0)
collectionRowSizingNative StandardRows = (2, 0)
collectionRowSizingNative SpaciousRows = (3, 0)
collectionRowSizingNative (FixedRows height) = (4, realToFrac height)
collectionRowSizingNative ContentSizedRows = (5, 0)

containerState :: Axis -> Double -> CInt
containerState axis spacing =
  (case axis of Horizontal -> 0; Vertical -> 1) * 100 + roundedSpacing spacing

roundedSpacing :: Double -> CInt
roundedSpacing value = fromIntegral (max 0 (min 99 (round value :: Int)))

catalogItem
  :: Word64 -> Text -> Text -> Text -> Int -> Bool -> Bool -> Bool -> Bool -> Bool
  -> Maybe CommandId -> CatalogItem
catalogItem = CatalogItem

menuCatalogItems :: [MenuEntry] -> [CatalogItem]
menuCatalogItems entries = zipWith convert [1 ..] entries
  where
    convert index (MenuCommand label command enabled) =
      catalogItem index label "" "" 0 enabled False False False False (Just command)
    convert index MenuSeparator =
      catalogItem index "" "" "" 0 False False False False True Nothing

presentationActionRoleText :: PresentationActionRole -> Text
presentationActionRoleText role =
  case role of
    DefaultPresentationAction -> "default"
    CancelPresentationAction -> "cancel"
    DestructivePresentationAction -> "destructive"
    AuxiliaryPresentationAction -> "auxiliary"

setCatalogItems :: Ptr MacControlHandle -> [CatalogItem] -> IO ()
setCatalogItems handle items = do
  c_catalogBeginItems handle
  forM_ items $ \item ->
    withText item.catalogItemLabel $ \label ->
      withText item.catalogItemDetail $ \detail ->
        withText item.catalogItemIcon $ \icon ->
          c_catalogAddItem handle
            item.catalogItemIdentity label detail icon
            (fromIntegral item.catalogItemDepth)
            (catalogItemFlags item)
            (maybe 0 unCommandId item.catalogItemCommand)
  c_catalogEndItems handle

catalogItemFlags :: CatalogItem -> CInt
catalogItemFlags item =
  flag 1 item.catalogItemEnabled
    + flag 2 item.catalogItemSelected
    + flag 4 item.catalogItemExpanded
    + flag 8 item.catalogItemSeparator
    + flag 16 item.catalogItemExpandable
  where
    flag value present = if present then value else 0

applyAttributedTextPresentation :: Ptr MacControlHandle -> AttributedText -> IO ()
applyAttributedTextPresentation handle attributed = do
  c_textEditorBeginPresentation handle
  withCTextStyle mempty (c_textEditorSetBaseStyle handle)
  let value = attributedTextValue attributed
      offsets = Map.fromDistinctAscList $
        zip [0 ..] (scanl advanceUtf16 0 (Text.unpack value))
  forM_ (attributedTextSpans attributed) $ \textSpan -> do
    let range = textSpan.textSpanRange
        start = range.textRangeStart
        end = start + range.textRangeLength
    case (Map.lookup start offsets, Map.lookup end offsets) of
      (Just utf16Start, Just utf16End) ->
        withCTextStyle textSpan.textSpanValue $ \style -> do
          applied <- c_textEditorApplyStyle handle utf16Start (utf16End - utf16Start) style
          unless (applied /= 0) $
            error "HaskeLUI AppKit rejected a validated rich-text range"
      _ -> error "HaskeLUI AppKit could not translate a validated rich-text range"
  c_textEditorEndPresentation handle
  where
    advanceUtf16 offset character =
      offset + if ord character > 0xFFFF then 2 else 1

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
    RichTextEditor editor
      | editor.textEditorFocused ->
          forM_ (Map.lookup editor.textEditorKey controls) $ \native ->
            c_controlFocus window native.nativeControlHandle
    TextArea input -> focusTextInput input
    SecureField input -> focusTextInput input
    SearchField input -> focusTextInput input
    SuggestField input -> focusTextInput input
    EditableComboBox input -> focusTextInput input
    _ -> pure ()
  where
    focusTextInput :: TextInputSpec -> IO ()
    focusTextInput input =
      when input.textInputFocused $
        forM_ (Map.lookup input.textInputKey controls) $ \native ->
          c_controlFocus window native.nativeControlHandle
    navigationHandles =
      [ native.nativeControlHandle
      | control <- desired
      , isKeyboardControl control
      , Just native <- [Map.lookup (controlKey control) controls]
      ]

isKeyboardControl :: Control -> Bool
isKeyboardControl Label {} = False
isKeyboardControl RichText {} = False
isKeyboardControl Image {} = False
isKeyboardControl Icon {} = False
isKeyboardControl DrawingSurface {} = False
isKeyboardControl Separator {} = False
isKeyboardControl ProgressBar {} = False
isKeyboardControl ActivityIndicator {} = False
isKeyboardControl Meter {} = False
isKeyboardControl Badge {} = False
isKeyboardControl InlineNotice {} = False
isKeyboardControl Dialog {} = False
isKeyboardControl Alert {} = False
isKeyboardControl Popover {} = False
isKeyboardControl Container {} = False
isKeyboardControl LayoutContainer {} = False
isKeyboardControl _ = True

controlsCompatible :: Control -> Control -> Bool
controlsCompatible (Label {}) (Label {}) = True
controlsCompatible (Button _ _ _ oldCommand _) (Button _ _ _ newCommand _) =
  oldCommand == newCommand
controlsCompatible (TextField _ _ _ oldPlaceholder _) (TextField _ _ _ newPlaceholder _) =
  oldPlaceholder == newPlaceholder
controlsCompatible (TextEditor {}) (TextEditor {}) = True
controlsCompatible (DrawingSurface {}) (DrawingSurface {}) = True
controlsCompatible old new =
  case (controlCatalogKind old, controlCatalogKind new) of
    (Just oldKind, Just newKind) -> oldKind == newKind
    _ -> False

applyDrawingPresentation :: Ptr MacControlHandle -> DrawingSurfaceSpec -> IO ()
applyDrawingPresentation handle surface =
  case validateDrawing surface.drawingSurfaceDrawing of
    [] -> do
      c_drawingBegin handle
      traverse_ (executeDrawingCommand handle) (compileDrawing surface.drawingSurfaceDrawing)
      c_drawingEnd handle
    errors ->
      error
        ( "Invalid HaskeLUI drawing surface: "
            <> Text.unpack
              (Text.intercalate "; " (fmap drawingValidationMessage errors))
        )

applyDrawingInputPresentation :: Ptr MacControlHandle -> DrawingSurfaceSpec -> IO ()
applyDrawingInputPresentation handle surface = do
  c_drawingSetInputEnabled handle (booleanInt (surface.drawingSurfaceInputMode == DrawingInputEnabled))
  c_drawingSetCursor handle (encodeDrawingCursor surface.drawingSurfaceCursor)

encodeDrawingCursor :: DrawingCursor -> CInt
encodeDrawingCursor DefaultCursor = 0
encodeDrawingCursor PointingHandCursor = 1
encodeDrawingCursor CrosshairCursor = 2
encodeDrawingCursor OpenHandCursor = 3
encodeDrawingCursor ClosedHandCursor = 4
encodeDrawingCursor TextCursor = 5
encodeDrawingCursor HorizontalResizeCursor = 6
encodeDrawingCursor VerticalResizeCursor = 7

executeDrawingCommand :: Ptr MacControlHandle -> DrawingCommand -> IO ()
executeDrawingCommand handle = \case
  PushState -> c_drawingPushState handle
  PopState -> c_drawingPopState handle
  ConcatTransform affine ->
    c_drawingConcatTransform
      handle
      (realToFrac affine.affineA)
      (realToFrac affine.affineB)
      (realToFrac affine.affineC)
      (realToFrac affine.affineD)
      (realToFrac affine.affineTx)
      (realToFrac affine.affineTy)
  ClipGeometry rule geometry -> do
    emitGeometryPath handle geometry
    c_drawingClipPath handle (encodeFillRule rule)
  BeginOpacity opacity -> c_drawingBeginOpacity handle (realToFrac opacity)
  EndOpacity -> c_drawingEndOpacity handle
  FillGeometry rule (Solid color) geometry -> do
    emitGeometryPath handle geometry
    c_drawingFillPath
      handle
      (encodeFillRule rule)
      (realToFrac color.colorRed)
      (realToFrac color.colorGreen)
      (realToFrac color.colorBlue)
      (realToFrac color.colorAlpha)
  StrokeGeometry style (Solid color) geometry -> do
    emitGeometryPath handle geometry
    let dash = fmap realToFrac style.strokeDashPattern :: [CDouble]
    withArray dash $ \dashPointer ->
      c_drawingStrokePath
        handle
        (realToFrac style.strokeWidth)
        (encodeLineCap style.strokeLineCap)
        (encodeLineJoin style.strokeLineJoin)
        (realToFrac style.strokeMiterLimit)
        dashPointer
        (fromIntegral (length dash))
        (realToFrac style.strokeDashPhase)
        (realToFrac color.colorRed)
        (realToFrac color.colorGreen)
        (realToFrac color.colorBlue)
        (realToFrac color.colorAlpha)
  DrawTextCommand text ->
    withText text.drawnText $ \value ->
      withMacRect text.drawnTextRect $ \rect ->
        withCTextStyle text.drawnTextStyle $ \style ->
          c_drawingText
            handle
            value
            rect
            style
            (encodeHorizontalAlignment text.drawnTextHorizontalAlignment)
            (encodeVerticalAlignment text.drawnTextVerticalAlignment)
            (encodeTextWrapping text.drawnTextWrapping)

emitGeometryPath :: Ptr MacControlHandle -> Geometry -> IO ()
emitGeometryPath handle geometry = do
  c_drawingPathBegin handle
  case geometry of
    Rectangle rect -> withMacRect rect (c_drawingPathAddRect handle)
    RoundedRectangle rect radiusX radiusY ->
      withMacRect rect $ \nativeRect ->
        c_drawingPathAddRoundedRect handle nativeRect (realToFrac radiusX) (realToFrac radiusY)
    Ellipse rect -> withMacRect rect (c_drawingPathAddEllipse handle)
    PathGeometry (Path segments) -> traverse_ (emitPathSegment handle) segments

emitPathSegment :: Ptr MacControlHandle -> PathSegment -> IO ()
emitPathSegment handle = \case
  MoveTo point -> c_drawingPathMoveTo handle (realToFrac point.pointX) (realToFrac point.pointY)
  LineTo point -> c_drawingPathLineTo handle (realToFrac point.pointX) (realToFrac point.pointY)
  QuadraticTo control end ->
    c_drawingPathQuadraticTo
      handle
      (realToFrac control.pointX)
      (realToFrac control.pointY)
      (realToFrac end.pointX)
      (realToFrac end.pointY)
  CubicTo first second end ->
    c_drawingPathCubicTo
      handle
      (realToFrac first.pointX)
      (realToFrac first.pointY)
      (realToFrac second.pointX)
      (realToFrac second.pointY)
      (realToFrac end.pointX)
      (realToFrac end.pointY)
  ClosePath -> c_drawingPathClose handle

encodeFillRule :: FillRule -> CInt
encodeFillRule NonZero = 0
encodeFillRule EvenOdd = 1

encodeLineCap :: LineCap -> CInt
encodeLineCap ButtCap = 0
encodeLineCap RoundCap = 1
encodeLineCap SquareCap = 2

encodeLineJoin :: LineJoin -> CInt
encodeLineJoin MiterJoin = 0
encodeLineJoin RoundJoin = 1
encodeLineJoin BevelJoin = 2

encodeHorizontalAlignment :: HorizontalTextAlignment -> CInt
encodeHorizontalAlignment TextStart = 0
encodeHorizontalAlignment TextCenter = 1
encodeHorizontalAlignment TextEnd = 2

encodeVerticalAlignment :: VerticalTextAlignment -> CInt
encodeVerticalAlignment TextTop = 0
encodeVerticalAlignment TextMiddle = 1
encodeVerticalAlignment TextBottom = 2

encodeTextWrapping :: TextWrapping -> CInt
encodeTextWrapping NoWrap = 0
encodeTextWrapping WordWrap = 1
encodeTextWrapping CharacterWrap = 2

textEditorPresentationChanged :: Control -> Control -> Bool
textEditorPresentationChanged (TextEditor old) (TextEditor new) =
  old.textEditorText /= new.textEditorText
    || old.textEditorRevision /= new.textEditorRevision
    || old.textEditorBaseStyle /= new.textEditorBaseStyle
    || old.textEditorLayers /= new.textEditorLayers
textEditorPresentationChanged (RichTextEditor old) (RichTextEditor new) =
  old.textEditorText /= new.textEditorText
    || old.textEditorRevision /= new.textEditorRevision
    || old.textEditorBaseStyle /= new.textEditorBaseStyle
    || old.textEditorLayers /= new.textEditorLayers
textEditorPresentationChanged _ _ = False

textEditorNavigationChanged :: Control -> Control -> Bool
textEditorNavigationChanged (TextEditor old) (TextEditor new) =
  fmap (.textNavigationKey) old.textEditorNavigation
    /= fmap (.textNavigationKey) new.textEditorNavigation
textEditorNavigationChanged (RichTextEditor old) (RichTextEditor new) =
  fmap (.textNavigationKey) old.textEditorNavigation
    /= fmap (.textNavigationKey) new.textEditorNavigation
textEditorNavigationChanged _ _ = False

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
            error "HaskeLUI AppKit rejected a validated text presentation range"
      _ -> error "HaskeLUI AppKit could not translate a validated Unicode text range"
  c_textEditorEndPresentation handle
  where
    advanceUtf16 offset character =
      offset + if ord character > 0xFFFF then 2 else 1

applyTextEditorNavigation :: Ptr MacControlHandle -> TextEditorSpec -> IO ()
applyTextEditorNavigation handle editor =
  forM_ editor.textEditorNavigation $ \request ->
    when (request.textNavigationRevision == editor.textEditorRevision) $ do
      let scalarLength = Text.length editor.textEditorText
          range = request.textNavigationRange
          start = range.textRangeStart
      when
        ( start >= 0
            && range.textRangeLength >= 0
            && start <= scalarLength
            && range.textRangeLength <= scalarLength - start
        ) $ do
          let end = start + range.textRangeLength
              offsets =
                Map.fromDistinctAscList $
                  zip [0 ..] (scanl advanceUtf16 0 (Text.unpack editor.textEditorText))
          case (Map.lookup start offsets, Map.lookup end offsets) of
            (Just utf16Start, Just utf16End) -> do
              applied <-
                c_textEditorNavigate
                  handle
                  utf16Start
                  (utf16End - utf16Start)
                  (booleanInt request.textNavigationSelect)
                  (booleanInt request.textNavigationFocus)
              unless (applied /= 0) $
                error "HaskeLUI AppKit rejected a validated text navigation range"
            _ -> error "HaskeLUI AppKit could not translate a validated text navigation range"
  where
    advanceUtf16 offset character =
      offset + if ord character > 0xFFFF then 2 else 1

shutdown
  :: IORef AppKitState
  -> FunPtr EventCallback
  -> FunPtr DrawingInputCallback
  -> FunPtr LayoutAllocationCallback
  -> IO ()
shutdown stateReference callback drawingInputCallback layoutAllocationCallback = do
  state <- readIORef stateReference
  forM_ (Map.elems state.nativeWindows) destroyWindow
  forM_ (Map.keys state.nativeCommands) (c_commandRemove . unCommandId)
  writeIORef stateReference (AppKitState Map.empty Map.empty)
  c_shutdown
  freeHaskellFunPtr callback
  freeHaskellFunPtr drawingInputCallback
  freeHaskellFunPtr layoutAllocationCallback

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
