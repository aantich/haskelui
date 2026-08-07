{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module VisualHaskell.TypeDiagram.Projection
  ( projectTypeDiagram
  , renderStructuredType
  , sourceLocationForPart
  ) where

import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text
import VisualHaskell.Semantic
import VisualHaskell.TypeDiagram.Scene

projectTypeDiagram :: TypeUniverse range -> TypeDiagramState -> TypeDiagram
projectTypeDiagram universe state =
  TypeDiagram
    { typeDiagramNodes = localNodes <> externalNodes
    , typeDiagramEdges = edges
    , typeDiagramEmptyMessage =
        if Map.null localNodes
          then Just "No type declarations are available for this scope yet."
          else Nothing
    }
  where
    table = universe.typeUniverseStructuredTypes
    entities = Map.elems universe.typeUniverseEntities
    aliasTargets =
      Map.fromList
        [ (target, (entity.typeEntityId, EntityNode entity.typeEntityId, entity.typeEntityName))
        | entity <- entities
        , TypeAliasDefinition target <- [entity.typeEntityDefinition]
        ]
    localNodes =
      Map.fromList
        [ (node.diagramNodeId, node)
        | node <- fmap (nodeForEntity table aliasTargets state) entities
        ]
    localTargetsByName =
      Map.fromList
        [ (constructorIdentity table typeId, EntityNode entity.typeEntityId)
        | entity <- entities
        , typeId <- maybeToList entity.typeEntityTypeConstructor
        ]
    localAliasTargets = fmap (\(_, target, _) -> target) aliasTargets
    seeds = concatMap (referenceSeeds table aliasTargets) entities
    edges =
      deduplicateEdges
        (zipWith (edgeFor localTargetsByName localAliasTargets universe) [(1 :: Int) ..] seeds)
    externalIds =
      Set.fromList
        [ target
        | edge <- edges
        , let target = edge.diagramEdgeTarget
        , Map.notMember target localNodes
        ]
    externalNodes =
      Map.fromList
        [ (nodeId, externalNode table nodeId)
        | nodeId <- Set.toAscList externalIds
        ]

maybeToList :: Maybe value -> [value]
maybeToList Nothing = []
maybeToList (Just value) = [value]

nodeForEntity
  :: TypeTable
  -> Map TypeId (TypeEntityId, DiagramNodeId, Text)
  -> TypeDiagramState
  -> TypeEntity range
  -> DiagramNode
nodeForEntity table aliasTargets state entity =
  DiagramNode
    { diagramNodeId = EntityNode entity.typeEntityId
    , diagramNodeEntity = Just entity.typeEntityId
    , diagramNodeTitle = entity.typeEntityName
    , diagramNodeSubtitle = parametersSubtitle table entity
    , diagramNodeKind = definitionKind entity.typeEntityDefinition
    , diagramNodeOrigin = originKind entity.typeEntityOrigin
    , diagramNodeEditability = entity.typeEntityEditability
    , diagramNodeRows = rowsForDefinition table aliasTargets entity
    , diagramNodeFunctionEndpoints = []
    , diagramNodeCollapsed = Set.member entity.typeEntityId state.typeDiagramCollapsedNodes
    }

definitionKind :: TypeDefinition range -> DiagramNodeKind
definitionKind = \case
  AlgebraicTypeDefinition _ -> AlgebraicNode
  NewtypeDefinition _ -> NewtypeNode
  TypeAliasDefinition _ -> AliasNode
  TypeClassDefinition _ _ -> ClassNode
  TypeFamilyDefinition -> FamilyNode
  UnresolvedTypeDefinition _ -> UnresolvedNode

originKind :: TypeOrigin -> DiagramNodeOrigin
originKind = \case
  CurrentDocumentOrigin _ -> CurrentDocumentNode
  WorkspaceDocumentOrigin _ -> WorkspaceNode
  PackageOrigin _ _ _ -> PackageNode
  BuiltinOrigin _ -> BuiltinNode
  UnknownOrigin _ -> UnknownNode

parametersSubtitle :: TypeTable -> TypeEntity range -> Maybe Text
parametersSubtitle table entity
  | null entity.typeEntityParameters = entity.typeEntitySignatureText
  | otherwise =
      Just
        ( Text.unwords
            [ parameter.typeParameterName <> kindSuffix parameter.typeParameterKind
            | parameter <- entity.typeEntityParameters
            ]
        )
  where
    kindSuffix = maybe "" (\typeId -> " :: " <> renderStructuredType table typeId)

rowsForDefinition
  :: forall range.
     TypeTable
  -> Map TypeId (TypeEntityId, DiagramNodeId, Text)
  -> TypeEntity range
  -> [DiagramRow]
rowsForDefinition table aliasTargets entity =
  case entity.typeEntityDefinition of
    AlgebraicTypeDefinition constructors -> concatMap constructorRows constructors
    NewtypeDefinition constructor -> constructorRows constructor
    TypeAliasDefinition target ->
      [ DiagramRow
          (AliasAnchor entity.typeEntityId)
          AliasRow
          "="
          (Just (renderStructuredType table target))
          0
      ]
    TypeClassDefinition constraints methods ->
      [ DiagramRow
          (NodeAnchor (EntityNode entity.typeEntityId))
          ConstraintRow
          "requires"
          (Just (Text.intercalate ", " (fmap (renderStructuredType table) constraints)))
          0
      | not (null constraints)
      ]
        <> [ DiagramRow
              (MethodAnchor entity.typeEntityId method.typeMethodDeclaration)
              MethodRow
              method.typeMethodName
              (method.typeMethodSignatureText `orElse` (renderStructuredType table <$> method.typeMethodType))
              0
           | method <- methods
           ]
    TypeFamilyDefinition -> [messageRow "open type family"]
    UnresolvedTypeDefinition reason -> [messageRow reason]
  where
    renderReference typeId =
      case Map.lookup typeId aliasTargets of
        Just (aliasEntity, _, aliasName)
          | aliasEntity /= entity.typeEntityId -> aliasName
        _ -> renderStructuredType table typeId
    messageRow message =
      DiagramRow
        (NodeAnchor (EntityNode entity.typeEntityId))
        MessageRow
        message
        Nothing
        0
    constructorRows :: TypeConstructorDefinition range -> [DiagramRow]
    constructorRows constructor =
      let fields = constructor.typeConstructorFields
          constructorSignature
            | not (null fields) = Nothing
            | otherwise =
                nonEmpty
                  ( Text.unwords
                      (fmap renderReference constructor.typeConstructorArguments)
                  )
       in DiagramRow
            (ConstructorAnchor entity.typeEntityId constructor.typeConstructorId)
            ConstructorRow
            constructor.typeConstructorName
            constructorSignature
            0
            : [ DiagramRow
                  (FieldAnchor entity.typeEntityId field.typeFieldId)
                  FieldRow
                  field.typeFieldName
                  (Just (renderReference field.typeFieldType))
                  1
              | field <- fields
              ]

nonEmpty :: Text -> Maybe Text
nonEmpty text
  | Text.null (Text.strip text) = Nothing
  | otherwise = Just text

orElse :: Maybe value -> Maybe value -> Maybe value
orElse (Just value) _ = Just value
orElse Nothing fallback = fallback

-- A seed retains the smallest semantic source row. That makes both edge ports
-- and source navigation precise instead of attributing every reference to the
-- containing declaration card.
data ReferenceSeed = ReferenceSeed
  { seedEntity :: !TypeEntityId
  , seedAnchor :: !DiagramAnchor
  , seedTargetType :: !TypeId
  , seedKind :: !TypeRelationKind
  }

referenceSeeds
  :: forall range.
     TypeTable
  -> Map TypeId (TypeEntityId, DiagramNodeId, Text)
  -> TypeEntity range
  -> [ReferenceSeed]
referenceSeeds table aliasTargets entity =
  case entity.typeEntityDefinition of
    AlgebraicTypeDefinition constructors -> concatMap constructorSeeds constructors
    NewtypeDefinition constructor -> constructorSeeds constructor
    TypeAliasDefinition target -> seeds (AliasAnchor entity.typeEntityId) AliasOfType target
    TypeClassDefinition constraints methods ->
      concatMap (seeds (NodeAnchor nodeId) ExtendsType) constraints
        <> concatMap methodSeeds methods
    TypeFamilyDefinition -> []
    UnresolvedTypeDefinition _ -> []
  where
    nodeId = EntityNode entity.typeEntityId
    seeds anchor kind typeId =
      case Map.lookup typeId aliasTargets of
        Just (aliasEntity, _, _)
          | aliasEntity /= entity.typeEntityId ->
              [ReferenceSeed entity.typeEntityId anchor typeId kind]
        _ | Just (FunctionType _ _) <- Map.lookup typeId table ->
              [ReferenceSeed entity.typeEntityId anchor typeId kind]
        _ ->
          [ ReferenceSeed entity.typeEntityId anchor target kind
          | target <- Set.toAscList (referencedConstructors table typeId)
          ]
    constructorSeeds :: TypeConstructorDefinition range -> [ReferenceSeed]
    constructorSeeds constructor =
      let constructorAnchor = ConstructorAnchor entity.typeEntityId constructor.typeConstructorId
       in concatMap (seeds constructorAnchor ConstrainsType) constructor.typeConstructorConstraints
            <> if null constructor.typeConstructorFields
              then concatMap (seeds constructorAnchor ReferencesType) constructor.typeConstructorArguments
              else concatMap fieldSeeds constructor.typeConstructorFields
            -- A constructor result identifies the declaration being built; it
            -- is not a stored/reference dependency. Treating `C :: ... -> T`
            -- as a use of T draws a false self-loop around every ordinary ADT.
    fieldSeeds :: TypeFieldDefinition range -> [ReferenceSeed]
    fieldSeeds field =
      seeds
        (FieldAnchor entity.typeEntityId field.typeFieldId)
        ReferencesType
        field.typeFieldType
    methodSeeds :: TypeMethodDefinition range -> [ReferenceSeed]
    methodSeeds method =
      foldMap
        (seeds (MethodAnchor entity.typeEntityId method.typeMethodDeclaration) ReferencesType)
        method.typeMethodType

edgeFor
  :: Map Text DiagramNodeId
  -> Map TypeId DiagramNodeId
  -> TypeUniverse range
  -> Int
  -> ReferenceSeed
  -> DiagramEdge
edgeFor localTargetsByName localAliasTargets universe ordinal seed =
  DiagramEdge
    { diagramEdgeId = DiagramEdgeId (edgeIdentity ordinal seed target)
    , diagramEdgeSource = seed.seedAnchor
    , diagramEdgeTarget = target
    , diagramEdgeKind = if recursive then RecursiveTypeReference else seed.seedKind
    , diagramEdgeVia = Just seed.seedTargetType
    , diagramEdgeRecursive = recursive
    }
  where
    table = universe.typeUniverseStructuredTypes
    target =
      case Map.lookup seed.seedTargetType localAliasTargets of
        Just aliasTarget -> aliasTarget
        Nothing ->
          Map.findWithDefault
            (ReferenceNode seed.seedTargetType)
            (constructorIdentity table seed.seedTargetType)
            localTargetsByName
    recursive =
      target == EntityNode seed.seedEntity
        || any
          (\relation ->
            relation.typeRelationSource == seed.seedEntity
              && EntityNode relation.typeRelationTarget == target
              && relation.typeRelationKind == RecursiveTypeReference
          )
          universe.typeUniverseRelations

edgeIdentity :: Int -> ReferenceSeed -> DiagramNodeId -> Text
edgeIdentity ordinal seed target =
  Text.pack (show seed.seedAnchor)
    <> "->"
    <> Text.pack (show target)
    <> ":"
    <> Text.pack (show seed.seedKind)
    <> ":"
    <> Text.pack (show ordinal)

deduplicateEdges :: [DiagramEdge] -> [DiagramEdge]
deduplicateEdges =
  Map.elems
    . foldl'
      (\acc edge -> Map.insertWith keepFirst (edgeKey edge) edge acc)
      (Map.empty :: Map (DiagramAnchor, DiagramNodeId, TypeRelationKind, Maybe TypeId) DiagramEdge)
  where
    edgeKey :: DiagramEdge -> (DiagramAnchor, DiagramNodeId, TypeRelationKind, Maybe TypeId)
    edgeKey edge =
      ( edge.diagramEdgeSource
      , edge.diagramEdgeTarget
      , edge.diagramEdgeKind
      , edge.diagramEdgeVia
      )
    keepFirst :: DiagramEdge -> DiagramEdge -> DiagramEdge
    keepFirst _ existing = existing

externalNode :: TypeTable -> DiagramNodeId -> DiagramNode
externalNode table nodeId =
  case nodeId of
    ReferenceNode referencedType
      | Just (FunctionType _ _) <- Map.lookup referencedType table ->
          baseNode
            { diagramNodeTitle = "Function type"
            , diagramNodeSubtitle = Nothing
            , diagramNodeKind = FunctionNodeKind
            , diagramNodeFunctionEndpoints = functionEndpoints table referencedType
            }
    _ -> baseNode
  where
    typeId = case nodeId of
      ReferenceNode referenced -> Just referenced
      EntityNode _ -> Nothing
    title = case nodeId of
      ReferenceNode referencedType -> renderStructuredType table referencedType
      EntityNode entityId -> unTypeEntityId entityId
    originDetail =
      case maybe [] (Set.toAscList . referencedModules table) typeId of
        [] -> "origin unavailable"
        modules -> Text.intercalate ", " modules
    baseNode =
      DiagramNode
        { diagramNodeId = nodeId
        , diagramNodeEntity = Nothing
        , diagramNodeTitle = title
        , diagramNodeSubtitle = Just originDetail
        , diagramNodeKind = ReferenceNodeKind
        , diagramNodeOrigin = ExternalReferenceNode
        , diagramNodeEditability = ReadOnlyDependency
        , diagramNodeRows = []
        , diagramNodeFunctionEndpoints = []
        , diagramNodeCollapsed = True
        }

functionEndpoints :: TypeTable -> TypeId -> [DiagramFunctionEndpoint]
functionEndpoints table = fmap endpoint . flatten
  where
    flatten typeId =
      case Map.lookup typeId table of
        Just (FunctionType argument result) -> argument : flatten result
        _ -> [typeId]
    endpoint typeId =
      DiagramFunctionEndpoint
        { diagramFunctionEndpointType = typeId
        , diagramFunctionEndpointLabel = renderStructuredType table typeId
        , diagramFunctionEndpointDetail =
            case Set.toAscList (referencedModules table typeId) of
              [] -> Nothing
              modules -> Just (Text.intercalate ", " modules)
        }

referencedModules :: TypeTable -> TypeId -> Set Text
referencedModules table = go Set.empty
  where
    go visited typeId
      | Set.member typeId visited = Set.empty
      | otherwise =
          let nextVisited = Set.insert typeId visited
              recurse = go nextVisited
           in case Map.lookup typeId table of
                Just (TypeConstructor name) -> Set.fromList (maybeToList (constructorModule name))
                Just (TypeApplication function arguments) -> recurse function <> foldMap recurse arguments
                Just (FunctionType input output) -> recurse input <> recurse output
                Just (ForallType _ body) -> recurse body
                Just (ConstrainedType constraints body) -> foldMap recurse constraints <> recurse body
                Just (TupleType members) -> foldMap recurse members
                Just (ListType item) -> recurse item
                _ -> Set.empty

constructorModule :: Text -> Maybe Text
constructorModule name =
  case Text.splitOn "." name of
    [_] -> Nothing
    parts -> nonEmpty (Text.intercalate "." (init parts))

shortConstructorName :: Text -> Text
shortConstructorName name =
  case reverse (Text.splitOn "." name) of
    occurrence : _ -> occurrence
    [] -> name

constructorIdentity :: TypeTable -> TypeId -> Text
constructorIdentity table typeId =
  case Map.lookup typeId table of
    Just (TypeConstructor name) -> name
    Just (TypeApplication function _) -> constructorIdentity table function
    _ -> unTypeId typeId

referencedConstructors :: TypeTable -> TypeId -> Set TypeId
referencedConstructors table = go Set.empty
  where
    go visited typeId
      | Set.member typeId visited = Set.empty
      | otherwise =
          let nextVisited = Set.insert typeId visited
           in case Map.lookup typeId table of
                Just (TypeConstructor _) -> Set.singleton typeId
                Just (TypeApplication function arguments) ->
                  go nextVisited function <> foldMap (go nextVisited) arguments
                Just (FunctionType input output) -> go nextVisited input <> go nextVisited output
                Just (ForallType _ body) -> go nextVisited body
                Just (ConstrainedType constraints body) ->
                  foldMap (go nextVisited) constraints <> go nextVisited body
                Just (TupleType members) -> foldMap (go nextVisited) members
                Just (ListType item) -> go nextVisited item
                _ -> Set.empty

renderStructuredType :: TypeTable -> TypeId -> Text
renderStructuredType table = go Set.empty
  where
    go visited typeId
      | Set.member typeId visited = "…"
      | otherwise =
          let nextVisited = Set.insert typeId visited
              render = go nextVisited
           in case Map.lookup typeId table of
                Nothing -> unTypeId typeId
                Just (TypeVariable name) -> name
                Just (TypeConstructor name) -> shortConstructorName name
                Just (TypeApplication function arguments) ->
                  Text.unwords (parenthesizeApplication (render function) : fmap (parenthesize . render) arguments)
                Just (FunctionType input output) -> parenthesizeArrow input <> " -> " <> render output
                Just (ForallType names body) -> "forall " <> Text.unwords names <> ". " <> render body
                Just (ConstrainedType constraints body) ->
                  parenthesizeConstraints (fmap render constraints) <> " => " <> render body
                Just (TupleType members) -> "(" <> Text.intercalate ", " (fmap render members) <> ")"
                Just (ListType item) -> "[" <> render item <> "]"
                Just (LiteralType literal) -> literal
                Just (UnsupportedType text) -> text
      where
        parenthesizeArrow nested =
          case Map.lookup nested table of
            Just (FunctionType _ _) -> parenthesize (go visited nested)
            _ -> go visited nested
    parenthesizeApplication text = text
    parenthesize text
      | Text.any (== ' ') text = "(" <> text <> ")"
      | otherwise = text
    parenthesizeConstraints [constraint] = constraint
    parenthesizeConstraints constraints = "(" <> Text.intercalate ", " constraints <> ")"

sourceLocationForPart
  :: TypeUniverse range
  -> DiagramPart
  -> Maybe (DocumentId, range)
sourceLocationForPart universe part =
  case part of
    AnchorPart anchor -> sourceForAnchor anchor
    DisclosurePart entityId -> sourceForEntity entityId
    EdgePart _ -> Nothing
    FamilyPart _ -> Nothing
    FunctionEndpointPart _ _ -> Nothing
    FunctionOverflowPart _ -> Nothing
  where
    entities = universe.typeUniverseEntities
    sourceForEntity entityId = do
      entity <- Map.lookup entityId entities
      pure (entity.typeEntityDocument, entity.typeEntitySelectionRange)
    sourceForAnchor anchor =
      case anchor of
        NodeAnchor (EntityNode entityId) -> sourceForEntity entityId
        NodeAnchor (ReferenceNode _) -> Nothing
        AliasAnchor entityId -> sourceForEntity entityId
        ConstructorAnchor entityId constructorId -> do
          entity <- Map.lookup entityId entities
          range <- findConstructorRange constructorId entity.typeEntityDefinition
          pure (entity.typeEntityDocument, range)
        FieldAnchor entityId fieldId -> do
          entity <- Map.lookup entityId entities
          range <- findFieldRange fieldId entity.typeEntityDefinition
          pure (entity.typeEntityDocument, range)
        MethodAnchor entityId methodDeclarationId -> do
          entity <- Map.lookup entityId entities
          range <- findMethodRange methodDeclarationId entity.typeEntityDefinition
          pure (entity.typeEntityDocument, range)

findConstructorRange :: TypeConstructorId -> TypeDefinition range -> Maybe range
findConstructorRange wanted = \case
  AlgebraicTypeDefinition constructors ->
    firstJust
      [ constructor.typeConstructorRange
      | constructor <- constructors
      , constructor.typeConstructorId == wanted
      ]
  NewtypeDefinition constructor
    | constructor.typeConstructorId == wanted -> constructor.typeConstructorRange
  _ -> Nothing

findFieldRange :: TypeFieldId -> TypeDefinition range -> Maybe range
findFieldRange wanted definition =
  firstJust
    [ field.typeFieldRange
    | constructor <- constructors
    , field <- constructor.typeConstructorFields
    , field.typeFieldId == wanted
    ]
  where
    constructors = case definition of
      AlgebraicTypeDefinition values -> values
      NewtypeDefinition value -> [value]
      _ -> []

findMethodRange :: DeclarationId -> TypeDefinition range -> Maybe range
findMethodRange wanted = \case
  TypeClassDefinition _ methods ->
    firstJust
      [ method.typeMethodRange
      | method <- methods
      , method.typeMethodDeclaration == wanted
      ]
  _ -> Nothing

firstJust :: [Maybe value] -> Maybe value
firstJust = \case
  [] -> Nothing
  Just value : _ -> Just value
  Nothing : rest -> firstJust rest
