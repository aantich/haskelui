{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedRecordDot #-}

module VisualHaskell.TypeDiagram.Scene
  ( DiagramAnchor (..)
  , DiagramEdge (..)
  , DiagramEdgeId (..)
  , DiagramFunctionEndpoint (..)
  , DiagramNode (..)
  , DiagramNodeId (..)
  , DiagramNodeKind (..)
  , DiagramNodeOrigin (..)
  , DiagramPart (..)
  , DiagramRow (..)
  , DiagramRowKind (..)
  , DiagramViewport (..)
  , DragState (..)
  , TypeDiagram (..)
  , TypeDiagramState (..)
  , initialTypeDiagramState
  , nextDiagramRevision
  ) where

import Data.Map.Strict (Map)
import Data.Set (Set)
import Data.Text (Text)
import Data.Word (Word64)
import HaskeLUI.Core (Point (..))
import VisualHaskell.Semantic

data DiagramNodeId
  = EntityNode !TypeEntityId
  | ReferenceNode !TypeId
  deriving stock (Eq, Ord, Show)

data DiagramAnchor
  = NodeAnchor !DiagramNodeId
  | ConstructorAnchor !TypeEntityId !TypeConstructorId
  | FieldAnchor !TypeEntityId !TypeFieldId
  | MethodAnchor !TypeEntityId !DeclarationId
  | AliasAnchor !TypeEntityId
  deriving stock (Eq, Ord, Show)

newtype DiagramEdgeId = DiagramEdgeId {unDiagramEdgeId :: Text}
  deriving stock (Eq, Ord, Show)

data DiagramPart
  = AnchorPart !DiagramAnchor
  | DisclosurePart !TypeEntityId
  | EdgePart !DiagramEdgeId
  | FamilyPart !Text
  | FunctionEndpointPart !DiagramNodeId !Int
  | FunctionOverflowPart !DiagramNodeId
  deriving stock (Eq, Ord, Show)

data DiagramNodeKind
  = AlgebraicNode
  | NewtypeNode
  | AliasNode
  | ClassNode
  | FamilyNode
  | UnresolvedNode
  | ReferenceNodeKind
  | FunctionNodeKind
  deriving stock (Eq, Ord, Show)

data DiagramNodeOrigin
  = CurrentDocumentNode
  | WorkspaceNode
  | PackageNode
  | BuiltinNode
  | UnknownNode
  | ExternalReferenceNode
  deriving stock (Eq, Ord, Show)

data DiagramRowKind
  = ConstructorRow
  | FieldRow
  | MethodRow
  | AliasRow
  | ConstraintRow
  | MessageRow
  deriving stock (Eq, Ord, Show)

data DiagramRow = DiagramRow
  { diagramRowAnchor :: !DiagramAnchor
  , diagramRowKind :: !DiagramRowKind
  , diagramRowPrimary :: !Text
  , diagramRowSecondary :: !(Maybe Text)
  , diagramRowDepth :: !Int
  }
  deriving stock (Eq, Show)

data DiagramFunctionEndpoint = DiagramFunctionEndpoint
  { diagramFunctionEndpointType :: !TypeId
  , diagramFunctionEndpointLabel :: !Text
  , diagramFunctionEndpointDetail :: !(Maybe Text)
  }
  deriving stock (Eq, Show)

data DiagramNode = DiagramNode
  { diagramNodeId :: !DiagramNodeId
  , diagramNodeEntity :: !(Maybe TypeEntityId)
  , diagramNodeTitle :: !Text
  , diagramNodeSubtitle :: !(Maybe Text)
  , diagramNodeKind :: !DiagramNodeKind
  , diagramNodeOrigin :: !DiagramNodeOrigin
  , diagramNodeEditability :: !TypeEditability
  , diagramNodeRows :: ![DiagramRow]
  , diagramNodeFunctionEndpoints :: ![DiagramFunctionEndpoint]
  , diagramNodeCollapsed :: !Bool
  }
  deriving stock (Eq, Show)

data DiagramEdge = DiagramEdge
  { diagramEdgeId :: !DiagramEdgeId
  , diagramEdgeSource :: !DiagramAnchor
  , diagramEdgeTarget :: !DiagramNodeId
  , diagramEdgeKind :: !TypeRelationKind
  , diagramEdgeVia :: !(Maybe TypeId)
  , diagramEdgeRecursive :: !Bool
  }
  deriving stock (Eq, Show)

data TypeDiagram = TypeDiagram
  { typeDiagramNodes :: !(Map DiagramNodeId DiagramNode)
  , typeDiagramEdges :: ![DiagramEdge]
  , typeDiagramEmptyMessage :: !(Maybe Text)
  }
  deriving stock (Eq, Show)

data DiagramViewport = DiagramViewport
  { diagramViewportOffset :: !Point
  , diagramViewportScale :: !Double
  }
  deriving stock (Eq, Show)

data DragState
  = PanningDiagram
  | DraggingNode !DiagramNodeId
  deriving stock (Eq, Show)

data TypeDiagramState = TypeDiagramState
  { typeDiagramSelected :: !(Maybe DiagramPart)
  , typeDiagramHovered :: !(Maybe DiagramPart)
  , typeDiagramCollapsedNodes :: !(Set TypeEntityId)
  , typeDiagramPinnedNodes :: !(Map DiagramNodeId Point)
  , typeDiagramViewport :: !DiagramViewport
  , typeDiagramDrag :: !(Maybe DragState)
  , typeDiagramRevision :: !Word64
  }
  deriving stock (Eq, Show)

initialTypeDiagramState :: TypeDiagramState
initialTypeDiagramState =
  TypeDiagramState
    { typeDiagramSelected = Nothing
    , typeDiagramHovered = Nothing
    , typeDiagramCollapsedNodes = mempty
    , typeDiagramPinnedNodes = mempty
    , typeDiagramViewport = DiagramViewport (Point 20 20) 0.78
    , typeDiagramDrag = Nothing
    , typeDiagramRevision = 0
    }

nextDiagramRevision :: TypeDiagramState -> TypeDiagramState
nextDiagramRevision state =
  state {typeDiagramRevision = state.typeDiagramRevision + 1}
