{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

-- | The compiler-independent semantic contract consumed by Visual Haskell's
-- Types inspector.  The GHC worker returns revision-bound analysis snapshots;
-- this module turns one or more accepted snapshots into the product-level
-- universe used by both textual diagnostics and future visual renderers.
module VisualHaskell.Semantic.TypeUniverse
  ( TypeConstructorDefinition (..)
  , TypeConstructorId (..)
  , TypeDefinition (..)
  , TypeEditability (..)
  , TypeEntity (..)
  , TypeEntityId (..)
  , TypeFieldDefinition (..)
  , TypeFieldId (..)
  , TypeMethodDefinition (..)
  , TypeOrigin (..)
  , TypeParameter (..)
  , TypeRelation (..)
  , TypeRelationKind (..)
  , TypeUniverse (..)
  , TypeUniverseCoverage (..)
  , TypeUniverseScope (..)
  , TypeUniverseSource (..)
  , TypeUsage (..)
  , buildTypeUniverse
  , renderTypeUniverseDebug
  ) where

import Data.Graph (SCC (..), stronglyConnComp)
import Data.List (sortOn)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (mapMaybe)
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text
import VisualHaskell.Semantic.Types

newtype TypeEntityId = TypeEntityId {unTypeEntityId :: Text}
  deriving stock (Eq, Ord, Show)

newtype TypeConstructorId = TypeConstructorId {unTypeConstructorId :: Text}
  deriving stock (Eq, Ord, Show)

newtype TypeFieldId = TypeFieldId {unTypeFieldId :: Text}
  deriving stock (Eq, Ord, Show)

-- | The visible extent of a universe.  Project scope also records the focused
-- document so renderers can emphasize local declarations without changing the
-- set of project entities.
data TypeUniverseScope
  = CurrentDocumentTypes !DocumentId
  | ProjectTypes !WorkspaceId !(Maybe DocumentId)
  deriving stock (Eq, Ord, Show)

-- | Overall coverage is separate from per-document completeness.  In
-- particular, project scope over a set of accepted editor snapshots must not
-- be mistaken for a fully indexed workspace.
data TypeUniverseCoverage
  = NoTypeCoverage
  | ExactDocumentCoverage !DocumentId
  | AcceptedSnapshotsCoverage ![DocumentId]
  | IndexedProjectCoverage !WorkspaceId
  deriving stock (Eq, Ord, Show)

-- | Provenance is semantic rather than visual.  Backends may use it for color,
-- grouping, badges, or filtering, but the distinction remains available in
-- every presentation.
data TypeOrigin
  = CurrentDocumentOrigin !DocumentId
  | WorkspaceDocumentOrigin !DocumentId
  | PackageOrigin !Text !(Maybe Text) !ModuleName
  | BuiltinOrigin !ModuleName
  | UnknownOrigin !Text
  deriving stock (Eq, Ord, Show)

data TypeEditability
  = EditableSource
  | GeneratedSource
  | ReadOnlyDependency
  deriving stock (Eq, Ord, Show)

data TypeParameter = TypeParameter
  { typeParameterName :: !Text
  , typeParameterKind :: !(Maybe TypeId)
  }
  deriving stock (Eq, Ord, Show)

data TypeFieldDefinition range = TypeFieldDefinition
  { typeFieldId :: !TypeFieldId
  , typeFieldName :: !Text
  , typeFieldType :: !TypeId
  , typeFieldRange :: !(Maybe range)
  }
  deriving stock (Eq, Show)

data TypeConstructorDefinition range = TypeConstructorDefinition
  { typeConstructorId :: !TypeConstructorId
  , typeConstructorName :: !Text
  , typeConstructorExistentialParameters :: ![TypeParameter]
  , typeConstructorConstraints :: ![TypeId]
  , typeConstructorArguments :: ![TypeId]
  , typeConstructorFields :: ![TypeFieldDefinition range]
  , typeConstructorResultType :: !(Maybe TypeId)
  , typeConstructorRange :: !(Maybe range)
  }
  deriving stock (Eq, Show)

data TypeMethodDefinition range = TypeMethodDefinition
  { typeMethodDeclaration :: !DeclarationId
  , typeMethodName :: !Text
  , typeMethodType :: !(Maybe TypeId)
  , typeMethodSignatureText :: !(Maybe Text)
  , typeMethodRange :: !(Maybe range)
  }
  deriving stock (Eq, Show)

-- | A renderer-ready definition shape.  V1 deliberately uses
-- 'UnresolvedTypeDefinition' for GHC declarations whose constructors or right
-- hand side have not yet been projected; it never guesses an ADT shape from a
-- rendered signature.
data TypeDefinition range
  = AlgebraicTypeDefinition ![TypeConstructorDefinition range]
  | NewtypeDefinition !(TypeConstructorDefinition range)
  | TypeAliasDefinition !TypeId
  | TypeClassDefinition ![TypeId] ![TypeMethodDefinition range]
  | TypeFamilyDefinition
  | UnresolvedTypeDefinition !Text
  deriving stock (Eq, Show)

data TypeEntity range = TypeEntity
  { typeEntityId :: !TypeEntityId
  , typeEntityDeclaration :: !DeclarationId
  , typeEntityDocument :: !DocumentId
  , typeEntityName :: !Text
  , typeEntityOrigin :: !TypeOrigin
  , typeEntityEditability :: !TypeEditability
  , typeEntityTypeConstructor :: !(Maybe TypeId)
  , typeEntityParameters :: ![TypeParameter]
  , typeEntitySemanticType :: !(Maybe TypeId)
  , typeEntitySignatureText :: !(Maybe Text)
  , typeEntityDefinition :: !(TypeDefinition range)
  , typeEntityRange :: !range
  , typeEntitySelectionRange :: !range
  }
  deriving stock (Eq, Show)

-- | A declaration-to-type attachment.  This retains function signatures and
-- constructor types in the type universe without pretending that values are
-- themselves declared type entities.  The Functions inspector can consume the
-- same attachments later.
data TypeUsage range = TypeUsage
  { typeUsageDeclaration :: !DeclarationId
  , typeUsageDocument :: !DocumentId
  , typeUsageName :: !Text
  , typeUsageDeclarationKind :: !DeclarationKind
  , typeUsageOrigin :: !TypeOrigin
  , typeUsageType :: !(Maybe TypeId)
  , typeUsageSignatureText :: !(Maybe Text)
  , typeUsageRange :: !range
  }
  deriving stock (Eq, Show)

data TypeRelationKind
  = ReferencesType
  | AliasOfType
  | ConstrainsType
  | ExtendsType
  | RecursiveTypeReference
  deriving stock (Eq, Ord, Show)

data TypeRelation = TypeRelation
  { typeRelationSource :: !TypeEntityId
  , typeRelationTarget :: !TypeEntityId
  , typeRelationKind :: !TypeRelationKind
  , typeRelationVia :: !(Maybe TypeId)
  }
  deriving stock (Eq, Ord, Show)

-- | Revision and analysis provenance for each contributing document.  A rich
-- renderer can use this to indicate stale or partial regions instead of
-- presenting incomplete data as authoritative.
data TypeUniverseSource = TypeUniverseSource
  { typeUniverseSourceDocument :: !DocumentId
  , typeUniverseSourceGeneration :: !WorkspaceGeneration
  , typeUniverseSourceSession :: !SessionId
  , typeUniverseSourceRevision :: !TextRevision
  , typeUniverseSourceContentHash :: !ContentHash
  , typeUniverseSourceCompleteness :: !AnalysisCompleteness
  , typeUniverseSourceFreshness :: !AnalysisFreshness
  }
  deriving stock (Eq, Ord, Show)

data TypeUniverse range = TypeUniverse
  { typeUniverseScope :: !TypeUniverseScope
  , typeUniverseCoverage :: !TypeUniverseCoverage
  , typeUniverseSources :: ![TypeUniverseSource]
  , typeUniverseEntities :: !(Map TypeEntityId (TypeEntity range))
  , typeUniverseUsages :: ![TypeUsage range]
  , typeUniverseStructuredTypes :: !TypeTable
  , typeUniverseRelations :: ![TypeRelation]
  }
  deriving stock (Eq, Show)

-- | Build an immutable universe from snapshots which have already passed the
-- editor's generation/session/revision/hash acceptance checks.
buildTypeUniverse
  :: TypeUniverseScope
  -> [AnalysisSnapshot range]
  -> TypeUniverse range
buildTypeUniverse scope snapshots =
  let entities =
        Map.fromList (concatMap (entitiesForSnapshot focusedDocument) selectedSnapshots)
      structuredTypes = Map.unions (fmap (.analysisTypes) selectedSnapshots)
   in TypeUniverse
        { typeUniverseScope = scope
        , typeUniverseCoverage = coverageFor scope selectedSnapshots
        , typeUniverseSources = fmap sourceForSnapshot selectedSnapshots
        , typeUniverseEntities = entities
        , typeUniverseUsages =
            concatMap (usagesForSnapshot focusedDocument) selectedSnapshots
        , typeUniverseStructuredTypes = structuredTypes
        , typeUniverseRelations = relationsFor structuredTypes entities
        }
  where
    selectedSnapshots =
      sortOn (.analysisDocument) (filter (snapshotInScope scope) snapshots)
    focusedDocument = scopeFocus scope

coverageFor
  :: TypeUniverseScope
  -> [AnalysisSnapshot range]
  -> TypeUniverseCoverage
coverageFor scope snapshots =
  case (scope, snapshots) of
    (_, []) -> NoTypeCoverage
    (CurrentDocumentTypes document, _) -> ExactDocumentCoverage document
    (ProjectTypes _ _, available) ->
      AcceptedSnapshotsCoverage (fmap (.analysisDocument) available)

sourceForSnapshot :: AnalysisSnapshot range -> TypeUniverseSource
sourceForSnapshot snapshot =
  TypeUniverseSource
    { typeUniverseSourceDocument = snapshot.analysisDocument
    , typeUniverseSourceGeneration = snapshot.analysisWorkspaceGeneration
    , typeUniverseSourceSession = snapshot.analysisSession
    , typeUniverseSourceRevision = snapshot.analysisRevision
    , typeUniverseSourceContentHash = snapshot.analysisContentHash
    , typeUniverseSourceCompleteness = snapshot.analysisCompleteness
    , typeUniverseSourceFreshness = snapshot.analysisFreshness
    }

entitiesForSnapshot
  :: Maybe DocumentId
  -> AnalysisSnapshot range
  -> [(TypeEntityId, TypeEntity range)]
entitiesForSnapshot focused snapshot =
  mapMaybe
    (entityFor focused snapshot.analysisDocument)
    snapshot.analysisDeclarations

usagesForSnapshot
  :: Maybe DocumentId
  -> AnalysisSnapshot range
  -> [TypeUsage range]
usagesForSnapshot focused snapshot =
  fmap
    (usageFor focused snapshot.analysisDocument)
    snapshot.analysisDeclarations

snapshotInScope :: TypeUniverseScope -> AnalysisSnapshot range -> Bool
snapshotInScope scope snapshot =
  case scope of
    CurrentDocumentTypes document -> snapshot.analysisDocument == document
    ProjectTypes _ _ -> True

scopeFocus :: TypeUniverseScope -> Maybe DocumentId
scopeFocus scope =
  case scope of
    CurrentDocumentTypes document -> Just document
    ProjectTypes _ focused -> focused

originFor :: Maybe DocumentId -> DocumentId -> TypeOrigin
originFor focused document
  | focused == Just document = CurrentDocumentOrigin document
  | otherwise = WorkspaceDocumentOrigin document

entityFor
  :: Maybe DocumentId
  -> DocumentId
  -> Declaration range
  -> Maybe (TypeEntityId, TypeEntity range)
entityFor focused document declaration
  | declaration.declarationKind `elem` [TypeDeclaration, ClassDeclaration] =
      Just (identity, entity)
  | otherwise = Nothing
  where
    identity =
      case declaration.declarationTypeSemantics of
        Just semantics ->
          TypeEntityId ("type::" <> semantics.typeDeclarationSemanticConstructor.unTypeId)
        Nothing ->
          TypeEntityId
            ( document.unDocumentId
                <> "::"
                <> declaration.declarationId.unDeclarationId
            )
    entity =
      TypeEntity
        { typeEntityId = identity
        , typeEntityDeclaration = declaration.declarationId
        , typeEntityDocument = document
        , typeEntityName = declaration.declarationName
        , typeEntityOrigin = originFor focused document
        , typeEntityEditability = EditableSource
        , typeEntityTypeConstructor =
            (.typeDeclarationSemanticConstructor) <$> declaration.declarationTypeSemantics
        , typeEntityParameters =
            maybe
              []
              (fmap typeParameterFor . (.typeDeclarationSemanticParameters))
              declaration.declarationTypeSemantics
        , typeEntitySemanticType = declaration.declarationType
        , typeEntitySignatureText = declaration.declarationSignatureText
        , typeEntityDefinition =
            maybe
              (UnresolvedTypeDefinition "snapshot did not supply declared-type semantics")
              (typeDefinitionFor . (.typeDeclarationSemanticDefinition))
              declaration.declarationTypeSemantics
        , typeEntityRange = declaration.declarationRange
        , typeEntitySelectionRange = declaration.declarationSelectionRange
        }

typeParameterFor :: TypeParameterSemantics -> TypeParameter
typeParameterFor parameter =
  TypeParameter
    { typeParameterName = parameter.typeParameterSemanticName
    , typeParameterKind = parameter.typeParameterSemanticKind
    }

typeDefinitionFor
  :: TypeDeclarationDefinition range
  -> TypeDefinition range
typeDefinitionFor definition =
  case definition of
    AlgebraicTypeSemantics constructors ->
      AlgebraicTypeDefinition (fmap typeConstructorFor constructors)
    NewtypeSemantics constructor ->
      NewtypeDefinition (typeConstructorFor constructor)
    TypeAliasSemantics target -> TypeAliasDefinition target
    TypeClassSemantics constraints methods ->
      TypeClassDefinition constraints (fmap typeMethodFor methods)
    TypeFamilySemantics -> TypeFamilyDefinition
    AbstractTypeSemantics reason -> UnresolvedTypeDefinition reason

typeConstructorFor
  :: TypeConstructorSemantics range
  -> TypeConstructorDefinition range
typeConstructorFor constructor =
  TypeConstructorDefinition
    { typeConstructorId = TypeConstructorId constructor.typeConstructorSemanticId
    , typeConstructorName = constructor.typeConstructorSemanticName
    , typeConstructorExistentialParameters =
        fmap typeParameterFor constructor.typeConstructorSemanticExistentials
    , typeConstructorConstraints = constructor.typeConstructorSemanticConstraints
    , typeConstructorArguments = constructor.typeConstructorSemanticArguments
    , typeConstructorFields = fmap typeFieldFor constructor.typeConstructorSemanticFields
    , typeConstructorResultType = constructor.typeConstructorSemanticResult
    , typeConstructorRange = constructor.typeConstructorSemanticRange
    }

typeFieldFor :: TypeFieldSemantics range -> TypeFieldDefinition range
typeFieldFor field =
  TypeFieldDefinition
    { typeFieldId = TypeFieldId field.typeFieldSemanticId
    , typeFieldName = field.typeFieldSemanticName
    , typeFieldType = field.typeFieldSemanticType
    , typeFieldRange = field.typeFieldSemanticRange
    }

typeMethodFor :: TypeMethodSemantics range -> TypeMethodDefinition range
typeMethodFor method =
  TypeMethodDefinition
    { typeMethodDeclaration = method.typeMethodSemanticDeclaration
    , typeMethodName = method.typeMethodSemanticName
    , typeMethodType = method.typeMethodSemanticType
    , typeMethodSignatureText = method.typeMethodSemanticSignatureText
    , typeMethodRange = method.typeMethodSemanticRange
    }

usageFor
  :: Maybe DocumentId
  -> DocumentId
  -> Declaration range
  -> TypeUsage range
usageFor focused document declaration =
  TypeUsage
    { typeUsageDeclaration = declaration.declarationId
    , typeUsageDocument = document
    , typeUsageName = declaration.declarationName
    , typeUsageDeclarationKind = declaration.declarationKind
    , typeUsageOrigin = originFor focused document
    , typeUsageType = declaration.declarationType
    , typeUsageSignatureText = declaration.declarationSignatureText
    , typeUsageRange = declaration.declarationRange
    }

relationsFor
  :: TypeTable
  -> Map TypeEntityId (TypeEntity range)
  -> [TypeRelation]
relationsFor table entities =
  Set.toAscList (baseRelations <> recursiveRelations)
  where
    typeEntityIndex =
      Map.fromList
        [ (constructor, identity)
        | (identity, entity) <- Map.toList entities
        , Just constructor <- [entity.typeEntityTypeConstructor]
        ]
    baseRelations =
      Set.fromList
        [ TypeRelation source target kind (Just via)
        | (source, entity) <- Map.toList entities
        , (kind, via) <- relationTypeSeeds table entity
        , constructor <- Set.toList (referencedTypeConstructors table via)
        , Just target <- [Map.lookup constructor typeEntityIndex]
        ]
    recursivePairs = recursiveEntityPairs entities baseRelations
    recursiveRelations =
      Set.fromList
        [ TypeRelation source target RecursiveTypeReference relation.typeRelationVia
        | relation <- Set.toList baseRelations
        , let source = relation.typeRelationSource
        , let target = relation.typeRelationTarget
        , relation.typeRelationKind `elem` [ReferencesType, AliasOfType]
        , Set.member (source, target) recursivePairs
        ]

relationTypeSeeds :: TypeTable -> TypeEntity range -> [(TypeRelationKind, TypeId)]
relationTypeSeeds table entity =
  parameterSeeds <> definitionSeeds entity.typeEntityDefinition
  where
    parameterSeeds =
      [ (ReferencesType, kind)
      | parameter <- entity.typeEntityParameters
      , Just kind <- [parameter.typeParameterKind]
      ]
    definitionSeeds definition =
      case definition of
        AlgebraicTypeDefinition constructors -> concatMap constructorSeeds constructors
        NewtypeDefinition constructor -> constructorSeeds constructor
        TypeAliasDefinition target -> [(AliasOfType, target)]
        TypeClassDefinition superclasses methods ->
          fmap (\typeId -> (ExtendsType, typeId)) superclasses
            <> concatMap methodSeeds methods
        TypeFamilyDefinition -> []
        UnresolvedTypeDefinition _ -> []
    constructorSeeds
      :: TypeConstructorDefinition range
      -> [(TypeRelationKind, TypeId)]
    constructorSeeds constructor =
      fmap (\typeId -> (ConstrainsType, typeId)) constructor.typeConstructorConstraints
        <> fmap (\typeId -> (ReferencesType, typeId)) constructor.typeConstructorArguments
        <> fmap (\field -> (ReferencesType, field.typeFieldType)) constructor.typeConstructorFields
        <> [ (ReferencesType, kind)
           | parameter <- constructor.typeConstructorExistentialParameters
           , Just kind <- [parameter.typeParameterKind]
           ]
    methodSeeds
      :: TypeMethodDefinition range
      -> [(TypeRelationKind, TypeId)]
    methodSeeds method =
      case method.typeMethodType of
        Nothing -> []
        Just methodType ->
          let (constraints, references) = categorizedTypeReferences table methodType
           in fmap (\typeId -> (ConstrainsType, typeId)) (Set.toList constraints)
                <> fmap (\typeId -> (ReferencesType, typeId)) (Set.toList references)

-- | Separate constraint subtrees from ordinary references so the visual
-- contract can distinguish "uses this type" from "requires this class".
categorizedTypeReferences :: TypeTable -> TypeId -> (Set TypeId, Set TypeId)
categorizedTypeReferences table root = go Set.empty root
  where
    go visited identifier
      | Set.member identifier visited = (Set.empty, Set.empty)
      | otherwise =
          let nextVisited = Set.insert identifier visited
           in case Map.lookup identifier table of
                Just (ConstrainedType constraints body) ->
                  ( Set.unions (fmap (referencedTypeConstructors table) constraints)
                  , referencedTypeConstructors table body
                  )
                Just (TypeApplication function arguments) ->
                  merge (fmap (go nextVisited) (function : arguments))
                Just (FunctionType argument result) ->
                  merge [go nextVisited argument, go nextVisited result]
                Just (ForallType _ body) -> go nextVisited body
                Just (TupleType elements) -> merge (fmap (go nextVisited) elements)
                Just (ListType element) -> go nextVisited element
                Just (TypeConstructor _) -> (Set.empty, Set.singleton identifier)
                _ -> (Set.empty, Set.empty)
    merge pairs =
      (Set.unions (fmap fst pairs), Set.unions (fmap snd pairs))

referencedTypeConstructors :: TypeTable -> TypeId -> Set TypeId
referencedTypeConstructors table root = go Set.empty root
  where
    go visited identifier
      | Set.member identifier visited = Set.empty
      | otherwise =
          let nextVisited = Set.insert identifier visited
           in case Map.lookup identifier table of
                Just (TypeConstructor _) -> Set.singleton identifier
                Just (TypeApplication function arguments) ->
                  Set.unions (fmap (go nextVisited) (function : arguments))
                Just (FunctionType argument result) ->
                  go nextVisited argument <> go nextVisited result
                Just (ForallType _ body) -> go nextVisited body
                Just (ConstrainedType constraints body) ->
                  Set.unions (fmap (go nextVisited) (body : constraints))
                Just (TupleType elements) -> Set.unions (fmap (go nextVisited) elements)
                Just (ListType element) -> go nextVisited element
                _ -> Set.empty

recursiveEntityPairs
  :: Map TypeEntityId (TypeEntity range)
  -> Set TypeRelation
  -> Set (TypeEntityId, TypeEntityId)
recursiveEntityPairs entities relations =
  Set.fromList
    [ (source, target)
    | component <- stronglyConnComp graphNodes
    , members <- case component of
        AcyclicSCC _ -> []
        CyclicSCC identities -> [Set.fromList identities]
    , source <- Set.toList members
    , target <- Set.toList members
    , Set.member (source, target) graphEdges
    ]
  where
    graphEdges =
      Set.fromList
        [ (relation.typeRelationSource, relation.typeRelationTarget)
        | relation <- Set.toList relations
        , relation.typeRelationKind `elem` [ReferencesType, AliasOfType]
        ]
    graphNodes =
      [ ( identity
        , identity
        , [ target | (source, target) <- Set.toList graphEdges, source == identity ]
        )
      | identity <- Map.keys entities
      ]

-- | Deterministic, deliberately exhaustive textual presentation of the same
-- contract a rich renderer consumes.  It is intended for inspector debug mode,
-- tests, and semantic troubleshooting—not as an interchange format.
renderTypeUniverseDebug
  :: (range -> Text)
  -> TypeUniverse range
  -> Text
renderTypeUniverseDebug renderRange universe =
  Text.unlines
    ( [ "type-universe/v1"
      , "scope: " <> renderScope universe.typeUniverseScope
      , "coverage: " <> renderCoverage universe.typeUniverseCoverage
      , "sources: " <> count universe.typeUniverseSources
      ]
        <> concatMap renderSource universe.typeUniverseSources
        <> ["entities: " <> count (Map.elems universe.typeUniverseEntities)]
        <> concatMap (renderEntity renderRange) (Map.elems universe.typeUniverseEntities)
        <> ["type-usages: " <> count universe.typeUniverseUsages]
        <> concatMap (renderUsage renderRange) universe.typeUniverseUsages
        <> ["structured-types: " <> count (Map.elems universe.typeUniverseStructuredTypes)]
        <> concatMap renderStructured (Map.toAscList universe.typeUniverseStructuredTypes)
        <> ["relations: " <> count universe.typeUniverseRelations]
        <> concatMap renderRelation universe.typeUniverseRelations
    )

renderScope :: TypeUniverseScope -> Text
renderScope scope =
  case scope of
    CurrentDocumentTypes document ->
      "current-document " <> document.unDocumentId
    ProjectTypes workspace focused ->
      "project "
        <> workspace.unWorkspaceId
        <> " (focused: "
        <> maybe "none" (.unDocumentId) focused
        <> ")"

renderCoverage :: TypeUniverseCoverage -> Text
renderCoverage coverage =
  case coverage of
    NoTypeCoverage -> "none"
    ExactDocumentCoverage document -> "exact-document " <> document.unDocumentId
    AcceptedSnapshotsCoverage documents ->
      "accepted-snapshots "
        <> "["
        <> Text.intercalate ", " (fmap (.unDocumentId) documents)
        <> "]"
    IndexedProjectCoverage workspace -> "indexed-project " <> workspace.unWorkspaceId

renderSource :: TypeUniverseSource -> [Text]
renderSource source =
  [ "  - document: " <> source.typeUniverseSourceDocument.unDocumentId
  , "    generation: " <> shown source.typeUniverseSourceGeneration.unWorkspaceGeneration
  , "    session: " <> source.typeUniverseSourceSession.unSessionId
  , "    revision: " <> shown source.typeUniverseSourceRevision.unTextRevision
  , "    content-hash: " <> shown source.typeUniverseSourceContentHash.unContentHash
  , "    completeness: " <> completenessText source.typeUniverseSourceCompleteness
  , "    freshness: " <> freshnessText source.typeUniverseSourceFreshness
  ]

renderEntity :: (range -> Text) -> TypeEntity range -> [Text]
renderEntity renderRange entity =
  [ "  - id: " <> entity.typeEntityId.unTypeEntityId
  , "    declaration: " <> entity.typeEntityDeclaration.unDeclarationId
  , "    name: " <> entity.typeEntityName
  , "    document: " <> entity.typeEntityDocument.unDocumentId
  , "    origin: " <> originText entity.typeEntityOrigin
  , "    editability: " <> editabilityText entity.typeEntityEditability
  , "    type-constructor: " <> maybe "none" (.unTypeId) entity.typeEntityTypeConstructor
  , "    parameters: " <> renderParameters entity.typeEntityParameters
  , "    semantic-type: " <> maybe "none" (.unTypeId) entity.typeEntitySemanticType
  , "    signature: " <> maybe "none" oneLine entity.typeEntitySignatureText
  , "    definition: " <> definitionText entity.typeEntityDefinition
  , "    range: " <> renderRange entity.typeEntityRange
  , "    selection-range: " <> renderRange entity.typeEntitySelectionRange
  ] <> renderDefinition renderRange entity.typeEntityDefinition

renderUsage :: (range -> Text) -> TypeUsage range -> [Text]
renderUsage renderRange usage =
  [ "  - declaration: " <> usage.typeUsageDeclaration.unDeclarationId
  , "    name: " <> usage.typeUsageName
  , "    kind: " <> declarationKindText usage.typeUsageDeclarationKind
  , "    document: " <> usage.typeUsageDocument.unDocumentId
  , "    origin: " <> originText usage.typeUsageOrigin
  , "    semantic-type: " <> maybe "none" (.unTypeId) usage.typeUsageType
  , "    signature: " <> maybe "none" oneLine usage.typeUsageSignatureText
  , "    range: " <> renderRange usage.typeUsageRange
  ]

renderStructured :: (TypeId, StructuredType) -> [Text]
renderStructured (identifier, structured) =
  [ "  - " <> identifier.unTypeId <> " = " <> structuredTypeText structured
  ]

renderRelation :: TypeRelation -> [Text]
renderRelation relation =
  [ "  - "
      <> relation.typeRelationSource.unTypeEntityId
      <> " --"
      <> relationKindText relation.typeRelationKind
      <> "--> "
      <> relation.typeRelationTarget.unTypeEntityId
      <> maybe "" ((" via " <>) . (.unTypeId)) relation.typeRelationVia
  ]

renderParameters :: [TypeParameter] -> Text
renderParameters [] = "[]"
renderParameters parameters =
  "["
    <> Text.intercalate
      ", "
      [ parameter.typeParameterName
          <> maybe "" ((" :: " <>) . (.unTypeId)) parameter.typeParameterKind
      | parameter <- parameters
      ]
    <> "]"

definitionText :: TypeDefinition range -> Text
definitionText definition =
  case definition of
    AlgebraicTypeDefinition constructors ->
      "algebraic (" <> count constructors <> " constructors)"
    NewtypeDefinition constructor ->
      "newtype " <> constructor.typeConstructorName
    TypeAliasDefinition target ->
      "alias " <> target.unTypeId
    TypeClassDefinition constraints methods ->
      "class ("
        <> count constraints
        <> " constraints, "
        <> count methods
        <> " methods)"
    TypeFamilyDefinition -> "type-family"
    UnresolvedTypeDefinition reason -> "unresolved: " <> oneLine reason

renderDefinition :: (range -> Text) -> TypeDefinition range -> [Text]
renderDefinition renderRange definition =
  case definition of
    AlgebraicTypeDefinition constructors ->
      ["    constructors: " <> count constructors]
        <> concatMap (renderConstructor renderRange) constructors
    NewtypeDefinition constructor ->
      ["    constructors: 1"] <> renderConstructor renderRange constructor
    TypeAliasDefinition target ->
      ["    alias-target: " <> target.unTypeId]
    TypeClassDefinition constraints methods ->
      [ "    superclass-constraints: " <> typeIdList constraints
      , "    methods: " <> count methods
      ] <> concatMap (renderMethod renderRange) methods
    TypeFamilyDefinition -> ["    family-equations: unavailable"]
    UnresolvedTypeDefinition reason ->
      ["    unresolved-reason: " <> oneLine reason]

renderConstructor
  :: (range -> Text)
  -> TypeConstructorDefinition range
  -> [Text]
renderConstructor renderRange constructor =
  [ "      - constructor-id: " <> constructor.typeConstructorId.unTypeConstructorId
  , "        name: " <> constructor.typeConstructorName
  , "        existentials: " <> renderParameters constructor.typeConstructorExistentialParameters
  , "        constraints: " <> typeIdList constructor.typeConstructorConstraints
  , "        arguments: " <> typeIdList constructor.typeConstructorArguments
  , "        result: " <> maybe "none" (.unTypeId) constructor.typeConstructorResultType
  , "        range: " <> maybe "none" renderRange constructor.typeConstructorRange
  , "        fields: " <> count constructor.typeConstructorFields
  ] <> concatMap (renderField renderRange) constructor.typeConstructorFields

renderField :: (range -> Text) -> TypeFieldDefinition range -> [Text]
renderField renderRange field =
  [ "          - field-id: " <> field.typeFieldId.unTypeFieldId
  , "            name: " <> field.typeFieldName
  , "            type: " <> field.typeFieldType.unTypeId
  , "            range: " <> maybe "none" renderRange field.typeFieldRange
  ]

renderMethod :: (range -> Text) -> TypeMethodDefinition range -> [Text]
renderMethod renderRange method =
  [ "      - declaration: " <> method.typeMethodDeclaration.unDeclarationId
  , "        name: " <> method.typeMethodName
  , "        semantic-type: " <> maybe "none" (.unTypeId) method.typeMethodType
  , "        signature: " <> maybe "none" oneLine method.typeMethodSignatureText
  , "        range: " <> maybe "none" renderRange method.typeMethodRange
  ]

structuredTypeText :: StructuredType -> Text
structuredTypeText structured =
  case structured of
    TypeVariable name -> "variable " <> name
    TypeConstructor name -> "constructor " <> name
    TypeApplication function arguments ->
      "application " <> function.unTypeId <> " " <> typeIdList arguments
    FunctionType argument result ->
      "function " <> argument.unTypeId <> " -> " <> result.unTypeId
    ForallType variables body ->
      "forall " <> Text.unwords variables <> ". " <> body.unTypeId
    ConstrainedType constraints body ->
      "constrained " <> typeIdList constraints <> " => " <> body.unTypeId
    TupleType elements -> "tuple " <> typeIdList elements
    ListType element -> "list " <> element.unTypeId
    LiteralType value -> "literal " <> oneLine value
    UnsupportedType description -> "unsupported " <> oneLine description

typeIdList :: [TypeId] -> Text
typeIdList identifiers =
  "[" <> Text.intercalate ", " (fmap (.unTypeId) identifiers) <> "]"

originText :: TypeOrigin -> Text
originText origin =
  case origin of
    CurrentDocumentOrigin document -> "current-document " <> document.unDocumentId
    WorkspaceDocumentOrigin document -> "workspace-document " <> document.unDocumentId
    PackageOrigin package version moduleName ->
      "package "
        <> package
        <> maybe "" ("-" <>) version
        <> ":"
        <> moduleName.unModuleName
    BuiltinOrigin moduleName -> "builtin " <> moduleName.unModuleName
    UnknownOrigin reason -> "unknown " <> oneLine reason

editabilityText :: TypeEditability -> Text
editabilityText editability =
  case editability of
    EditableSource -> "editable-source"
    GeneratedSource -> "generated-source"
    ReadOnlyDependency -> "read-only-dependency"

relationKindText :: TypeRelationKind -> Text
relationKindText relationKind =
  case relationKind of
    ReferencesType -> "references"
    AliasOfType -> "alias-of"
    ConstrainsType -> "constrains"
    ExtendsType -> "extends"
    RecursiveTypeReference -> "recursive-reference"

declarationKindText :: DeclarationKind -> Text
declarationKindText kind =
  case kind of
    ValueDeclaration -> "value"
    TypeDeclaration -> "type"
    DataConstructorDeclaration -> "data-constructor"
    ClassDeclaration -> "class"
    InstanceDeclaration -> "instance"
    ModuleDeclaration -> "module"
    UnsupportedDeclaration description -> "unsupported (" <> oneLine description <> ")"

completenessText :: AnalysisCompleteness -> Text
completenessText completeness =
  case completeness of
    ParseOnly -> "parse-only"
    Renamed -> "renamed"
    Typechecked -> "typechecked"
    Indexed -> "indexed"
    PartiallyFailed -> "partially-failed"

freshnessText :: AnalysisFreshness -> Text
freshnessText freshness =
  case freshness of
    CurrentAnalysis -> "current"
    StaleAnalysis -> "stale"

count :: [value] -> Text
count = shown . length

shown :: Show value => value -> Text
shown = Text.pack . show

oneLine :: Text -> Text
oneLine = Text.unwords . Text.lines
