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
import Control.Exception (bracket, displayException)
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
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (catMaybes)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Time.Clock (UTCTime, getCurrentTime)
import qualified GHC
import GHC.Builtin.Types (listTyCon)
import GHC.Core.Class (classMethods, classSCTheta)
import GHC.Core.ConLike (ConLike (..))
import GHC.Core.DataCon
  ( DataCon
  , dataConFieldLabels
  , dataConFullSig
  , dataConName
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
  , splitTyConApp_maybe
  )
import GHC.Data.StringBuffer (stringToStringBuffer)
import GHC.Driver.Monad (pushLogHookM)
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
  , isFieldNameSpace
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
  ( moduleName
  , moduleUnit
  , unitString
  )
import HIE.Bios.Environment (initSession)
import HIE.Bios.Types (ComponentOptions (..))
import Language.Haskell.Syntax.Basic (FieldLabelString (..))
import Language.Haskell.Syntax.Module.Name (moduleNameString)
import System.FilePath (normalise)
import VisualHaskell.Analysis.Ghc910.Types
import VisualHaskell.Semantic

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
        _ <- initSession componentOptions
        captureReference <- liftIO (newIORef Nothing)
        pushLogHookM (const (captureCurrentLog captureReference))
        liftIO (atomically (putTMVar ready ()))
        engineLoop invocation captureReference requests Map.empty
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
  -> TargetCache
  -> GHC.Ghc ()
engineLoop invocation captureReference requests targetCache = do
  request <- liftIO (atomically (readTQueue requests))
  (result, updatedTargetCache) <-
    analyzeInCurrentSession
      invocation
      captureReference
      targetCache
      request.requestDocuments
      request.requestDocument
      request.requestGeneration
  liftIO (atomically (putTMVar request.requestResponse result))
  engineLoop invocation captureReference requests updatedTargetCache

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
      targets <-
        traverse
          (\snapshot -> snapshotTarget (targetTimestamp targetCache snapshot) snapshot)
          (Map.elems documents)
      GHC.setTargets targets
      loadResult <- GHC.load GHC.LoadAllTargets
      liftIO (writeIORef captureReference Nothing)
      diagnostics <- liftIO (readIORef diagnosticReference)
      (declarations, typeTable) <-
        case loadResult of
          GHC.Failed -> pure ([], Map.empty)
          GHC.Succeeded -> declarationsFor requestedSnapshot
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
          _ -> (version, now)

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

snapshotTarget :: GHC.GhcMonad monad => UTCTime -> DocumentSnapshot -> monad GHC.Target
snapshotTarget now snapshot = do
  target <- GHC.guessTarget snapshot.snapshotPath Nothing Nothing
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
      captureLog diagnosticReference snapshot logFlags messageClass sourceSpan message

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
      renderedCode = Text.pack . show <$> code
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
      , diagnosticSource = "GHC 9.10.3"
      , diagnosticCode = renderedCode
      , diagnosticMessage = rendered
      , diagnosticRange = range
      , diagnosticRelated = []
      }

declarationsFor
  :: GHC.GhcMonad monad
  => DocumentSnapshot
  -> monad ([Declaration RevisionedSourceRange], TypeTable)
declarationsFor snapshot = do
  graph <- GHC.getModuleGraph
  let summaries =
        filter
          (\summary -> fmap normalise (GHC.ml_hs_file (GHC.ms_location summary)) == Just (normalise snapshot.snapshotPath))
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
        { declarationId = declarationIdFor declarationNameValue range
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

declarationIdFor :: Text -> RevisionedSourceRange -> DeclarationId
declarationIdFor name range =
  DeclarationId ("ghc:" <> name <> ":" <> Text.pack (show range))

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
  let (_, existentialVariables, _, constraints, arguments, result) =
        dataConFullSig constructor
   in fmap varType existentialVariables
        <> constraints
        <> fmap scaledThing arguments
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
    (_, existentialVariables, _, constraints, arguments, result) =
      dataConFullSig constructor

typeMethodSemanticsFor
  :: DocumentSnapshot
  -> GHC.Id
  -> TypeMethodSemantics RevisionedSourceRange
typeMethodSemanticsFor snapshot method =
  TypeMethodSemantics
    { typeMethodSemanticDeclaration =
        maybe
          (DeclarationId ("ghc:" <> stableNameIdentity methodName))
          (declarationIdFor (nameText methodName))
          methodRange
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
  | Just (constructor, arguments) <- splitTyConApp_maybe ghcType = do
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
qualifiedName = Text.pack . showSDocUnsafe . ppr

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
  SessionId
    ( "ghc-9.10.3:"
        <> Text.pack (show (contentHash (Text.pack (invocation.invocationComponentRoot <> show invocation.invocationCompilerOptions))))
    )

failure :: Text -> Text -> Bool -> GhcAnalysisFailure
failure code message recoverable =
  GhcAnalysisFailure
    { failureCode = code
    , failureMessage = message
    , failureRecoverable = recoverable
    }
