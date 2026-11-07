{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE ScopedTypeVariables #-}
module Coordinator (main) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async
import Control.Concurrent.STM
import Control.Exception
import Control.Monad (forM_, unless, void, when)
import qualified Data.Map.Strict as Map
import Data.Map.Strict (Map)
import Data.List (find, nub)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.IO as TextIO
import System.Directory hiding (executable)
import System.Environment
import System.FilePath
import System.IO
import System.Timeout (timeout)
import System.Exit (exitWith, ExitCode (ExitFailure))
import qualified System.FSNotify as FS
import VisualHaskell.Analysis.Client
import VisualHaskell.Analysis.Ghc910 (prepareProjectContext)
import VisualHaskell.Analysis.Protocol
import VisualHaskell.Projects
import VisualHaskell.Semantic

type Incoming = ProtocolEnvelope ClientMessage
data Event = Input (Either FrameError Incoming)
  | CatalogReady Int Incoming (Either SomeException ProjectCatalog)
  | ContextReady Int Incoming (Either SomeException ResolvedContext)
  | Progress Int Incoming Text
  | ChildEvent Int AnalysisClientEvent
  | DiskChanged Int FilePath
data Running = Running Int (Maybe ResolvedContext) AnalysisClient
data State = State
  { workspace :: Maybe Incoming, documents :: Map DocumentId DocumentSnapshot
  , catalog :: Maybe ProjectCatalog, preferred :: Maybe Text, selected :: Maybe ComponentId
  , contexts :: Map ComponentId ResolvedContext, running :: Maybe Running
  , job :: Maybe (Async ()), epoch :: Int, childEpoch :: Int, watchEpoch :: Int
  , pending :: Maybe Incoming, watcher :: IO ()
  , managedProject :: Bool
  , documentPaths :: Map DocumentId FilePath
  , diskDigests :: Map FilePath (Maybe ContentHash)
  }

-- One live compiler process is deliberately the initial memory budget. Prepared
-- contexts (max two) are cached, but each component switch starts an isolated
-- compiler session. No DynFlags/Name/Type values cross that process boundary.
main :: IO ()
main = do
  hSetBinaryMode stdin True
  hSetBinaryMode stdout True
  hSetBuffering stdout NoBuffering
  first <- readFrame defaultFrameLimits stdin
  case first of
    Right hello@(ProtocolEnvelope {envelopePayload = ClientHelloMessage _}) -> do
      respond hello (WorkerHelloMessage (WorkerHello protocolV2 "visual-haskell-project-worker/0.2.0"
        (Just (CompilerVersion "9.10.3")) [WorkspaceLoadingCapability, ComponentDiscoveryCapability,
          FullDocumentSnapshotsCapability, DiagnosticsCapability, DocumentDeclarationsCapability,
          StructuredTypesCapability, PositionQueriesCapability, CompositionChecksCapability]
        (maximumFrameBytes defaultFrameLimits)))
      events <- newTQueueIO
      let readInput = do
            frame <- readFrame defaultFrameLimits stdin
            atomically (writeTQueue events (Input frame))
            case frame of Right _ -> readInput; _ -> pure ()
      withAsync readInput $ \_ -> loop events (State Nothing Map.empty Nothing Nothing Nothing Map.empty Nothing Nothing 0 0 0 Nothing (pure ()) False Map.empty Map.empty)
    _ -> fail "Expected protocol v2 ClientHello"

loop :: TQueue Event -> State -> IO ()
loop events state = do
  event <- atomically (readTQueue events)
  case event of
    Input (Left _) -> cleanup state
    Input (Right incoming) -> do
     case incoming.envelopePayload of AnalyzeDocument _ -> crashOnce; _ -> pure ()
     case incoming.envelopePayload of
      ShutdownWorker -> cleanup state
      OpenWorkspace request -> do
        cleanup state
        let next = State (Just incoming) Map.empty Nothing Nothing Nothing Map.empty Nothing Nothing (state.epoch + 1) (state.childEpoch + 1) (state.watchEpoch + 1) Nothing (pure ()) False Map.empty Map.empty
        if request.workspaceRequestTrust == UntrustedWorkspace
          then respond incoming (WorkspaceFailed request.workspaceRequestId (RequestFailure "workspace-untrusted" "Trust this workspace to run Stack/Cabal, custom Setup, plugins and compiler code" True))
          else do
            respond incoming (WorkspaceLoading request.workspaceRequestId)
            respond incoming (WorkspaceReady request.workspaceRequestId (SessionId "workspace-coordinator"))
        loop events next
      _ | not (trusted state) -> do
        failed incoming "workspace-untrusted" "Open and trust a workspace before running project tools"
        loop events state
      DiscoverProject choice -> do
        stopped <- invalidate state
        next <- discover events incoming stopped {preferred = choice, pending = state.pending, managedProject = True}
        loop events next
      OpenDocument document -> updateDocument events incoming state document
      UpdateDocumentSnapshot document -> updateDocument events incoming state document
      CloseDocument document -> do
        forward state incoming
        loop events state {documents = Map.delete document state.documents, documentPaths = Map.delete document state.documentPaths}
      AnalyzeDocument _ | state.job /= Nothing -> loop events state {pending = Just incoming}
      AnalyzeDocument _ -> routeAnalysis events incoming state >>= loop events
      PrepareComponent component | state.catalog == Nothing && state.job /= Nothing -> loop events state {selected = Just component}
      PrepareComponent component -> prepare events incoming component state >>= loop events
      SelectComponent component -> prepare events incoming component state >>= loop events
      QueryPosition _ -> forwardOrFail state incoming >> loop events state
      CheckComposition _ -> forwardOrFail state incoming >> loop events state
      ReloadConfiguration -> do
        stopped <- invalidate state
        next <- discover events incoming stopped {pending = state.pending, managedProject = True}
        loop events next
      CancelRequest _ -> do
        stopped <- invalidateSession state
        respond incoming (ProjectConfigurationChanged [])
        respond incoming (ProjectProgress "Project operation cancelled; editing remains available")
        loop events stopped {pending = Nothing}
      _ -> failed incoming "unsupported-project-command" "Command is private to a compiler session" >> loop events state
    Progress token incoming message -> do
      when (token == state.epoch) (respond incoming (ProjectProgress (Text.take 8192 message)))
      loop events state
    CatalogReady token incoming result | token == state.epoch -> case result of
      Left exception -> failed incoming "project-discovery-failed" (Text.pack (displayException exception)) >> loop events state {job = Nothing, pending = Nothing}
      Right value -> do
        respond incoming (ProjectDiscovered value)
        stopWatching <- startWatching events state.watchEpoch state.workspace value
        let updated = state {catalog = Just value, job = Nothing, watcher = stopWatching}
        case state.selected >>= (\identifier -> find ((== identifier) . projectComponentId) value.catalogComponents) of
          Just component -> prepare events incoming component.projectComponentId updated >>= loop events
          Nothing -> case state.pending of
            Just request -> routeAnalysis events request updated {pending = Nothing} >>= loop events
            Nothing -> loop events updated
    ContextReady token incoming result | token == state.epoch -> case result of
      Left exception -> failed incoming "component-prepare-failed" (Text.pack (displayException exception)) >> loop events state {job = Nothing, pending = Nothing}
      Right context -> do
        let cached = Map.insert context.resolvedComponent context (Map.fromList (take 1 (Map.toList state.contexts)))
            updatedCatalog = fmap (\value -> value {catalogConfigurationFiles = nub (value.catalogConfigurationFiles <> context.resolvedConfigurationFiles)}) state.catalog
        state.watcher
        watching <- maybe (pure (pure ())) (startWatching events state.watchEpoch state.workspace) updatedCatalog
        next <- startChild events incoming (Just context) state {job = Nothing, contexts = cached, catalog = updatedCatalog, watcher = watching}
        case state.pending of
          Just request -> routeAnalysis events request next {pending = Nothing} >>= loop events
          Nothing -> loop events next
    ChildEvent token child | token == state.childEpoch -> do
      case child of
        AnalysisWorkerMessage _ message -> case message.envelopePayload of
          WorkerHelloMessage _ -> pure ()
          WorkspaceLoading _ -> pure ()
          WorkspaceReady _ _ -> pure ()
          PositionQueryCompleted result -> do
            let restore :: DefinitionTarget -> DefinitionTarget
                restore target = case find ((== normalise target.definitionPath) . normalise . snapshotPath) (Map.elems state.documents) of
                  Just document -> target {definitionPath = Map.findWithDefault target.definitionPath document.snapshotDocumentId state.documentPaths}
                  Nothing -> target
            void (writeFrame defaultFrameLimits stdout message {envelopePayload = PositionQueryCompleted result {resultDefinitions = map restore result.resultDefinitions}})
          _ -> void (writeFrame defaultFrameLimits stdout message)
        AnalysisWorkerLog _ message -> forM_ state.workspace (\incoming -> respond incoming (ProjectProgress (Text.take 8192 message)))
        AnalysisWorkerProtocolFailure _ message -> forM_ state.workspace (\incoming -> failed incoming "compiler-process-failed" message)
        AnalysisWorkerRestarting _ _ -> forM_ state.workspace (\incoming -> respond incoming (ProjectProgress "Restarting compiler session and restoring open buffers"))
        _ -> pure ()
      loop events state
    DiskChanged token path | token == state.watchEpoch -> do
      -- Disk saves for open buffers are not an authority change. Configuration
      -- changes always are, including atomic replacement and missing-file creation.
      let isConfig = isConfiguration path || maybe False (elem path . catalogConfigurationFiles) state.catalog
          open = any ((== normalise path) . normalise . snapshotPath) (Map.elems state.documents)
      content <- try (TextIO.readFile path) :: IO (Either IOException Text)
      let digest = either (const Nothing) (Just . contentHash) content
          seen = state {diskDigests = Map.insert path digest state.diskDigests}
          unchanged = Map.lookup path state.diskDigests == Just digest
      -- Setup/preprocessor hooks often rewrite generated .hs files. During
      -- preparation no compiler graph is live; the new session reads the final
      -- files. Hashing events also prevents identical rewrites/repeated native
      -- events from causing a reconfigure loop.
      if unchanged || (not isConfig && (open || state.job /= Nothing)) then loop events seen else do
        forM_ state.workspace (\incoming -> respond incoming (ProjectConfigurationChanged [path]))
        stopped <- invalidate seen
        case state.workspace of
          Nothing -> loop events stopped
          Just incoming -> do
            let pendingRequest = state.pending
            next <- discoverDelayed events incoming stopped {pending = pendingRequest}
            loop events next
    _ -> loop events state

crashOnce :: IO ()
crashOnce = do
  args <- getArgs
  case dropWhile (/= "--crash-once-marker") args of
    _ : marker : _ -> do
      exists <- doesFileExist marker
      unless exists (writeFile marker "crashed\n" >> exitWith (ExitFailure 86))
    _ -> pure ()

updateDocument :: TQueue Event -> Incoming -> State -> DocumentSnapshot -> IO ()
updateDocument events incoming state document = do
  path <- canonicalizePath document.snapshotPath
  let canonical = document {snapshotPath = path}
      message = case incoming.envelopePayload of
        OpenDocument _ -> OpenDocument canonical
        _ -> UpdateDocumentSnapshot canonical
  when (belongsToRunning state canonical) (forward state incoming {envelopePayload = message})
  loop events state {documents = Map.insert document.snapshotDocumentId canonical state.documents,
    documentPaths = Map.insert document.snapshotDocumentId document.snapshotPath state.documentPaths}

trusted :: State -> Bool
trusted state = case state.workspace of
  Just (ProtocolEnvelope {envelopePayload = OpenWorkspace request}) -> request.workspaceRequestTrust == TrustedWorkspace
  _ -> False

rootOf :: State -> FilePath
rootOf state = case state.workspace of
  Just (ProtocolEnvelope {envelopePayload = OpenWorkspace request}) -> request.workspaceRequestRoot
  _ -> "."

cacheOf :: State -> IO FilePath
cacheOf state = do
  base <- getXdgDirectory XdgCache "visual-haskell/projects"
  pure (base </> show (unContentHash (contentHash (Text.pack (rootOf state)))))

discover :: TQueue Event -> Incoming -> State -> IO State
discover = discoverAfter 0
discoverDelayed :: TQueue Event -> Incoming -> State -> IO State
discoverDelayed = discoverAfter 350000
discoverAfter :: Int -> TQueue Event -> Incoming -> State -> IO State
discoverAfter delay events incoming state = do
  cache <- cacheOf state
  let token = state.epoch
      progress message = atomically (writeTQueue events (Progress token incoming message))
  worker <- async $ do
    threadDelay delay
    result <- try (discoverProject True (runTool progress) (rootOf state) state.preferred cache)
    atomically (writeTQueue events (CatalogReady token incoming result))
  respond incoming (ProjectProgress "Discovering project packages and components")
  pure state {job = Just worker}

routeAnalysis :: TQueue Event -> Incoming -> State -> IO State
routeAnalysis events incoming state = case (incoming.envelopePayload, state.catalog) of
  (_, Just value) | value.catalogSelectedProfile == Nothing ->
    failed incoming "project-profile-choice-required" "Choose a Stack or Cabal configuration in the project selector" >> pure state {pending = Just incoming}
  (AnalyzeDocument document, Just value) -> case Map.lookup document state.documents of
    Nothing -> failed incoming "document-unavailable" "The requested document is not open" >> pure state
    Just snapshot -> case ownersForPath value.catalogComponents snapshot.snapshotPath of
      [component] -> use component
      owners | Just chosen <- find (\c -> Just c.projectComponentId == state.selected) owners -> use chosen
      [] | any ((== CradleComponent) . projectComponentKind) value.catalogComponents -> legacy
      [] -> failed incoming "file-outside-project" "This file is not owned by a component in the selected configuration" >> pure state
      _ -> failed incoming "component-choice-required" "This source belongs to several components; select its library, executable, test or benchmark context" >> pure state {pending = Just incoming}
  (_, Nothing) | state.managedProject -> failed incoming "project-not-ready" "Project discovery did not complete; select a configuration or use Reload / Retry" >> pure state
  (_, Nothing) -> legacy
  _ -> pure state
  where
    use :: ProjectComponent -> IO State
    use component = case state.running of
      Just (Running _ (Just context) _) | context.resolvedComponent == component.projectComponentId ->
        case incoming.envelopePayload of
          AnalyzeDocument document | Just snapshot <- Map.lookup document state.documents,
            not (any (`within` snapshot.snapshotPath) context.resolvedSourceRoots) ->
              failed incoming "file-not-in-active-component" "This source directory is disabled by the active project flags; choose another component or configuration" >> pure state
          _ -> forward state incoming >> pure state
      _ -> prepare events incoming component.projectComponentId state {pending = Just incoming}
    legacy = case state.running of
      Just (Running _ Nothing _) -> forward state incoming >> pure state
      _ -> do
        next <- startChild events incoming Nothing state
        forward next incoming
        pure next

prepare :: TQueue Event -> Incoming -> ComponentId -> State -> IO State
prepare events incoming component state = case state.catalog >>= find ((== component) . projectComponentId) . catalogComponents of
  Nothing -> failed incoming "component-unavailable" "Rediscover the project before selecting this component" >> pure state
  Just descriptor -> do
    stopped <- invalidateSession state
    let next = stopped {selected = Just component}
    case Map.lookup component next.contexts of
      Just cached -> do
        started <- startChild events incoming (Just cached) next
        case state.pending of
          Just request -> routeAnalysis events request started {pending = Nothing}
          Nothing -> pure started
      Nothing -> do
        cache <- cacheOf next
        let token = next.epoch
            progress message = atomically (writeTQueue events (Progress token incoming message))
        worker <- async $ do
          result <- try (prepareProjectContext (runTool progress) (cache </> "contexts" </> show (unContentHash (contentHash component.unComponentId)))
            (fromMaybe emptyProjectCatalog next.catalog) descriptor)
          atomically (writeTQueue events (ContextReady token incoming result))
        respond incoming (ProjectProgress ("Preparing " <> descriptor.projectComponentTarget))
        pure next {job = Just worker}

startChild :: TQueue Event -> Incoming -> Maybe ResolvedContext -> State -> IO State
startChild events incoming context state = do
  stopRunning state.running
  executable <- getExecutablePath
  args <- getArgs
  let token = state.childEpoch + 1
      hello = protocolEnvelope incoming.envelopeWorkspaceGeneration
        (ClientHelloMessage (ClientHello "project-coordinator/0.2.0" Nothing TrustedWorkspace [FullDocumentSnapshotsCapability]))
      launch = (defaultWorkerLaunch executable) {workerArguments = "--session-worker" : args}
  client <- startAnalysisClient launch hello (atomically . writeTQueue events . ChildEvent token)
  forM_ state.workspace (sendAnalysisMessage client)
  forM_ context (\value -> sendAnalysisMessage client incoming {envelopePayload = ConfigureContext value})
  forM_ (Map.elems state.documents) $ \document ->
    when (maybe True (\value -> any (`within` document.snapshotPath) value.resolvedSourceRoots) context) $
      sendAnalysisMessage client incoming {envelopePayload = UpdateDocumentSnapshot document, envelopeDocument = Just document.snapshotDocumentId}
  pure state {running = Just (Running token context client), childEpoch = token}

belongsToRunning :: State -> DocumentSnapshot -> Bool
belongsToRunning state document = case state.running of
  Just (Running _ (Just context) _) -> any (`within` document.snapshotPath) context.resolvedSourceRoots
  _ -> True
forward :: State -> Incoming -> IO ()
forward state incoming = case state.running of Just (Running _ _ client) -> sendAnalysisMessage client incoming; _ -> pure ()
forwardOrFail :: State -> Incoming -> IO ()
forwardOrFail state incoming = case state.running of
  Just _ | state.job == Nothing -> forward state incoming
  _ -> failed incoming "context-not-ready" "Wait for component preparation to complete"

invalidateSession :: State -> IO State
invalidateSession state = do
  forM_ state.job cancel
  stopRunning state.running
  pure state {job = Nothing, running = Nothing, epoch = state.epoch + 1, childEpoch = state.childEpoch + 1}
invalidate :: State -> IO State
invalidate state = do
  state.watcher
  next <- invalidateSession state
  pure next {contexts = Map.empty, catalog = Nothing, watcher = pure (), watchEpoch = state.watchEpoch + 1}
cleanup :: State -> IO ()
cleanup state = void (invalidate state)
stopRunning :: Maybe Running -> IO ()
stopRunning value = forM_ value $ \(Running _ _ client) -> do
  stopAnalysisClient client
  void (timeout 3000000 (waitAnalysisClient client))

startWatching :: TQueue Event -> Int -> Maybe Incoming -> ProjectCatalog -> IO (IO ())
startWatching events token incoming value = do
  attempted <- try $ do
    manager <- FS.startManager
    let candidates = nub (map profileRoot value.catalogProfiles <> map projectComponentRoot value.catalogComponents)
        roots = [root | root <- candidates, not (any (\other -> other /= root && other `within` root) candidates)]
        relevant event = let path = normalise (FS.eventPath event) in not (ignored path) &&
          (isConfiguration path || path `elem` value.catalogConfigurationFiles || takeExtension path `elem` [".hs", ".lhs", ".hs-boot", ".hsc", ".chs", ".h", ".hpp", ".c"])
    let handler = atomically . writeTQueue events . DiskChanged token . normalise . FS.eventPath
        externalDirectories = nub [takeDirectory path | path <- value.catalogConfigurationFiles, isAbsolute path,
          not (any (`within` path) roots)]
    stops <- ((++) <$> (forM roots $ \root -> FS.watchTree manager root relevant handler)
      <*> (forM externalDirectories $ \root -> FS.watchDir manager root relevant handler))
      `onException` FS.stopManager manager
    pure (sequence_ stops >> FS.stopManager manager)
  case attempted of
    Right stop -> pure stop
    Left (exception :: SomeException) -> do
      forM_ incoming (\request -> respond request (ProjectProgress ("Automatic watching unavailable; use Reload / Retry. " <> Text.pack (displayException exception))))
      pure (pure ())
  where forM = flip mapM
ignored :: FilePath -> Bool
ignored path = any (`elem` [".git", ".stack-work", "dist-newstyle", ".ide-cache", "bios-cache"]) (splitDirectories path)
isConfiguration :: FilePath -> Bool
isConfiguration path = takeExtension path == ".cabal" ||
  ("stack" `Text.isPrefixOf` Text.pack (takeFileName path) && takeExtension path == ".yaml") ||
  "cabal.project." `Text.isPrefixOf` Text.pack (takeFileName path) || takeFileName path `elem`
  ["package.yaml", "hie.yaml", "cabal.project", "cabal.project.local", "cabal.project.freeze", "stack.yaml", "stack.yaml.lock"]
within :: FilePath -> FilePath -> Bool
within root path = let relative = makeRelative (normalise root) (normalise path)
  in not (isAbsolute relative) && case splitDirectories relative of ".." : _ -> False; _ -> True

respond :: Incoming -> WorkerMessage -> IO ()
respond incoming payload = do
  result <- writeFrame defaultFrameLimits stdout (ProtocolEnvelope protocolV2 incoming.envelopeRequestId incoming.envelopeWorkspace
    incoming.envelopeWorkspaceGeneration incoming.envelopeSession incoming.envelopeDocument incoming.envelopeRevision
    incoming.envelopeContentHash incoming.envelopeInputHash payload)
  either (fail . show) pure result
failed :: Incoming -> Text -> Text -> IO ()
failed incoming code message = respond incoming (WorkerRequestFailed incoming.envelopeRequestId (RequestFailure code message True))
