{-# LANGUAGE CPP #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module VisualHaskell.Analysis.Ghc910.Compat
  ( AnalysisEngine
  , analyzeWithEngine
  , analyzeWithGhc910
  , analysisEngineIsRunning
  , startAnalysisEngine
  , stopAnalysisEngine
  , queryWithEngine
  , checkCompositionWithEngine
  , searchSymbolsWithEngine
  , inspectCompilerUnits
  ) where

import Control.Concurrent.Async
  ( Async
  , async
  , cancel
  , poll
  , race
  , waitCatch
  )
import Control.Concurrent.STM
  ( TQueue
  , TMVar
  , atomically
  , newEmptyTMVarIO
  , newTQueueIO
  , putTMVar
  , readTQueue
  , takeTMVar
  , writeTQueue
  )
import Control.Exception (bracket, displayException, try, IOException)
import Control.Monad (forM, forM_, void)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.State.Strict (State, execState, get, modify')
import Data.IORef
  ( IORef
  , modifyIORef'
  , newIORef
  , readIORef
  , writeIORef
  )
import Data.List (find, sortOn, nub, isSuffixOf)
import Data.Char (isAlphaNum)
import qualified Data.Set as Set
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (catMaybes)
import Data.Aeson (eitherDecode, encode)
import qualified Data.ByteString.Lazy as LazyBytes
import Data.Version (showVersion)
import GHC.Fingerprint (getFileHash)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.IO as TextIO
import Data.Time.Clock (UTCTime, getCurrentTime, addUTCTime)
import qualified GHC
import qualified GHC.Iface.Ext.Ast as Hie
import qualified GHC.Iface.Ext.Types as Hie
import qualified GHC.Iface.Ext.Utils as Hie
import qualified GHC.Tc.Types as Tc
import qualified GHC.Types.Name.Reader as Reader
import GHC.Builtin.Types (listTyCon)
import GHC.Core.Class (classMethods, classSCTheta)
import GHC.Core.ConLike (ConLike (..))
import GHC.Core.DataCon
  ( DataCon
  , dataConFieldLabels
  , dataConFullSig
  , dataConName
  , dataConOrigArgTys
  , dataConRepType
  )
import GHC.Core.TyCon
  ( isTupleTyCon
  , isAlgTyCon
  , isFamilyTyCon
  , isNewTyCon
  , synTyConRhs_maybe
  , tyConClass_maybe
  , tyConDataCons
  , tyConName
  , tyConTyVars
  )
import GHC.Core.TyCo.Rep (scaledThing)
import GHC.Core.Type
  ( Type
  , getTyVar_maybe
  , splitAppTy_maybe
  , splitForAllTyCoVar_maybe
  , splitFunTy_maybe
  , splitTyConAppNoView_maybe
  )
import GHC.Data.StringBuffer (stringToStringBuffer)
import qualified GHC.Data.Strict as Strict
import GHC.Driver.Monad (pushLogHookM, modifySession)
import GHC.Driver.Env (hscSetActiveUnitId, hsc_all_home_unit_ids, hsc_unit_env, hsc_units)
import GHC.Unit.State (listVisibleModuleNames, lookupUnit, moduleNameProvidersMap, ModuleOrigin (..))
import GHC.Unit.Info (unitPackageNameString, unitPackageVersion, unitAbiHash, unitId)
import GHC.Unit.Module.ModIface (mi_usages)
import GHC.Unit.Module.Deps (Usage (..))
#if MIN_VERSION_ghc(9,10,0)
import GHC.Types.Unique.Map (lookupUniqMap)
#endif
import qualified GHC.Driver.Session as DynFlags
import qualified GHC.Unit.Env as UnitEnv
import GHC.Types.Error
  ( DiagnosticCode
  , MessageClass (..)
  , Severity (..)
  )
import GHC.Types.Id (idType)
import GHC.Types.FieldLabel
  ( flLabel
  , flSelector
  )
import GHC.Types.Name
  ( Name
  , nameModule_maybe
  , nameOccName
  , nameSrcSpan
  )
import GHC.Types.Name.Occurrence
  ( NameSpace
  , isDataConNameSpace
#if MIN_VERSION_ghc(9,8,0)
  , isFieldNameSpace
#endif
  , isTcClsNameSpace
  , isVarNameSpace
  , occNameSpace
  , occNameString
  )
import GHC.Types.SrcLoc
  ( RealSrcSpan
  , SrcSpan (..)
  , srcSpanEndCol
  , srcSpanEndLine
  , srcSpanFile
  , srcSpanStartCol
  , srcSpanStartLine
  )
import GHC.Types.TyThing (TyThing (..))
import GHC.Types.Var
  ( isInvisibleFunArg
  , tyVarKind
  , varType
  )
import GHC.Utils.Outputable
  ( SDoc
  , ppr
  , renderWithContext
  , showSDocUnsafe
  )
import GHC.Utils.Logger (LogAction, LogFlags (..))
import GHC.Data.FastString (unpackFS)
import GHC.Unit.Types
  ( mkModule
  , UnitId
  , moduleName
  , moduleUnit
  , toUnitId
  , unitString
  , stringToUnitId
  , unitIdString
  )
import HIE.Bios.Environment (initSession)
import VisualHaskell.Analysis.Ghc910.Version (compilerVersionText)
import HIE.Bios.Types (ComponentOptions (..))
import Language.Haskell.Syntax.Basic (FieldLabelString (..))
import Language.Haskell.Syntax.Module.Name (moduleNameString)
import System.FilePath
import System.Directory (getXdgDirectory, XdgDirectory (XdgCache), createDirectoryIfMissing, renameFile)
import System.IO (stderr, hClose)
import System.IO.Temp (withTempFile)
import VisualHaskell.Analysis.Ghc910.Types
import VisualHaskell.Semantic
import VisualHaskell.Analysis.Protocol.Queries

#if !MIN_VERSION_ghc(9,8,0)
-- Before GHC 9.8 record selectors share the ordinary variable namespace.
isFieldNameSpace :: NameSpace -> Bool
isFieldNameSpace _ = False
#endif

#if MIN_VERSION_ghc(9,8,0)
readerName :: Reader.GlobalRdrEltX info -> Name
readerName = Reader.greName
#else
readerName :: Reader.GlobalRdrElt -> Name
readerName = Reader.greMangledName
#endif

-- Ask GHC to interpret the actual flags rather than guessing source roots from
-- every conditional branch of a .cabal file. This does NOT load source code.
inspectCompilerUnits :: FilePath -> ComponentOptions -> IO [(Text, FilePath, [FilePath])]
inspectCompilerUnits libdir options = GHC.runGhc (Just libdir) $ do
  _ <- initSession options
  environment <- GHC.getSession
  pure [let flags = UnitEnv.homeUnitEnv_dflags (UnitEnv.ue_findHomeUnitEnv unit (hsc_unit_env environment))
            directory = maybe options.componentRoot (absolute options.componentRoot) (DynFlags.workingDirectory flags)
        in (Text.pack (unitIdString unit), directory, nub (map (absolute directory) (DynFlags.importPaths flags)))
       | unit <- Set.toList (hsc_all_home_unit_ids environment)]
  where absolute root path = normalise (if isAbsolute path then path else root </> path)

-- | A single component-scoped GHC session. The worker thread owns the Ghc
-- monad for its entire lifetime; callers communicate through typed requests.
-- This preserves GHC's module graph, home-unit table, parsed modules, and
-- typechecked modules between editor revisions.
data AnalysisEngine = AnalysisEngine
  { engineRequests :: !(TQueue EngineRequest)
  , engineWorker :: !(Async ())
  }

data EngineRequest = EngineRequest
  { requestDocuments :: !(Map DocumentId DocumentSnapshot)
  , requestDocument :: !DocumentId
  , requestGeneration :: !WorkspaceGeneration
  , requestResponse :: !(TMVar (Either GhcAnalysisFailure (AnalysisSnapshot RevisionedSourceRange)))
  }
  | EngineQuery !(Map DocumentId DocumentSnapshot) !DocumentId !PositionQuery
      !(TMVar (Either GhcAnalysisFailure PositionResult))
  | EngineComposition !(Map DocumentId DocumentSnapshot) !DocumentId !CompositionQuery
      !(TMVar (Either GhcAnalysisFailure CompositionResult))
  | EngineSymbols !(Map DocumentId DocumentSnapshot) !DocumentId !SymbolQuery
      !(TMVar (Either GhcAnalysisFailure SymbolSearchResult))

data SymbolIndexStore = SymbolIndexStore
  { indexVersions :: !(Map DocumentId (FilePath, TextRevision, ContentHash))
  , indexSources :: ![(FilePath, Maybe ContentHash)]
  , indexSymbols :: ![IndexedSymbol]
  , indexLibrarySymbols :: ![IndexedSymbol]
  , indexLocalModules :: !Int
  , indexLibraryModules :: !Int
  , indexCacheHits :: !Int
  , indexWarnings :: ![Text]
  , indexComplete :: !Bool
  , indexRevision :: !ContentHash
  }

data QueryContext = QueryContext
  { contextDocument :: !DocumentSnapshot
  , contextVersions :: !(Map DocumentId (FilePath, TextRevision, ContentHash))
  , contextOccurrences :: ![(Int, Int, Name, Maybe Type)]
  , contextCandidates :: ![CompletionCandidate]
  , contextLocals :: ![(CompletionCandidate, [(Int, Int)])]
  }

data TargetVersion = TargetVersion
  { targetPath :: !FilePath
  , targetRevision :: !TextRevision
  , targetContentHash :: !ContentHash
  }
  deriving stock (Eq)

type TargetCache = Map DocumentId (TargetVersion, UTCTime)

type DiagnosticCapture =
  Maybe
    ( DocumentSnapshot
    , IORef [Diagnostic RevisionedSourceRange]
    )

startAnalysisEngine
  :: CompilerInvocation
  -> IO (Either GhcAnalysisFailure AnalysisEngine)
startAnalysisEngine invocation = do
  requests <- newTQueueIO
  ready <- newEmptyTMVarIO
  worker <-
    async $
      GHC.runGhc (Just invocation.invocationCompilerLibDir) $ do
        let componentOptions =
              ComponentOptions
                invocation.invocationCompilerOptions
                invocation.invocationComponentRoot
                invocation.invocationCradleDependencies
        targets <- initSession componentOptions
        GHC.setTargets targets
        captureReference <- liftIO (newIORef Nothing)
        indexReference <- liftIO (newIORef Nothing)
        pushLogHookM (const (captureCurrentLog captureReference))
        liftIO (atomically (putTMVar ready ()))
        engineLoop invocation captureReference requests targets indexReference Map.empty Nothing
  startup <- race (atomically (takeTMVar ready)) (waitCatch worker)
  case startup of
    Left () ->
      pure
        ( Right
            AnalysisEngine
              { engineRequests = requests
              , engineWorker = worker
              }
        )
    Right result -> do
      cancel worker
      pure
        ( Left
            ( failure
                "ghc-session-start-failed"
                (case result of
                  Left exception -> Text.pack (displayException exception)
                  Right () -> "The persistent GHC session stopped during initialization"
                )
                True
            )
        )

stopAnalysisEngine :: AnalysisEngine -> IO ()
stopAnalysisEngine engine = do
  cancel engine.engineWorker
  void (waitCatch engine.engineWorker)

analysisEngineIsRunning :: AnalysisEngine -> IO Bool
analysisEngineIsRunning engine =
  maybe True (const False) <$> poll engine.engineWorker

analyzeWithEngine
  :: AnalysisEngine
  -> Map DocumentId DocumentSnapshot
  -> DocumentId
  -> WorkspaceGeneration
  -> IO (Either GhcAnalysisFailure (AnalysisSnapshot RevisionedSourceRange))
analyzeWithEngine engine documents requested generation =
  case Map.lookup requested documents of
    Nothing -> pure (Left (failure "document-unavailable" "The requested document is not open" True))
    Just _ -> do
      response <- newEmptyTMVarIO
      atomically $
        writeTQueue
          engine.engineRequests
          EngineRequest
            { requestDocuments = documents
            , requestDocument = requested
            , requestGeneration = generation
            , requestResponse = response
            }
      completed <- race (atomically (takeTMVar response)) (waitCatch engine.engineWorker)
      pure $
        case completed of
          Left result -> result
          Right workerResult ->
            Left
              ( failure
                  "ghc-session-terminated"
                  (case workerResult of
                    Left exception -> Text.pack (displayException exception)
                    Right () -> "The persistent GHC session stopped before producing a result"
                  )
                  True
              )

engineLoop
  :: CompilerInvocation
  -> IORef DiagnosticCapture
  -> TQueue EngineRequest
  -> [GHC.Target]
  -> IORef (Maybe SymbolIndexStore)
  -> TargetCache
  -> Maybe QueryContext
  -> GHC.Ghc ()
engineLoop invocation captureReference requests declaredTargets indexReference targetCache queryContext = do
  request <- liftIO (atomically (readTQueue requests))
  case request of
    EngineSymbols documents document query response -> do
      (currentContext, updatedTargets) <- prepareQueryContext invocation captureReference targetCache documents document False queryContext
      result <- case (currentContext, Map.lookup document documents) of
        (Just context, Just snapshot) | context.contextDocument == snapshot && context.contextVersions == documentVersions documents -> do
          environment <- GHC.getSession
          GHC.handleSourceError (\exception -> do
            GHC.setSession environment
            liftIO (writeIORef indexReference Nothing)
            pure (Left (failure "index-source-error" (Text.pack (show exception)) True))) $ do
              index <- prepareSymbolIndex invocation declaredTargets indexReference documents
              let (total, page) = searchSymbols query index.indexSymbols
                  pinned = Map.elems (Map.fromList [(symbol.indexedDeclaration.declarationId, symbol) | symbol <- index.indexSymbols,
                    symbol.indexedDeclaration.declarationId `elem` take 64 query.symbolQueryPinned])
              pure (Right (SymbolSearchResult query page pinned total index.indexLocalModules index.indexLibraryModules index.indexCacheHits index.indexWarnings
                index.indexComplete index.indexRevision))
        _ -> pure (Left (failure "index-unavailable" "The active document must typecheck before indexing its component" True))
      liftIO (atomically (putTMVar response result))
      engineLoop invocation captureReference requests declaredTargets indexReference updatedTargets currentContext
    EngineComposition documents document query response -> do
      (currentContext, updatedTargets) <- prepareQueryContext invocation captureReference targetCache documents document False queryContext
      cachedIndex <- liftIO (readIORef indexReference)
      validIndex <- case cachedIndex of
        Just index -> liftIO (indexIsCurrent documents index)
        Nothing -> pure False
      result <- answerComposition invocation documents document query currentContext
        (if validIndex then maybe [] indexSymbols cachedIndex else [])
      liftIO (atomically (putTMVar response result))
      engineLoop invocation captureReference requests declaredTargets indexReference updatedTargets currentContext
    EngineQuery documents document query response -> do
      (currentContext, updatedTargets) <- prepareQueryContext invocation captureReference targetCache documents document (query.queryKind == CompletionQuery) queryContext
      result <- answerQuery invocation documents document query currentContext
      liftIO (atomically (putTMVar response result))
      engineLoop invocation captureReference requests declaredTargets indexReference updatedTargets currentContext
    EngineRequest {} -> do
      (result, updatedTargetCache) <-
        analyzeInCurrentSession invocation captureReference targetCache
          request.requestDocuments request.requestDocument request.requestGeneration
      freshContext <- case result of
        Right snapshot | snapshot.analysisCompleteness == Typechecked ->
          case Map.lookup request.requestDocument request.requestDocuments of
            Just document -> GHC.handleSourceError (const (pure Nothing)) (buildQueryContext invocation request.requestDocuments document)
            Nothing -> pure Nothing
        _ -> pure Nothing
      let retained = case freshContext of
            Just context -> Just context
            Nothing -> queryContext
      liftIO (atomically (putTMVar request.requestResponse result))
      engineLoop invocation captureReference requests declaredTargets indexReference updatedTargetCache retained

-- Queries can target another open buffer than the last background analysis.
-- Reuse the same GHC session, but refresh its context before answering. Tracking
-- every open target also prevents a definition span from being combined with
-- the hash of a newer, unsaved dependency.
prepareQueryContext
  :: CompilerInvocation -> IORef DiagnosticCapture -> TargetCache
  -> Map DocumentId DocumentSnapshot -> DocumentId -> Bool -> Maybe QueryContext
  -> GHC.Ghc (Maybe QueryContext, TargetCache)
prepareQueryContext invocation capture targets documents document allowLastGood context
  | Just current <- context
  , current.contextDocument.snapshotDocumentId == document
  , allowLastGood || current.contextVersions == documentVersions documents = pure (context, targets)
  | otherwise = do
      (result, updatedTargets) <- analyzeInCurrentSession invocation capture targets documents document (WorkspaceGeneration 0)
      fresh <- case (result, Map.lookup document documents) of
        (Right analysis, Just snapshot) | analysis.analysisCompleteness == Typechecked ->
          GHC.handleSourceError (const (pure Nothing)) (buildQueryContext invocation documents snapshot)
        _ -> pure Nothing
      pure (case fresh of Just value -> Just value; Nothing -> context, updatedTargets)

documentVersions :: Map DocumentId DocumentSnapshot -> Map DocumentId (FilePath, TextRevision, ContentHash)
documentVersions = Map.map (\snapshot -> (snapshot.snapshotPath, snapshot.snapshotRevision, snapshot.snapshotContentHash))

queryWithEngine
  :: AnalysisEngine -> Map DocumentId DocumentSnapshot -> DocumentId -> PositionQuery
  -> IO (Either GhcAnalysisFailure PositionResult)
queryWithEngine engine documents document query = do
  response <- newEmptyTMVarIO
  atomically (writeTQueue engine.engineRequests (EngineQuery documents document query response))
  completed <- race (atomically (takeTMVar response)) (waitCatch engine.engineWorker)
  pure $ case completed of
    Left result -> result
    Right _ -> Left (failure "ghc-session-terminated" "Compiler query session stopped" True)

checkCompositionWithEngine
  :: AnalysisEngine -> Map DocumentId DocumentSnapshot -> DocumentId -> CompositionQuery
  -> IO (Either GhcAnalysisFailure CompositionResult)
checkCompositionWithEngine engine documents document query = do
  response <- newEmptyTMVarIO
  atomically (writeTQueue engine.engineRequests (EngineComposition documents document query response))
  completed <- race (atomically (takeTMVar response)) (waitCatch engine.engineWorker)
  pure $ case completed of
    Left result -> result
    Right _ -> Left (failure "ghc-session-terminated" "Compiler composition session stopped" True)

searchSymbolsWithEngine
  :: AnalysisEngine -> Map DocumentId DocumentSnapshot -> DocumentId -> SymbolQuery
  -> IO (Either GhcAnalysisFailure SymbolSearchResult)
searchSymbolsWithEngine engine documents document query = do
  response <- newEmptyTMVarIO
  atomically (writeTQueue engine.engineRequests (EngineSymbols documents document query response))
  completed <- race (atomically (takeTMVar response)) (waitCatch engine.engineWorker)
  pure $ case completed of
    Left result -> result
    Right _ -> Left (failure "ghc-session-terminated" "Compiler index session stopped" True)

indexIsCurrent :: Map DocumentId DocumentSnapshot -> SymbolIndexStore -> IO Bool
indexIsCurrent documents index
  | index.indexVersions /= documentVersions documents = pure False
  | otherwise = (== index.indexSources) <$> sourceVersions documents (map fst index.indexSources)

sourceVersions :: Map DocumentId DocumentSnapshot -> [FilePath] -> IO [(FilePath, Maybe ContentHash)]
sourceVersions documents = traverse $ \path -> do
  hashValue <- case find ((== normalise path) . normalise . snapshotPath) (Map.elems documents) of
    Just snapshot -> pure (Just snapshot.snapshotContentHash)
    Nothing -> do
      hashed <- try (getFileHash path)
      pure (case hashed of Left (_ :: IOException) -> Nothing; Right fingerprint -> Just (contentHash (Text.pack (show fingerprint))))
  pure (path, hashValue)

sourceSnapshot :: Map DocumentId DocumentSnapshot -> FilePath -> IO (Maybe DocumentSnapshot)
sourceSnapshot documents path = case find ((== normalise path) . normalise . snapshotPath) (Map.elems documents) of
  Just snapshot -> pure (Just snapshot)
  Nothing -> do
    loaded <- try (TextIO.readFile path)
    pure $ case loaded of
      Left (_ :: IOException) -> Nothing
      Right source -> Just (DocumentSnapshot (DocumentId (Text.pack path)) path (TextRevision 0) (contentHash source) source UnknownLineEndings)

prepareSymbolIndex
  :: CompilerInvocation -> [GHC.Target] -> IORef (Maybe SymbolIndexStore)
  -> Map DocumentId DocumentSnapshot -> GHC.Ghc SymbolIndexStore
prepareSymbolIndex invocation declaredTargets reference documents = do
  previous <- liftIO (readIORef reference)
  current <- liftIO (maybe (pure False) (indexIsCurrent documents) previous)
  case previous of
    Just index | current && index.indexComplete -> pure index
    _ -> do
      -- The editor may have unrelated, broken buffers open. Restrict the full
      -- load to cradle-declared targets and overlays in their dependency graph.
      previousTargets <- GHC.getTargets
      let declared = [maybe target id (find (sameTarget target) previousTargets) | target <- declaredTargets]
      GHC.setTargets declared
      graph <- GHC.depanal [] False
      let paths = catMaybes (map (GHC.ml_hs_file . GHC.ms_location) (GHC.mgModSummaries graph))
          relevant target = case GHC.targetId target of
            GHC.TargetFile path _ -> normalise path `elem` map normalise paths
            _ -> any (`sameTarget` target) declared
          overlays = filter relevant previousTargets
      before <- liftIO (sourceVersions documents (nub paths))
      sourceSnapshots <- liftIO $ fmap Map.fromList $ forM paths $ \path -> do
        source <- sourceSnapshot documents path
        pure (normalise path, source)
      GHC.setTargets (declared <> [target | target <- overlays, not (any (`sameTarget` target) declared)])
      loaded <- GHC.handleSourceError (const (pure GHC.Failed)) (GHC.load GHC.LoadAllTargets)
      loadedGraph <- GHC.getModuleGraph
      let moduleSources = Map.fromList [(GHC.ms_mod summary, source)
            | summary <- GHC.mgModSummaries loadedGraph
            , Just path <- [GHC.ml_hs_file (GHC.ms_location summary)]
            , Just source <- [Map.lookup (normalise path) sourceSnapshots >>= id]]
      local <- case loaded of
        GHC.Failed -> pure []
        GHC.Succeeded -> fmap concat $ forM (GHC.mgModSummaries loadedGraph) $ \summary -> do
          case GHC.ml_hs_file (GHC.ms_location summary) >>= (\path -> Map.lookup (normalise path) sourceSnapshots >>= id) of
            Nothing -> pure []
            Just _ -> moduleSymbols (GHC.ms_mod summary) moduleSources
      environment <- GHC.getSession
      let memoryLibraries = Map.fromListWith (<>)
            [(symbol.indexedModule, [symbol]) | index <- maybe [] pure previous, symbol <- index.indexLibrarySymbols]
      libraries <- forM (listVisibleModuleNames (hsc_units environment)) $ \name ->
        GHC.handleSourceError (const (pure ([], False, Just (Text.pack (GHC.moduleNameString name))))) $ do
          resolved <- GHC.findModule name Nothing
          if toUnitId (moduleUnit resolved) `Set.member` hsc_all_home_unit_ids environment
            then pure ([], False, Nothing)
            else do
              let definingUnit = lookupUnit (hsc_units environment) (moduleUnit resolved)
                  -- A module re-export can rename the module itself, not just
                  -- its exported Names (base:Data.List -> ghc-internal:...).
                  origin =
#if MIN_VERSION_ghc(9,10,0)
                    lookupUniqMap (moduleNameProvidersMap (hsc_units environment)) name >>= (`lookupUniqMap` resolved)
#else
                    Map.lookup name (moduleNameProvidersMap (hsc_units environment)) >>= Map.lookup resolved
#endif
                  unit = case origin of
                    Just ModOrigin {fromExposedReexport = exposed, fromOrigUnit = original}
                      | original /= Just True, exposing : _ <- exposed -> Just exposing
                    _ -> definingUnit
                  key = Text.pack (show (invocation.invocationCompilerLibDir, invocation.invocationCompilerVersion,
                          unitString (moduleUnit resolved), GHC.moduleNameString name,
                          fmap (\value -> (unitIdString (unitId value), show (unitAbiHash value))) unit,
                          fmap (show . unitAbiHash) definingUnit))
              cached <- case Map.lookup (ModuleName (Text.pack (GHC.moduleNameString name))) memoryLibraries of
                Just symbols -> pure (Just symbols)
                Nothing -> liftIO (readLibraryCache key)
              case cached of
                Just symbols -> pure (symbols, True, Nothing)
                Nothing -> do
                  projected <- moduleSymbols resolved Map.empty
                  let symbols = [symbol
                        { indexedModule = ModuleName (Text.pack (GHC.moduleNameString name))
                        , indexedUnit = maybe symbol.indexedUnit (Text.pack . unitIdString . unitId) unit
                        , indexedPackage = maybe symbol.indexedPackage (Text.pack . unitPackageNameString) unit
                        , indexedPackageVersion = maybe symbol.indexedPackageVersion (Text.pack . showVersion . unitPackageVersion) unit
                        } | symbol <- projected]
                  liftIO (writeLibraryCache key symbols)
                  pure (symbols, False, Nothing)
      GHC.setTargets previousTargets
      dependentFiles <- fmap concat $ forM (GHC.mgModSummaries loadedGraph) $ \summary -> do
        info <- GHC.getModuleInfo (GHC.ms_mod summary)
        pure [usageFilePath usage | interface <- maybe [] pure (info >>= GHC.modInfoIface),
              usage@UsageFile {} <- mi_usages interface]
      versions <- liftIO (sourceVersions documents (nub (paths <> dependentFiles)))
      after <- liftIO (sourceVersions documents (nub paths))
      let localCurrent = before == after && Set.fromList paths == Set.fromList
            (catMaybes (map (GHC.ml_hs_file . GHC.ms_location) (GHC.mgModSummaries loadedGraph)))
          localSymbols = if localCurrent then local else []
          skipped = catMaybes [warning | (_, _, warning) <- libraries]
          warnings = ["Local component failed to typecheck; local index is unavailable" | GHC.Failed <- [loaded]]
            <> ["Sources changed while indexing; refresh to obtain local symbols" | not localCurrent]
            <> ["Unavailable or ambiguous library modules: " <> Text.intercalate ", " (take 20 skipped) | not (null skipped)]
          complete = case loaded of GHC.Succeeded -> localCurrent && null skipped; GHC.Failed -> False
          -- Library ABIs and compiler options are fixed for this engine's
          -- lifetime. Its UI scope additionally includes worker/session IDs.
          revision = contentHash (Text.pack (show (documentVersions documents, versions, complete, warnings)))
          index = SymbolIndexStore (documentVersions documents) versions
            (localSymbols <> concat [symbols | (symbols, _, _) <- libraries])
            (concat [symbols | (symbols, _, _) <- libraries])
            (case loaded of GHC.Succeeded | localCurrent -> length (GHC.mgModSummaries loadedGraph); _ -> 0)
            (length [() | (_, _, Nothing) <- libraries]) (length [() | (_, True, _) <- libraries]) warnings complete revision
      -- Retain usable library authority even when the local graph failed.
      -- Incomplete coverage is never reused as a complete search cache hit.
      liftIO (writeIORef reference (Just index))
      pure index

usageFilePath :: Usage -> FilePath
usageFilePath UsageFile {usg_file_path = path} =
#if MIN_VERSION_ghc(9,8,0)
  unpackFS path
#else
  path
#endif
usageFilePath _ = error "Expected GHC UsageFile"

moduleSymbols :: GHC.Module -> Map GHC.Module DocumentSnapshot -> GHC.Ghc [IndexedSymbol]
moduleSymbols exportedModule sources = do
  info <- GHC.getModuleInfo exportedModule
  environment <- GHC.getSession
  let unit = lookupUnit (hsc_units environment) (moduleUnit exportedModule)
      package = maybe "workspace" (Text.pack . unitPackageNameString) unit
      version = maybe "" (Text.pack . showVersion . unitPackageVersion) unit
  fmap catMaybes $ forM (maybe [] GHC.modInfoExports info) $ \name -> do
    thing <- GHC.lookupName name
    pure $ do
      value <- thing
      -- Keep the public import route separate from the defining source. A
      -- local re-export can point into another open or closed home module.
      let source = nameModule_maybe name >>= (`Map.lookup` sources)
          snapshot = maybe (DocumentSnapshot (DocumentId "interface") "" (TextRevision 0) (ContentHash 0) "" UnknownLineEndings) id source
          types = execState (mapM_ recordType (semanticTypesForThing value) >> case value of ATyCon constructor -> void (recordTypeConstructor constructor); _ -> pure ()) Map.empty
          range = sourceRangeFor snapshot (nameSrcSpan name)
          declaration = Declaration (DeclarationId ("ghc:" <> stableNameIdentity name)) (nameText name)
            (declarationKindFor value) range range (typeIdentity <$> typeOfThing value)
            (renderType <$> typeOfThing value) (fmap (fmap Just) (typeDeclarationSemanticsFor snapshot value))
      pure (IndexedSymbol declaration types (ModuleName (Text.pack (GHC.moduleNameString (moduleName exportedModule))))
        (Text.pack (unitString (moduleUnit exportedModule))) package version
        (snapshotPath <$> source) (snapshotContentHash <$> source))

-- Only immutable library interface projections are persisted. Unsaved and
-- local source text never enters this cache. Cache failures are non-fatal.
libraryCachePath :: Text -> IO FilePath
libraryCachePath key = do
  root <- getXdgDirectory XdgCache "visual-haskell/symbol-index/v2"
  pure (root </> show (contentHash key).unContentHash <.> "json")

readLibraryCache :: Text -> IO (Maybe [IndexedSymbol])
readLibraryCache key = do
  attempted <- try $ do
    path <- libraryCachePath key
    bytes <- LazyBytes.readFile path
    pure $ case eitherDecode bytes of
      Right (storedKey, symbols) | storedKey == key -> Just symbols
      _ -> Nothing
  pure (either (const Nothing) id (attempted :: Either IOException (Maybe [IndexedSymbol])))

writeLibraryCache :: Text -> [IndexedSymbol] -> IO ()
writeLibraryCache key symbols = do
  attempted <- try $ do
    path <- libraryCachePath key
    createDirectoryIfMissing True (takeDirectory path)
    withTempFile (takeDirectory path) "index.tmp" $ \temporary handle -> do
      LazyBytes.hPut handle (encode (key, symbols))
      hClose handle
      renameFile temporary path
  either (\(_ :: IOException) -> pure ()) pure attempted

answerComposition
  :: CompilerInvocation -> Map DocumentId DocumentSnapshot -> DocumentId -> CompositionQuery -> Maybe QueryContext
  -> [IndexedSymbol]
  -> GHC.Ghc (Either GhcAnalysisFailure CompositionResult)
answerComposition invocation documents document query context indexed = case (Map.lookup document documents, context) of
  (Just snapshot, Just current)
    | current.contextDocument == snapshot
    , current.contextVersions == documentVersions documents
    , length query.compositionFunctions >= 2
    , length query.compositionFunctions <= 32 -> do
        graph <- GHC.getModuleGraph
        case find (summaryMatches invocation snapshot) (GHC.mgModSummaries graph) of
          Nothing -> pure unavailable
          Just summary -> do
            info <- GHC.getModuleInfo (GHC.ms_mod summary)
            let names = maybe [] (maybe [] id . GHC.modInfoTopLevelScope) info
                declared = Map.fromList
                  [(DeclarationId ("ghc:" <> stableNameIdentity name), Left (nameText name)) | name <- names,
                    sourceRangeFor snapshot (nameSrcSpan name) /= Nothing]
                available = Map.union declared (Map.fromList [(symbol.indexedDeclaration.declarationId, Right symbol) | symbol <- indexed, symbolFunction symbol /= Nothing])
            case traverse (`Map.lookup` available) query.compositionFunctions of
              Nothing -> pure unavailable
              Just selected -> do
                environment <- GHC.getSession
                GHC.handleSourceError
                  (\exception -> do
                    GHC.setSession environment
                    pure (Right (CompositionResult query False Nothing (Just (Text.pack (show exception)))))) $ do
                  modifySession (hscSetActiveUnitId (toUnitId (moduleUnit (GHC.ms_mod summary))))
                  importsAndFunctions <- forM (zip [0 :: Int ..] selected) $ \(offset, entry) -> case entry of
                    Left function -> pure (Nothing, function, Nothing)
                    Right symbol -> do
                      let alias = "VHIndex" <> Text.pack (show offset)
                          function = alias <> "." <> symbol.indexedDeclaration.declarationName
                      imported <- GHC.parseImportDecl ("import qualified " <> Text.unpack symbol.indexedModule.unModuleName <> " as " <> Text.unpack alias)
                      pure (Just (GHC.IIDecl imported), function, Just symbol.indexedDeclaration.declarationId)
                  GHC.setContext (GHC.IIModule (GHC.ms_mod_name summary) : catMaybes [imported | (imported, _, _) <- importsAndFunctions])
                  identities <- forM importsAndFunctions $ \(_, function, expected) -> case expected of
                    Nothing -> pure True
                    Just identifier -> do
                      resolved <- GHC.parseName (Text.unpack function)
                      pure (any (\name -> DeclarationId ("ghc:" <> stableNameIdentity name) == identifier) resolved)
                  let functions = [function | (_, function, _) <- importsAndFunctions]
                      freshBinder offset = let candidate = "vhInput" <> Text.pack (show (offset :: Int))
                        in if candidate `elem` functions then freshBinder (offset + 1) else candidate
                      binder = freshBinder 0
                      body = foldl (\input function -> "(" <> function <> ") (" <> input <> ")") binder functions
                  if not (and identities) then GHC.setSession environment >> pure unavailable else do
                    inferred <- GHC.exprType GHC.TM_Inst (Text.unpack ("(\\" <> binder <> " -> " <> body <> ")"))
                    GHC.setSession environment
                    pure (Right (CompositionResult query True (Just (renderType inferred)) Nothing))
  _ -> pure unavailable
  where
    unavailable = Left (failure "composition-unavailable" "Composition requires current, successfully typechecked function declarations" True)

buildQueryContext :: CompilerInvocation -> Map DocumentId DocumentSnapshot -> DocumentSnapshot -> GHC.Ghc (Maybe QueryContext)
buildQueryContext invocation documents snapshot = do
  graph <- GHC.getModuleGraph
  case find (summaryMatches invocation snapshot) (GHC.mgModSummaries graph) of
    Nothing -> pure Nothing
    Just summary -> do
      parsed <- GHC.parseModule summary
      typed <- GHC.typecheckModule parsed
      case GHC.tm_renamed_source typed of
        Nothing -> pure Nothing
        Just renamed -> do
          let (environment, _) = GHC.tm_internals_ typed
              asts = Hie.enrichHie (GHC.tm_typechecked_source typed) renamed
                (Tc.tcg_ev_binds environment) (Tc.tcg_insts environment) (Tc.tcg_tcs environment)
              index = buildCoordinateIndex snapshot.snapshotRevision snapshot.snapshotText
              collect node =
                let info = Hie.nodeInfo node
                    range = realSourceRange snapshot.snapshotRevision (Hie.nodeSpan node)
                    offsets = (,) <$> positionToScalarOffset index range.sourceRangeStart
                                  <*> positionToScalarOffset index range.sourceRangeEnd
                    here = case offsets of
                      Right (start, end) ->
                        [ (start, end, name, Hie.identType details)
                        | (Right name, details) <- Map.toList (Hie.nodeIdentifiers info)
                        , not (Set.null (Hie.identInfo details))
                        ]
                      Left _ -> []
                 in here <> concatMap collect (Hie.nodeChildren node)
              occurrences = concatMap collect (Map.elems (Hie.getAsts asts))
          moduleInfo <- GHC.getModuleInfo (GHC.ms_mod summary)
          let globals = maybe [] (maybe [] Reader.globalRdrEnvElts . GHC.modInfoRdrEnv) moduleInfo
          candidates <- forM globals $ \entry -> do
            thing <- GHC.lookupName (readerName entry)
            let signature = maybe "" (maybe "" renderType . typeOfThing) thing
            pure [CompletionCandidate (Text.pack (showSDocUnsafe (ppr reader))) signature | reader <- Reader.greRdrNames entry]
          let scopeRanges Hie.ModuleScope = [(0, Text.length snapshot.snapshotText)]
              scopeRanges (Hie.LocalScope spanValue) = case sourceRangeFor snapshot (RealSrcSpan spanValue Strict.Nothing) of
                Just range -> case (,) <$> positionToScalarOffset index range.sourceRangeStart <*> positionToScalarOffset index range.sourceRangeEnd of
                  Right offsets -> [offsets]
                  Left _ -> []
                Nothing -> []
              scopeRanges Hie.NoScope = []
              bindingScopes context = case context of
                Hie.ValBind _ scope _ -> scopeRanges scope
                Hie.PatternBind first second _ -> scopeRanges first <> scopeRanges second
                Hie.TyVarBind scope _ -> scopeRanges scope
                _ -> []
              localCandidates node =
                [ (CompletionCandidate (Text.pack (occNameString (nameOccName name))) (maybe "" renderType (Hie.identType details)), ranges)
                | (Right name, details) <- Map.toList (Hie.nodeIdentifiers (Hie.nodeInfo node))
                , let ranges = concatMap bindingScopes (Set.toList (Hie.identInfo details))
                , not (null ranges)
                ] <> concatMap localCandidates (Hie.nodeChildren node)
              locals = concatMap localCandidates (Map.elems (Hie.getAsts asts))
          pure (Just (QueryContext snapshot (documentVersions documents) occurrences (concat candidates) locals))

answerQuery
  :: CompilerInvocation -> Map DocumentId DocumentSnapshot -> DocumentId -> PositionQuery -> Maybe QueryContext
  -> GHC.Ghc (Either GhcAnalysisFailure PositionResult)
answerQuery invocation documents document query context = case (Map.lookup document documents, context) of
  (Just snapshot, Just current)
    | current.contextDocument.snapshotDocumentId == document
    , query.queryOffset >= 0 && query.queryOffset <= Text.length snapshot.snapshotText
    , query.queryKind == CompletionQuery || (current.contextDocument == snapshot && current.contextVersions == documentVersions documents) -> do
        let offset = query.queryOffset
            prefix = Text.takeWhileEnd identifierChar (Text.take offset snapshot.snapshotText)
            start = offset - Text.length prefix
            at point = [o | o@(a,b,_,_) <- current.contextOccurrences, a <= point, point < b]
            directMatches = at offset
            matches = sortOn (\(a,b,_,_) -> b-a)
              (if null directMatches && query.queryKind == DefinitionQuery && offset > 0 then at (offset - 1) else directMatches)
        hovered <- case matches of
          (a,b,name,ty) : _ -> do
            thing <- GHC.lookupName name
            let inferred = case ty of
                  Just value -> Just value
                  Nothing -> thing >>= typeOfThing
            pure (Just (HoverInfo (Text.pack (occNameString (nameOccName name)))
              (maybe "" renderType inferred) (Text.pack . moduleNameString . moduleName <$> nameModule_maybe name) a (b-a)))
          [] -> pure Nothing
        definitions <- case (query.queryKind, matches) of
          (DefinitionQuery, (_,_,name,_) : _) -> liftIO (definitionForName invocation documents name)
          _ -> pure []
        let completions = take 200 . Map.elems . Map.fromList $
              [ (candidate.completionLabel, candidate)
              | candidate <- current.contextCandidates <>
                  [candidate | (candidate, ranges) <- current.contextLocals, any (\(a,b) -> a <= offset && offset <= b) ranges]
              , prefix `Text.isPrefixOf` candidate.completionLabel
              , candidate.completionLabel /= prefix
              , not ("$" `Text.isPrefixOf` candidate.completionLabel)
              ]
        pure (Right (PositionResult query
          (if query.queryKind == HoverQuery then hovered else Nothing)
          definitions (if query.queryKind == CompletionQuery then completions else [])
          start (Text.length prefix)))
  _ -> pure (Left (failure "query-unavailable" "Wait for a successful analysis of this document" True))
  where
    identifierChar character = isAlphaNum character || character `elem` ("_'." :: String)

definitionForName :: CompilerInvocation -> Map DocumentId DocumentSnapshot -> Name -> IO [DefinitionTarget]
definitionForName invocation documents name = case nameSrcSpan name of
  RealSrcSpan spanValue _ -> do
    let sourcePath = unpackFS (srcSpanFile spanValue)
        directory = case nameModule_maybe name >>= (\modul -> lookup (Text.pack (unitIdString (toUnitId (moduleUnit modul)))) invocation.invocationUnitDirectories) of
          Just root -> root
          Nothing -> invocation.invocationComponentRoot
        path = normalise (if isAbsolute sourcePath then sourcePath else directory </> sourcePath)
        open = find ((== path) . normalise . snapshotPath) (Map.elems documents)
    content <- case open of
      Just snapshot -> pure (Right (snapshot.snapshotRevision, snapshot.snapshotContentHash))
      Nothing -> do
        readResult <- try (TextIO.readFile path) :: IO (Either IOException Text)
        pure (fmap (\source -> (TextRevision 0, contentHash source)) readResult)
    pure $ case content of
      Right (revision, hashValue) -> [DefinitionTarget path (realSourceRange revision spanValue) hashValue]
      Left _ -> []
  _ -> pure []

analyzeWithGhc910
  :: CompilerInvocation
  -> Map DocumentId DocumentSnapshot
  -> DocumentId
  -> WorkspaceGeneration
  -> IO (Either GhcAnalysisFailure (AnalysisSnapshot RevisionedSourceRange))
analyzeWithGhc910 invocation documents requested generation =
  bracket (startAnalysisEngine invocation) stopStarted $ \started ->
    case started of
      Left engineFailure -> pure (Left engineFailure)
      Right engine -> analyzeWithEngine engine documents requested generation
  where
    stopStarted (Left _) = pure ()
    stopStarted (Right engine) = stopAnalysisEngine engine

analyzeInCurrentSession
  :: CompilerInvocation
  -> IORef DiagnosticCapture
  -> TargetCache
  -> Map DocumentId DocumentSnapshot
  -> DocumentId
  -> WorkspaceGeneration
  -> GHC.Ghc
      ( Either GhcAnalysisFailure (AnalysisSnapshot RevisionedSourceRange)
      , TargetCache
      )
analyzeInCurrentSession invocation captureReference previousTargets documents requested generation =
  case Map.lookup requested documents of
    Nothing ->
      pure
        ( Left (failure "document-unavailable" "The requested document is not open" True)
        , previousTargets
        )
    Just requestedSnapshot -> do
      now <- liftIO getCurrentTime
      let targetCache = refreshTargetCache now previousTargets documents
      diagnosticReference <- liftIO (newIORef [])
      liftIO (writeIORef captureReference (Just (requestedSnapshot, diagnosticReference)))
      previous <- GHC.getTargets
      overlays <- fmap concat $ forM (Map.elems documents) $ \snapshot -> do
        let units = [stringToUnitId (Text.unpack identifier) | (identifier, roots) <- invocation.invocationUnitRoots,
              any (\root -> pathWithin root snapshot.snapshotPath) roots]
        if null invocation.invocationUnitRoots
          then pure <$> snapshotTarget (targetTimestamp targetCache snapshot) snapshot Nothing
          else traverse (snapshotTarget (targetTimestamp targetCache snapshot) snapshot . Just) (nub units)
      let merged = [case find (sameTarget target) overlays of
              Just overlay -> overlay
              Nothing -> target {GHC.targetContents = Nothing} | target <- previous]
            <> [overlay | overlay <- overlays, not (any (`sameTarget` overlay) previous)]
          targets = concat [filter ((== unit) . GHC.targetUnitId) merged | unit <- nub (map GHC.targetUnitId merged)]
      GHC.setTargets targets
      -- Keep every open buffer in the module graph so dependencies can use
      -- their unsaved contents, but load only the requested module and its
      -- dependency closure. Loading every target also recompiles unrelated
      -- reverse dependants (often the largest application module) whenever a
      -- small leaf module is inspected.
      loadResult <- loadRequestedModule invocation requestedSnapshot
      liftIO (writeIORef captureReference Nothing)
      diagnostics <- liftIO (readIORef diagnosticReference)
      (declarations, typeTable) <-
        case loadResult of
          GHC.Failed -> pure ([], Map.empty)
          GHC.Succeeded -> declarationsFor invocation requestedSnapshot
      pure
        ( Right
            AnalysisSnapshot
              { analysisWorkspaceGeneration = generation
              , analysisSession = invocationSession invocation
              , analysisDocument = requested
              , analysisRevision = requestedSnapshot.snapshotRevision
              , analysisContentHash = requestedSnapshot.snapshotContentHash
              , analysisCompleteness =
                  case loadResult of
                    GHC.Succeeded -> Typechecked
                    GHC.Failed -> PartiallyFailed
              , analysisFreshness = CurrentAnalysis
              , analysisDiagnostics = diagnostics
              , analysisDeclarations = declarations
              , analysisTypes = typeTable
              }
        , targetCache
        )

loadRequestedModule :: CompilerInvocation -> DocumentSnapshot -> GHC.Ghc GHC.SuccessFlag
loadRequestedModule invocation requestedSnapshot =
  GHC.handleSourceError
    (\exception -> liftIO (TextIO.hPutStrLn stderr (Text.pack (show exception))) >> pure GHC.Failed)
    $ if length invocation.invocationUnitRoots > 1 then GHC.load GHC.LoadAllTargets else do
      graph <- GHC.depanal [] False
      case find (summaryMatches invocation requestedSnapshot) (GHC.mgModSummaries graph) of
        Nothing ->
          -- This should only be reachable for an unusual target that GHC
          -- cannot associate with a source location. Preserve correctness in
          -- that case, even though the fallback is intentionally slower.
          GHC.load GHC.LoadAllTargets
        Just summary ->
          let sourceModule = GHC.ms_mod summary
              homeModule =
                mkModule
                  (toUnitId (moduleUnit sourceModule))
                  (moduleName sourceModule)
           in GHC.load (GHC.LoadUpTo homeModule)

summaryMatches :: CompilerInvocation -> DocumentSnapshot -> GHC.ModSummary -> Bool
summaryMatches invocation snapshot summary =
  fmap normalise (GHC.ml_hs_file (GHC.ms_location summary)) == Just (normalise snapshot.snapshotPath)
    && maybe True (== Text.pack (unitIdString (toUnitId (moduleUnit (GHC.ms_mod summary)))) ) invocation.invocationPrimaryUnit

pathWithin :: FilePath -> FilePath -> Bool
pathWithin root path = let relative = makeRelative (normalise root) (normalise path)
  in not (isAbsolute relative) && case splitDirectories relative of ".." : _ -> False; _ -> True

-- A source may be a named module in the cradle targets but a file in an
-- overlay. Replace that target in the SAME home unit, never globally by name.
sameTarget :: GHC.Target -> GHC.Target -> Bool
sameTarget old new = GHC.targetUnitId old == GHC.targetUnitId new && case (GHC.targetId old, GHC.targetId new) of
  (GHC.TargetFile left _, GHC.TargetFile right _) -> normalise left == normalise right
  (GHC.TargetModule name, GHC.TargetFile path _) ->
    addTrailingPathSeparator (joinPath (Text.unpack <$> Text.splitOn "." (Text.pack (GHC.moduleNameString name)))) `isSuffixOf` addTrailingPathSeparator (dropExtension path)
  _ -> GHC.targetId old == GHC.targetId new

refreshTargetCache
  :: UTCTime
  -> TargetCache
  -> Map DocumentId DocumentSnapshot
  -> TargetCache
refreshTargetCache now previous =
  Map.mapWithKey $ \document snapshot ->
    let version = targetVersion snapshot
     in case Map.lookup document previous of
          Just (previousVersion, timestamp)
            | previousVersion == version -> (version, timestamp)
            | otherwise -> (version, max now (addUTCTime 1 timestamp))
          _ -> (version, addUTCTime 1 now)

targetVersion :: DocumentSnapshot -> TargetVersion
targetVersion snapshot =
  TargetVersion
    { targetPath = normalise snapshot.snapshotPath
    , targetRevision = snapshot.snapshotRevision
    , targetContentHash = snapshot.snapshotContentHash
    }

targetTimestamp :: TargetCache -> DocumentSnapshot -> UTCTime
targetTimestamp targetCache snapshot =
  case Map.lookup snapshot.snapshotDocumentId targetCache of
    Just (_, timestamp) -> timestamp
    Nothing -> error "Visual Haskell invariant: target cache omitted an open document"

snapshotTarget :: GHC.GhcMonad monad => UTCTime -> DocumentSnapshot -> Maybe UnitId -> monad GHC.Target
snapshotTarget now snapshot unit = do
  target <- GHC.guessTarget snapshot.snapshotPath unit Nothing
  pure
    target
      { GHC.targetAllowObjCode = False
      , GHC.targetContents = Just (stringToStringBuffer (Text.unpack snapshot.snapshotText), now)
      }

captureLog
  :: IORef [Diagnostic RevisionedSourceRange]
  -> DocumentSnapshot
  -> LogAction
captureLog reference snapshot logFlags messageClass sourceSpan message =
  case messageClass of
    MCDiagnostic severity _reason code ->
      case diagnosticFor snapshot logFlags severity code sourceSpan message of
        Nothing -> pure ()
        Just diagnostic -> modifyIORef' reference (<> [diagnostic])
    MCFatal ->
      case diagnosticFor snapshot logFlags SevError Nothing sourceSpan message of
        Nothing -> pure ()
        Just diagnostic -> modifyIORef' reference (<> [diagnostic])
    _ -> pure ()

captureCurrentLog :: IORef DiagnosticCapture -> LogAction
captureCurrentLog captureReference logFlags messageClass sourceSpan message = do
  current <- readIORef captureReference
  case current of
    Nothing -> pure ()
    Just (snapshot, diagnosticReference) ->
      do
        captureLog diagnosticReference snapshot logFlags messageClass sourceSpan message
        case messageClass of
          MCDiagnostic SevError _ _ -> TextIO.hPutStrLn stderr (Text.pack (renderWithContext logFlags.log_default_user_context message))
          MCFatal -> TextIO.hPutStrLn stderr (Text.pack (renderWithContext logFlags.log_default_user_context message))
          _ -> pure ()

diagnosticFor
  :: DocumentSnapshot
  -> LogFlags
  -> Severity
  -> Maybe DiagnosticCode
  -> SrcSpan
  -> SDoc
  -> Maybe (Diagnostic RevisionedSourceRange)
diagnosticFor snapshot logFlags severity code sourceSpan message = do
  range <- sourceRangeFor snapshot sourceSpan
  let rendered = Text.strip (Text.pack (renderWithContext logFlags.log_default_user_context message))
      renderedCode = Text.pack . showSDocUnsafe . ppr <$> code
      identity =
        DiagnosticId
          ( "ghc:"
              <> maybe "uncoded" id renderedCode
              <> ":"
              <> Text.pack (show (contentHash (rendered <> Text.pack (show range))))
          )
  pure
    Diagnostic
      { diagnosticId = identity
      , diagnosticSeverity = case severity of
          SevError -> DiagnosticError
          SevWarning -> DiagnosticWarning
          SevIgnore -> DiagnosticInformation
      , diagnosticSource = "GHC " <> compilerVersionText
      , diagnosticCode = renderedCode
      , diagnosticMessage = rendered
      , diagnosticRange = range
      , diagnosticRelated = []
      }

declarationsFor
  :: GHC.GhcMonad monad
  => CompilerInvocation
  -> DocumentSnapshot
  -> monad ([Declaration RevisionedSourceRange], TypeTable)
declarationsFor invocation snapshot = do
  graph <- GHC.getModuleGraph
  let summaries =
        filter
          (summaryMatches invocation snapshot)
          (GHC.mgModSummaries graph)
  case summaries of
    [] -> pure ([], Map.empty)
    summary : _ -> do
      info <- GHC.getModuleInfo summary.ms_mod
      case info >>= GHC.modInfoTopLevelScope of
        Nothing -> pure ([], Map.empty)
        Just names -> do
          declarationsAndTypes <- forM names $ \name -> do
            thing <- GHC.lookupName name
            pure (declarationFor snapshot name =<< thing)
          let projected = catMaybes declarationsAndTypes
              declarations = fmap (\(declaration, _, _) -> declaration) projected
              typeTable = execState (recordProjectedTypes projected) Map.empty
              declarationsWithIds = map (attachTypeId typeTable) declarations
          pure (declarationsWithIds, typeTable)

recordProjectedTypes
  :: [(Declaration range, [Type], Maybe GHC.TyCon)]
  -> State TypeTable ()
recordProjectedTypes projected =
  forM_ projected $ \(_, types, declaredConstructor) -> do
    mapM_ recordType types
    forM_ declaredConstructor recordTypeConstructor

declarationFor
  :: DocumentSnapshot
  -> Name
  -> TyThing
  -> Maybe (Declaration RevisionedSourceRange, [Type], Maybe GHC.TyCon)
declarationFor snapshot name thing = do
  range <- sourceRangeFor snapshot (nameSrcSpan name)
  let declarationNameValue = Text.pack (occNameString (nameOccName name))
      declarationTypeValue = typeOfThing thing
  pure
    ( Declaration
        { declarationId = DeclarationId ("ghc:" <> stableNameIdentity name)
        , declarationName = declarationNameValue
        , declarationKind = declarationKindFor thing
        , declarationRange = range
        , declarationSelectionRange = range
        , declarationType = typeIdentity <$> declarationTypeValue
        , declarationSignatureText = renderType <$> declarationTypeValue
        , declarationTypeSemantics = typeDeclarationSemanticsFor snapshot thing
        }
    , semanticTypesForThing thing
    , case thing of
        ATyCon constructor -> Just constructor
        _ -> Nothing
    )

declarationKindFor :: TyThing -> DeclarationKind
declarationKindFor = \case
  AnId _ -> ValueDeclaration
  ATyCon constructor
    | Just _ <- tyConClass_maybe constructor -> ClassDeclaration
    | otherwise -> TypeDeclaration
  AConLike _ -> DataConstructorDeclaration
  ACoAxiom _ -> UnsupportedDeclaration "coercion-axiom"

typeOfThing :: TyThing -> Maybe Type
typeOfThing = \case
  AnId identifier -> Just (idType identifier)
  ATyCon constructor -> Just (GHC.tyConKind constructor)
  AConLike (RealDataCon constructor) -> Just (dataConRepType constructor)
  AConLike (PatSynCon _) -> Nothing
  ACoAxiom _ -> Nothing

semanticTypesForThing :: TyThing -> [Type]
semanticTypesForThing thing =
  maybe [] pure (typeOfThing thing)
    <> case thing of
      ATyCon constructor -> semanticTypesForTyCon constructor
      _ -> []

semanticTypesForTyCon :: GHC.TyCon -> [Type]
semanticTypesForTyCon constructor =
  fmap tyVarKind (tyConTyVars constructor)
    <> maybe [] pure (synTyConRhs_maybe constructor)
    <> case tyConClass_maybe constructor of
      Just classValue ->
        classSCTheta classValue <> fmap idType (classMethods classValue)
      Nothing -> concatMap semanticTypesForDataCon (tyConDataCons constructor)

semanticTypesForDataCon :: DataCon -> [Type]
semanticTypesForDataCon constructor =
  let (_, existentialVariables, _, constraints, _, result) =
        dataConFullSig constructor
   in fmap varType existentialVariables
        <> constraints
        <> fmap scaledThing (dataConOrigArgTys constructor)
        <> [result]

typeDeclarationSemanticsFor
  :: DocumentSnapshot
  -> TyThing
  -> Maybe (TypeDeclarationSemantics RevisionedSourceRange)
typeDeclarationSemanticsFor snapshot = \case
  ATyCon constructor ->
    Just
      TypeDeclarationSemantics
        { typeDeclarationSemanticConstructor = typeConstructorIdentity constructor
        , typeDeclarationSemanticParameters =
            fmap typeParameterSemanticsFor (tyConTyVars constructor)
        , typeDeclarationSemanticDefinition =
            typeDeclarationDefinitionFor snapshot constructor
        }
  _ -> Nothing

typeParameterSemanticsFor :: GHC.TyVar -> TypeParameterSemantics
typeParameterSemanticsFor variable =
  TypeParameterSemantics
    { typeParameterSemanticName = nameText (GHC.getName variable)
    , typeParameterSemanticKind = Just (typeIdentity (tyVarKind variable))
    }

typeDeclarationDefinitionFor
  :: DocumentSnapshot
  -> GHC.TyCon
  -> TypeDeclarationDefinition RevisionedSourceRange
typeDeclarationDefinitionFor snapshot constructor
  | Just classValue <- tyConClass_maybe constructor =
      TypeClassSemantics
        (fmap typeIdentity (classSCTheta classValue))
        (fmap (typeMethodSemanticsFor snapshot) (classMethods classValue))
  | isFamilyTyCon constructor = TypeFamilySemantics
  | Just rhs <- synTyConRhs_maybe constructor = TypeAliasSemantics (typeIdentity rhs)
  | isNewTyCon constructor =
      case tyConDataCons constructor of
        dataConstructor : _ -> NewtypeSemantics (typeConstructorSemanticsFor snapshot dataConstructor)
        [] -> AbstractTypeSemantics "newtype has no visible data constructor"
  | isAlgTyCon constructor =
      AlgebraicTypeSemantics
        (fmap (typeConstructorSemanticsFor snapshot) (tyConDataCons constructor))
  | otherwise =
      AbstractTypeSemantics "GHC type constructor has no supported source definition shape"

typeConstructorSemanticsFor
  :: DocumentSnapshot
  -> DataCon
  -> TypeConstructorSemantics RevisionedSourceRange
typeConstructorSemanticsFor snapshot constructor =
  TypeConstructorSemantics
    { typeConstructorSemanticId = "ghc:data-constructor:" <> stableNameIdentity (dataConName constructor)
    , typeConstructorSemanticName = nameText (dataConName constructor)
    , typeConstructorSemanticExistentials =
        fmap
          (\variable ->
            TypeParameterSemantics
              { typeParameterSemanticName = nameText (GHC.getName variable)
              , typeParameterSemanticKind = Just (typeIdentity (varType variable))
              }
          )
          existentialVariables
    , typeConstructorSemanticConstraints = fmap typeIdentity constraints
    , typeConstructorSemanticArguments = fmap (typeIdentity . scaledThing) arguments
    , typeConstructorSemanticFields =
        [ TypeFieldSemantics
            { typeFieldSemanticId = "ghc:field:" <> stableNameIdentity (flSelector field)
            , typeFieldSemanticName = Text.pack (unpackFS (field_label (flLabel field)))
            , typeFieldSemanticType = typeIdentity (scaledThing argument)
            , typeFieldSemanticRange = sourceRangeFor snapshot (nameSrcSpan (flSelector field))
            }
        | (field, argument) <- zip (dataConFieldLabels constructor) arguments
        ]
    , typeConstructorSemanticResult = Just (typeIdentity result)
    , typeConstructorSemanticRange = sourceRangeFor snapshot (nameSrcSpan (dataConName constructor))
    }
  where
    (_, existentialVariables, _, constraints, _, result) =
      dataConFullSig constructor
    -- Original arguments retain source-facing synonyms when GHC preserves
    -- them (notably FilePath) and avoid representation-only argument shapes.
    -- GHC may still expand a local alias such as TraceSink; the pure diagram
    -- projection compacts an exact alias RHS back to its declared local node.
    arguments = dataConOrigArgTys constructor

typeMethodSemanticsFor
  :: DocumentSnapshot
  -> GHC.Id
  -> TypeMethodSemantics RevisionedSourceRange
typeMethodSemanticsFor snapshot method =
  TypeMethodSemantics
    { typeMethodSemanticDeclaration = DeclarationId ("ghc:" <> stableNameIdentity methodName)
    , typeMethodSemanticName = nameText methodName
    , typeMethodSemanticType = Just (typeIdentity methodType)
    , typeMethodSemanticSignatureText = Just (renderType methodType)
    , typeMethodSemanticRange = methodRange
    }
  where
    methodName = GHC.getName method
    methodType = idType method
    methodRange = sourceRangeFor snapshot (nameSrcSpan methodName)

typeConstructorIdentity :: GHC.TyCon -> TypeId
typeConstructorIdentity constructor =
  TypeId ("ghc:constructor:" <> stableNameIdentity (tyConName constructor))

nameText :: Name -> Text
nameText = Text.pack . occNameString . nameOccName

-- | GHC 'Unique' values and pretty-printer qualification are session-local.
-- Protocol identity therefore follows unit/module/namespace/occurrence, as
-- required by the stable semantic contract.
stableNameIdentity :: Name -> Text
stableNameIdentity name =
  Text.intercalate
    ":"
    (moduleIdentity <> [namespaceText (occNameSpace occurrence), Text.pack (occNameString occurrence)])
  where
    occurrence = nameOccName name
    moduleIdentity =
      case nameModule_maybe name of
        Nothing -> ["local"]
        Just definingModule ->
          [ Text.pack (unitString (moduleUnit definingModule))
          , Text.pack (moduleNameString (moduleName definingModule))
          ]

namespaceText :: NameSpace -> Text
namespaceText namespace
  | isFieldNameSpace namespace = "field"
  | isDataConNameSpace namespace = "data"
  | isTcClsNameSpace namespace = "type-class"
  | isVarNameSpace namespace = "value"
  | otherwise = "type-variable"

attachTypeId :: TypeTable -> Declaration range -> Declaration range
attachTypeId table declaration =
  declaration
    { declarationType =
        declaration.declarationType >>= (\identifier -> identifier <$ Map.lookup identifier table)
    }

recordType :: Type -> State TypeTable TypeId
recordType ghcType = do
  table <- get
  let identifier = typeIdentity ghcType
  case Map.lookup identifier table of
    Just _ -> pure identifier
    Nothing -> do
      modify' (Map.insert identifier (UnsupportedType (renderType ghcType)))
      normalized <- normalizeType ghcType
      modify' (Map.insert identifier normalized)
      pure identifier

normalizeType :: Type -> State TypeTable StructuredType
normalizeType ghcType
  | Just variable <- getTyVar_maybe ghcType =
      pure (TypeVariable (Text.pack (occNameString (nameOccName (GHC.getName variable)))))
  | Just (binder, body) <- splitForAllTyCoVar_maybe ghcType = do
      bodyIdentifier <- recordType body
      pure (ForallType [Text.pack (occNameString (nameOccName (GHC.getName binder)))] bodyIdentifier)
  | Just (flag, _, argument, result) <- splitFunTy_maybe ghcType =
      if isInvisibleFunArg flag
        then ConstrainedType <$> (pure <$> recordType argument) <*> recordType result
        else FunctionType <$> recordType argument <*> recordType result
  | Just (constructor, arguments) <- splitTyConAppNoView_maybe ghcType = do
      argumentIdentifiers <- traverse recordType arguments
      if constructor == listTyCon
        then case argumentIdentifiers of
          [element] -> pure (ListType element)
          _ -> pure (UnsupportedType (renderType ghcType))
        else if isTupleTyCon constructor
          then pure (TupleType argumentIdentifiers)
          else if null argumentIdentifiers
            then pure (TypeConstructor (qualifiedName (tyConName constructor)))
            else do
              constructorIdentifier <- recordTypeConstructor constructor
              pure (TypeApplication constructorIdentifier argumentIdentifiers)
  | Just (function, argument) <- splitAppTy_maybe ghcType =
      TypeApplication <$> recordType function <*> (pure <$> recordType argument)
  | otherwise = pure (UnsupportedType (renderType ghcType))

recordTypeConstructor :: GHC.TyCon -> State TypeTable TypeId
recordTypeConstructor constructor = do
  let name = qualifiedName (tyConName constructor)
      identifier = typeConstructorIdentity constructor
  modify' (Map.insert identifier (TypeConstructor name))
  pure identifier

typeIdentity :: Type -> TypeId
typeIdentity ghcType = TypeId ("ghc:type:" <> renderType ghcType)

renderType :: Type -> Text
renderType = Text.pack . showSDocUnsafe . ppr

qualifiedName :: Name -> Text
qualifiedName name =
  case nameModule_maybe name of
    Nothing -> occurrence
    Just definingModule ->
      Text.pack (moduleNameString (moduleName definingModule))
        <> "."
        <> occurrence
  where
    occurrence = nameText name

sourceRangeFor :: DocumentSnapshot -> SrcSpan -> Maybe RevisionedSourceRange
sourceRangeFor snapshot (RealSrcSpan realSpan _) =
  if normalise (unpackFS (srcSpanFile realSpan)) == normalise snapshot.snapshotPath
    then Just (realSourceRange snapshot.snapshotRevision realSpan)
    else Nothing
sourceRangeFor _ (UnhelpfulSpan _) = Nothing

realSourceRange :: TextRevision -> RealSrcSpan -> RevisionedSourceRange
realSourceRange revision realSpan =
  RevisionedSourceRange
    revision
    (SourcePosition (srcSpanStartLine realSpan - 1) (srcSpanStartCol realSpan - 1) GhcColumn)
    (SourcePosition (srcSpanEndLine realSpan - 1) (srcSpanEndCol realSpan - 1) GhcColumn)

invocationSession :: CompilerInvocation -> SessionId
invocationSession invocation =
  case invocation.invocationSessionIdentity of
   Just identity -> identity
   Nothing -> SessionId
    ( "ghc-" <> compilerVersionText <> ":"
        <> Text.pack (show (contentHash (Text.pack (invocation.invocationComponentRoot <> show invocation.invocationCompilerOptions))))
    )

failure :: Text -> Text -> Bool -> GhcAnalysisFailure
failure code message recoverable =
  GhcAnalysisFailure
    { failureCode = code
    , failureMessage = message
    , failureRecoverable = recoverable
    }
