{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Control.Monad (unless)
import Data.List (tails)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Text (Text)
import HaskeLUI.Core
import VisualHaskell.Semantic
import VisualHaskell.TypeDiagram

main :: IO ()
main = do
  projectionTests
  layoutTests
  renderingTests
  interactionTests
  navigationTests
  putStrLn "visual-haskell-type-diagram tests passed"

projectionTests :: IO ()
projectionTests = do
  let diagram = projectTypeDiagram fixtureUniverse initialTypeDiagramState
      nodes = diagram.typeDiagramNodes
      tree = nodes Map.! EntityNode treeId
  assertEqual "projects all local entities plus external references" 9 (Map.size nodes)
  assertEqual "preserves ADT node kind" AlgebraicNode tree.diagramNodeKind
  assertTrue "projects constructor and field rows" (length tree.diagramNodeRows == 4)
  assertTrue
    "marks self-recursive references"
    (any (\edge -> edge.diagramEdgeRecursive && edge.diagramEdgeTarget == EntityNode treeId) diagram.typeDiagramEdges)
  assertTrue
    "does not mistake an ordinary constructor result for recursion"
    ( not
        ( any
            (\edge ->
              edge.diagramEdgeRecursive
                && case edge.diagramEdgeSource of
                  ConstructorAnchor entityId _ -> entityId == identifierId
                  _ -> False
            )
            diagram.typeDiagramEdges
        )
    )
  assertTrue
    "groups mutual recursion semantically"
    (any (\edge -> edge.diagramEdgeRecursive && edge.diagramEdgeTarget == EntityNode alphaId) diagram.typeDiagramEdges)
  assertTrue
    "compacts an exact structural field type to its local source alias"
    ( any
        (\row -> row.diagramRowPrimary == "value" && row.diagramRowSecondary == Just "Names")
        tree.diagramNodeRows
        && any
          (\edge ->
            edge.diagramEdgeSource == FieldAnchor treeId (TypeFieldId "Main.Tree.value")
              && edge.diagramEdgeTarget == EntityNode namesId
          )
          diagram.typeDiagramEdges
    )
  assertTrue
    "creates compact external type stubs"
    (any ((== ReferenceNodeKind) . (.diagramNodeKind)) (Map.elems nodes))
  let functionNodes = filter ((== FunctionNodeKind) . (.diagramNodeKind)) (Map.elems nodes)
  assertEqual "function references remain one structured visual node" 1 (length functionNodes)
  assertEqual
    "function nodes preserve the curried endpoint chain"
    [["a", "a", "Bool"]]
    (fmap (fmap (.diagramFunctionEndpointLabel) . (.diagramNodeFunctionEndpoints)) functionNodes)
  assertTrue
    "function internals are not flattened into independent uses edges"
    (not (Map.member (ReferenceNode boolType) nodes))
  assertTrue
    "external references expose their defining module when available"
    ( any
        (\node -> node.diagramNodeTitle == "Int" && node.diagramNodeSubtitle == Just "GHC.Types")
        (Map.elems nodes)
    )
  assertEqual
    "renders structured function types"
    "a -> a -> Bool"
    (renderStructuredType fixtureTable equalsType)

layoutTests :: IO ()
layoutTests = do
  let diagram = projectTypeDiagram fixtureUniverse initialTypeDiagramState
      layout = layoutTypeDiagram defaultDiagramMetrics viewport diagram initialTypeDiagramState
      rects = fmap (.laidOutNodeRect) (Map.elems layout.laidOutNodes)
      collapsedState =
        initialTypeDiagramState
          { typeDiagramCollapsedNodes = Set.singleton treeId
          , typeDiagramPinnedNodes = Map.singleton (EntityNode treeId) (Point 777 88)
          }
      collapsedLayout = layoutTypeDiagram defaultDiagramMetrics viewport (projectTypeDiagram fixtureUniverse collapsedState) collapsedState
      collapsedTree = collapsedLayout.laidOutNodes Map.! EntityNode treeId
      functionLayouts =
        [ nodeLayout
        | nodeLayout <- Map.elems layout.laidOutNodes
        , nodeLayout.laidOutNode.diagramNodeKind == FunctionNodeKind
        ]
  assertTrue "automatic node layout has no overlaps" (all (uncurry nonOverlapping) (pairs rects))
  assertTrue "recursive SCCs receive family hulls" (not (null layout.laidOutFamilies))
  assertTrue
    "recursive family labels own a band above every member card"
    ( and
        [ family.laidOutFamilyRect.rectY + defaultDiagramMetrics.diagramFamilyPadding
            <= minimum
              [ nodeLayout.laidOutNodeRect.rectY
              | nodeId <- Set.toList family.laidOutFamilyNodes
              , nodeLayout <- maybeToList (Map.lookup nodeId layout.laidOutNodes)
              ]
        | family <- layout.laidOutFamilies
        ]
    )
  assertTrue "all edges receive routed paths" (length layout.laidOutEdges == length diagram.typeDiagramEdges)
  assertTrue
    "every row remains inside its card"
    ( and
        [ contains nodeLayout.laidOutNodeRect rowRect
        | nodeLayout <- Map.elems layout.laidOutNodes
        , rowRect <- Map.elems nodeLayout.laidOutRowRects
        ]
    )
  assertEqual "pinned card position overrides automatic layout" (Point 777 88) (Point collapsedTree.laidOutNodeRect.rectX collapsedTree.laidOutNodeRect.rectY)
  assertEqual "collapsed cards retain only their header height" defaultDiagramMetrics.diagramHeaderHeight collapsedTree.laidOutNodeRect.rectHeight
  assertTrue
    "ordinary cards size to content within configured bounds"
    ( treeLayoutWidth layout >= defaultDiagramMetrics.diagramNodeMinimumWidth
        && treeLayoutWidth layout < defaultDiagramMetrics.diagramNodeWidth
    )
  assertTrue
    "function endpoints receive dedicated inline card layout"
    (case functionLayouts of [functionLayout] -> length functionLayout.laidOutFunctionItems == 3; _ -> False)

renderingTests :: IO ()
renderingTests = do
  let diagram = projectTypeDiagram fixtureUniverse initialTypeDiagramState
      light = renderTypeDiagram defaultDiagramMetrics (diagramTheme LightColorScheme) viewport diagram initialTypeDiagramState
      dark = renderTypeDiagram defaultDiagramMetrics (diagramTheme DarkColorScheme) viewport diagram initialTypeDiagramState
      treeLayout = light.diagramPresentationLayout.laidOutNodes Map.! EntityNode treeId
      worldCenter = rectCenter treeLayout.laidOutHeaderRect
      screenCenter = applyViewport initialTypeDiagramState worldCenter
      hit = hitTestDrawing screenCenter light.diagramPresentationHitTest
      longFunctionNodeId = ReferenceNode (TypeId "function:long")
      longFunctionNode =
        DiagramNode
          { diagramNodeId = longFunctionNodeId
          , diagramNodeEntity = Nothing
          , diagramNodeTitle = "Function type"
          , diagramNodeSubtitle = Nothing
          , diagramNodeKind = FunctionNodeKind
          , diagramNodeOrigin = ExternalReferenceNode
          , diagramNodeEditability = ReadOnlyDependency
          , diagramNodeRows = []
          , diagramNodeFunctionEndpoints =
              [ DiagramFunctionEndpoint (TypeId ("endpoint:" <> label)) label Nothing
              | label <- ["A", "B", "C", "D", "E", "F"]
              ]
          , diagramNodeCollapsed = True
          }
      longDiagram = TypeDiagram (Map.singleton longFunctionNodeId longFunctionNode) [] Nothing
      longState =
        initialTypeDiagramState
          { typeDiagramHovered = Just (FunctionOverflowPart longFunctionNodeId)
          }
      longPresentation =
        renderTypeDiagram defaultDiagramMetrics (diagramTheme LightColorScheme) viewport longDiagram longState
  assertEqual "drawing validates" [] (validateDrawing light.diagramPresentationDrawing)
  assertEqual "hit tree validates" [] (validateDrawingHitTest light.diagramPresentationHitTest)
  assertTrue "system themes produce different drawings" (light.diagramPresentationDrawing /= dark.diagramPresentationDrawing)
  assertEqual
    "card hit resolves semantic node"
    (Just (AnchorPart (NodeAnchor (EntityNode treeId))))
    (hit >>= diagramPartForHit light)
  assertEqual
    "render revision is deterministic"
    light.diagramPresentationRevision
    (renderTypeDiagram defaultDiagramMetrics (diagramTheme LightColorScheme) viewport diagram initialTypeDiagramState).diagramPresentationRevision
  assertTrue
    "long function chains use an interactive ellipsis"
    ( any
        (\case FunctionEllipsisLayout _ -> True; _ -> False)
        ((longPresentation.diagramPresentationLayout.laidOutNodes Map.! longFunctionNodeId).laidOutFunctionItems)
    )
  assertTrue
    "hovering function overflow draws the complete signature popover"
    ("A → B → C → D → E → F" `elem` drawingTexts longPresentation.diagramPresentationDrawing)

interactionTests :: IO ()
interactionTests = do
  let diagram = projectTypeDiagram fixtureUniverse initialTypeDiagramState
      presentation = renderTypeDiagram defaultDiagramMetrics (diagramTheme LightColorScheme) viewport diagram initialTypeDiagramState
      functionNodeId = ReferenceNode equalsType
      disclosureKey = presentation.diagramPresentationRegions Map.! (DisclosurePart treeId)
      disclosureHit = DrawingHitResult disclosureKey PointingHandCursor
      collapse =
        handleTypeDiagramInput
          defaultDiagramMetrics
          presentation
          (DrawingPointerInput (pointer DrawingPointerDown (Just disclosureHit) 1 (Point 0 0)))
          initialTypeDiagramState
      collapsed = collapse.updatedTypeDiagramState
      nodeKey = presentation.diagramPresentationRegions Map.! (AnchorPart (NodeAnchor (EntityNode treeId)))
      nodeHit = DrawingHitResult nodeKey OpenHandCursor
      activate =
        handleTypeDiagramInput
          defaultDiagramMetrics
          presentation
          (DrawingPointerInput (pointer DrawingPointerDown (Just nodeHit) 2 (Point 0 0)))
          initialTypeDiagramState
      dragStart =
        handleTypeDiagramInput
          defaultDiagramMetrics
          presentation
          (DrawingPointerInput (pointer DrawingPointerDown (Just nodeHit) 1 (Point 0 0)))
          initialTypeDiagramState
      dragged =
        handleTypeDiagramInput
          defaultDiagramMetrics
          presentation
          ( DrawingPointerInput
              ((pointer DrawingPointerMoved (Just nodeHit) 1 (Point 18 9)) {drawingPointerDelta = Point 18 9})
          )
          dragStart.updatedTypeDiagramState
      functionEndpointKey =
        presentation.diagramPresentationRegions Map.! FunctionEndpointPart functionNodeId 0
      functionEndpointHit = DrawingHitResult functionEndpointKey OpenHandCursor
      functionDragStart =
        handleTypeDiagramInput
          defaultDiagramMetrics
          presentation
          (DrawingPointerInput (pointer DrawingPointerDown (Just functionEndpointHit) 1 (Point 0 0)))
          initialTypeDiagramState
      functionDragged =
        handleTypeDiagramInput
          defaultDiagramMetrics
          presentation
          ( DrawingPointerInput
              ((pointer DrawingPointerMoved (Just functionEndpointHit) 1 (Point 16 7)) {drawingPointerDelta = Point 16 7})
          )
          functionDragStart.updatedTypeDiagramState
      functionDragRecovered =
        handleTypeDiagramInput
          defaultDiagramMetrics
          presentation
          ( DrawingPointerInput
              ( ((pointer DrawingPointerMoved (Just functionEndpointHit) 1 (Point 16 7)) {drawingPointerDelta = Point 16 7})
                  { drawingPointerButtons =
                      noDrawingPointerButtons {primaryPointerButtonPressed = True}
                  }
              )
          )
          initialTypeDiagramState
      panStart =
        handleTypeDiagramInput
          defaultDiagramMetrics
          presentation
          (DrawingPointerInput (pointer DrawingPointerDown Nothing 1 (Point 0 0)))
          initialTypeDiagramState
      panned =
        handleTypeDiagramInput
          defaultDiagramMetrics
          presentation
          (DrawingPointerInput ((pointer DrawingPointerMoved Nothing 1 (Point 12 8)) {drawingPointerDelta = Point 12 8}))
          panStart.updatedTypeDiagramState
      zoomed =
        handleTypeDiagramInput
          defaultDiagramMetrics
          presentation
          ( DrawingScrollInput
              DrawingScrollEvent
                { drawingScrollPosition = Point 120 100
                , drawingScrollDelta = Point 0 (-20)
                , drawingScrollIsPrecise = True
                , drawingScrollModifiers = noDrawingModifiers {drawingMetaPressed = True}
                , drawingScrollTarget = Nothing
                }
          )
          initialTypeDiagramState
  assertTrue "disclosure toggles collapsed state" (Set.member treeId collapsed.typeDiagramCollapsedNodes)
  assertEqual "double-click activates semantic part" (Just (AnchorPart (NodeAnchor (EntityNode treeId)))) activate.activatedDiagramPart
  assertTrue "single-click selects and card drag pins the node" (Map.member (EntityNode treeId) dragged.updatedTypeDiagramState.typeDiagramPinnedNodes)
  assertTrue
    "dragging any function endpoint moves the owning composite function node"
    (Map.member functionNodeId functionDragged.updatedTypeDiagramState.typeDiagramPinnedNodes)
  assertTrue
    "a pressed function drag survives a declarative re-render between down and move"
    (Map.member functionNodeId functionDragRecovered.updatedTypeDiagramState.typeDiagramPinnedNodes)
  assertEqual "blank drag pans canvas" (Point 32 28) panned.updatedTypeDiagramState.typeDiagramViewport.diagramViewportOffset
  assertTrue "modified scroll zooms" (zoomed.updatedTypeDiagramState.typeDiagramViewport.diagramViewportScale > 0.78)

navigationTests :: IO ()
navigationTests = do
  assertEqual
    "constructor source anchor remains navigable"
    (Just (documentId, 11))
    (sourceLocationForPart fixtureUniverse (AnchorPart (ConstructorAnchor treeId treeNodeConstructorId)))
  assertEqual
    "an unindexed external reference is intentionally not source-navigable"
    Nothing
    (sourceLocationForPart fixtureUniverse (AnchorPart (NodeAnchor (ReferenceNode intType))))

pointer :: DrawingPointerPhase -> Maybe DrawingHitResult -> Int -> Point -> DrawingPointerEvent
pointer phase target clicks position =
  DrawingPointerEvent
    { drawingPointerId = DrawingPointerId 1
    , drawingPointerPhase = phase
    , drawingPointerPosition = position
    , drawingPointerDelta = Point 0 0
    , drawingPointerChangedButton = Just PrimaryPointerButton
    , drawingPointerButtons = noDrawingPointerButtons
    , drawingPointerModifiers = noDrawingModifiers
    , drawingPointerClickCount = clicks
    , drawingPointerTarget = target
    }

applyViewport :: TypeDiagramState -> Point -> Point
applyViewport state =
  applyAffine
    ( composeAffine
        (translation offset.pointX offset.pointY)
        (scaling scale scale)
    )
  where
    viewportState = state.typeDiagramViewport
    offset = viewportState.diagramViewportOffset
    scale = viewportState.diagramViewportScale

pairs :: [value] -> [(value, value)]
pairs values = [(left, right) | left : rest <- tails values, right <- rest]

nonOverlapping :: Rect -> Rect -> Bool
nonOverlapping left right =
  rectRight left <= right.rectX
    || rectRight right <= left.rectX
    || rectBottom left <= right.rectY
    || rectBottom right <= left.rectY

contains :: Rect -> Rect -> Bool
contains outer inner =
  inner.rectX >= outer.rectX
    && inner.rectY >= outer.rectY
    && rectRight inner <= rectRight outer
    && rectBottom inner <= rectBottom outer

drawingTexts :: Drawing -> [Text]
drawingTexts drawing =
  case drawing of
    Empty -> []
    Group children -> concatMap drawingTexts children
    Transform _ child -> drawingTexts child
    Clip _ _ child -> drawingTexts child
    Opacity _ child -> drawingTexts child
    Fill {} -> []
    Stroke {} -> []
    DrawText textDraw -> [textDraw.drawnText]

treeLayoutWidth :: LaidOutTypeDiagram -> Double
treeLayoutWidth layout =
  (layout.laidOutNodes Map.! EntityNode treeId).laidOutNodeRect.rectWidth

assertTrue :: String -> Bool -> IO ()
assertTrue label result = unless result (error (label <> ": assertion failed"))

assertEqual :: (Eq value, Show value) => String -> value -> value -> IO ()
assertEqual label expected actual =
  unless (expected == actual) (error (label <> ": expected " <> show expected <> ", got " <> show actual))

maybeToList :: Maybe value -> [value]
maybeToList Nothing = []
maybeToList (Just value) = [value]

viewport :: Rect
viewport = Rect 0 0 1200 900

documentId :: DocumentId
documentId = DocumentId "/project/Main.hs"

workspaceId :: WorkspaceId
workspaceId = WorkspaceId "/project"

treeId, identifierId, namesId, equalityId, alphaId, betaId :: TypeEntityId
treeId = TypeEntityId "Main.Tree"
identifierId = TypeEntityId "Main.Identifier"
namesId = TypeEntityId "Main.Names"
equalityId = TypeEntityId "Main.Equality"
alphaId = TypeEntityId "Main.Alpha"
betaId = TypeEntityId "Main.Beta"

treeNodeConstructorId :: TypeConstructorId
treeNodeConstructorId = TypeConstructorId "Main.Tree.Node"

treeType, identifierType, namesType, equalityType, alphaType, betaType, intType, textType, boolType, parameterType, treeOfA, listTree, listText, equalsType, arrowTail :: TypeId
treeType = TypeId "tycon:Tree"
identifierType = TypeId "tycon:Identifier"
namesType = TypeId "tycon:Names"
equalityType = TypeId "tycon:Equality"
alphaType = TypeId "tycon:Alpha"
betaType = TypeId "tycon:Beta"
intType = TypeId "tycon:Int"
textType = TypeId "tycon:Text"
boolType = TypeId "tycon:Bool"
parameterType = TypeId "var:a"
treeOfA = TypeId "app:Tree:a"
listTree = TypeId "list:Tree"
listText = TypeId "list:Text"
equalsType = TypeId "fun:equals"
arrowTail = TypeId "fun:equals:tail"

fixtureTable :: TypeTable
fixtureTable =
  Map.fromList
    [ (treeType, TypeConstructor "Tree")
    , (identifierType, TypeConstructor "Identifier")
    , (namesType, TypeConstructor "Names")
    , (equalityType, TypeConstructor "Equality")
    , (alphaType, TypeConstructor "Alpha")
    , (betaType, TypeConstructor "Beta")
    , (intType, TypeConstructor "GHC.Types.Int")
    , (textType, TypeConstructor "Data.Text.Text")
    , (boolType, TypeConstructor "GHC.Types.Bool")
    , (parameterType, TypeVariable "a")
    , (treeOfA, TypeApplication treeType [parameterType])
    , (listTree, ListType treeOfA)
    , (listText, ListType textType)
    , (equalsType, FunctionType parameterType arrowTail)
    , (arrowTail, FunctionType parameterType boolType)
    ]

fixtureUniverse :: TypeUniverse Int
fixtureUniverse =
  TypeUniverse
    { typeUniverseScope = ProjectTypes workspaceId (Just documentId)
    , typeUniverseCoverage = ExactDocumentCoverage documentId
    , typeUniverseSources = []
    , typeUniverseEntities =
        Map.fromList
          [ (treeId, treeEntity)
          , (identifierId, identifierEntity)
          , (namesId, namesEntity)
          , (equalityId, equalityEntity)
          , (alphaId, alphaEntity)
          , (betaId, betaEntity)
          ]
    , typeUniverseUsages = []
    , typeUniverseStructuredTypes = fixtureTable
    , typeUniverseRelations =
        [ TypeRelation treeId treeId RecursiveTypeReference (Just treeOfA)
        , TypeRelation alphaId betaId RecursiveTypeReference (Just betaType)
        , TypeRelation betaId alphaId RecursiveTypeReference (Just alphaType)
        ]
    }

baseEntity :: TypeEntityId -> Text -> TypeId -> TypeDefinition Int -> Int -> TypeEntity Int
baseEntity entityId name constructor definition range =
  TypeEntity
    { typeEntityId = entityId
    , typeEntityDeclaration = DeclarationId ("decl:" <> name)
    , typeEntityDocument = documentId
    , typeEntityName = name
    , typeEntityOrigin = CurrentDocumentOrigin documentId
    , typeEntityEditability = EditableSource
    , typeEntityTypeConstructor = Just constructor
    , typeEntityParameters = []
    , typeEntitySemanticType = Nothing
    , typeEntitySignatureText = Nothing
    , typeEntityDefinition = definition
    , typeEntityRange = range
    , typeEntitySelectionRange = range
    }

treeEntity :: TypeEntity Int
treeEntity =
  (baseEntity treeId "Tree" treeType (AlgebraicTypeDefinition [leaf, branch]) 10)
    { typeEntityParameters = [TypeParameter "a" Nothing]
    }
  where
    leaf = TypeConstructorDefinition (TypeConstructorId "Main.Tree.Leaf") "Leaf" [] [] [parameterType] [] Nothing (Just 10)
    branch =
      TypeConstructorDefinition
        treeNodeConstructorId
        "Node"
        []
        []
        []
        [ TypeFieldDefinition (TypeFieldId "Main.Tree.value") "value" listText (Just 12)
        , TypeFieldDefinition (TypeFieldId "Main.Tree.children") "children" listTree (Just 13)
        ]
        Nothing
        (Just 11)

identifierEntity :: TypeEntity Int
identifierEntity =
  baseEntity
    identifierId
    "Identifier"
    identifierType
    (NewtypeDefinition (TypeConstructorDefinition (TypeConstructorId "Main.Identifier") "Identifier" [] [] [intType] [] (Just identifierType) (Just 20)))
    20

namesEntity :: TypeEntity Int
namesEntity = baseEntity namesId "Names" namesType (TypeAliasDefinition listText) 30

equalityEntity :: TypeEntity Int
equalityEntity =
  baseEntity
    equalityId
    "Equality"
    equalityType
    (TypeClassDefinition [] [TypeMethodDefinition (DeclarationId "decl:equals") "equals" (Just equalsType) (Just "a -> a -> Bool") (Just 41)])
    40

alphaEntity, betaEntity :: TypeEntity Int
alphaEntity =
  baseEntity alphaId "Alpha" alphaType (AlgebraicTypeDefinition [TypeConstructorDefinition (TypeConstructorId "Alpha") "Alpha" [] [] [betaType] [] Nothing (Just 50)]) 50
betaEntity =
  baseEntity betaId "Beta" betaType (AlgebraicTypeDefinition [TypeConstructorDefinition (TypeConstructorId "Beta") "Beta" [] [] [alphaType] [] Nothing (Just 60)]) 60
