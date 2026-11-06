{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Native editor queries. Offsets are Unicode scalars in the exact snapshot
-- identified by the envelope; results never authorize edits to another revision.
module VisualHaskell.Analysis.Protocol.Queries where

import Data.Aeson
import Data.Text (Text)
import VisualHaskell.Semantic

data QueryKind = HoverQuery | DefinitionQuery | CompletionQuery
  deriving stock (Eq, Ord, Show)

data PositionQuery = PositionQuery
  { queryKind :: !QueryKind
  , queryOffset :: !Int
  }
  deriving stock (Eq, Show)

data HoverInfo = HoverInfo
  { hoverName :: !Text
  , hoverSignature :: !Text
  , hoverModule :: !(Maybe Text)
  , hoverStart :: !Int
  , hoverLength :: !Int
  }
  deriving stock (Eq, Show)

data DefinitionTarget = DefinitionTarget
  { definitionPath :: !FilePath
  , definitionRange :: !RevisionedSourceRange
  , definitionContentHash :: !ContentHash
  }
  deriving stock (Eq, Show)

data CompletionCandidate = CompletionCandidate
  { completionLabel :: !Text
  , completionSignature :: !Text
  }
  deriving stock (Eq, Ord, Show)

data PositionResult = PositionResult
  { resultQuery :: !PositionQuery
  , resultHover :: !(Maybe HoverInfo)
  , resultDefinitions :: ![DefinitionTarget]
  , resultCompletions :: ![CompletionCandidate]
  , resultReplacementStart :: !Int
  , resultReplacementLength :: !Int
  }
  deriving stock (Eq, Show)

newtype CompositionQuery = CompositionQuery {compositionFunctions :: [DeclarationId]}
  deriving stock (Eq, Show)

data CompositionResult = CompositionResult
  { compositionQuery :: !CompositionQuery
  , compositionValid :: !Bool
  , compositionSignature :: !(Maybe Text)
  , compositionError :: !(Maybe Text)
  }
  deriving stock (Eq, Show)

instance ToJSON CompositionQuery where
  toJSON q = object ["functions" .= q.compositionFunctions]
instance FromJSON CompositionQuery where
  parseJSON = withObject "composition query" $ \v -> CompositionQuery <$> v .: "functions"
instance ToJSON CompositionResult where
  toJSON r = object ["query" .= r.compositionQuery, "valid" .= r.compositionValid, "signature" .= r.compositionSignature, "error" .= r.compositionError]
instance FromJSON CompositionResult where
  parseJSON = withObject "composition result" $ \v -> CompositionResult <$> v .: "query" <*> v .: "valid" <*> v .:? "signature" <*> v .:? "error"

instance ToJSON QueryKind where
  toJSON HoverQuery = String "hover"
  toJSON DefinitionQuery = String "definition"
  toJSON CompletionQuery = String "completion"
instance FromJSON QueryKind where
  parseJSON = withText "query kind" $ \kind -> case kind of
    "hover" -> pure HoverQuery
    "definition" -> pure DefinitionQuery
    "completion" -> pure CompletionQuery
    _ -> fail "unknown position query"
instance ToJSON PositionQuery where
  toJSON q = object ["kind" .= q.queryKind, "offset" .= q.queryOffset]
instance FromJSON PositionQuery where
  parseJSON = withObject "position query" $ \v -> PositionQuery <$> v .: "kind" <*> v .: "offset"
instance ToJSON HoverInfo where
  toJSON h = object ["name" .= h.hoverName, "signature" .= h.hoverSignature, "module" .= h.hoverModule, "start" .= h.hoverStart, "length" .= h.hoverLength]
instance FromJSON HoverInfo where
  parseJSON = withObject "hover" $ \v -> HoverInfo <$> v .: "name" <*> v .: "signature" <*> v .:? "module" <*> v .: "start" <*> v .: "length"
instance ToJSON DefinitionTarget where
  toJSON d = object ["path" .= d.definitionPath, "range" .= d.definitionRange, "hash" .= d.definitionContentHash]
instance FromJSON DefinitionTarget where
  parseJSON = withObject "definition" $ \v -> DefinitionTarget <$> v .: "path" <*> v .: "range" <*> v .: "hash"
instance ToJSON CompletionCandidate where
  toJSON c = object ["label" .= c.completionLabel, "signature" .= c.completionSignature]
instance FromJSON CompletionCandidate where
  parseJSON = withObject "completion" $ \v -> CompletionCandidate <$> v .: "label" <*> v .: "signature"
instance ToJSON PositionResult where
  toJSON r = object ["query" .= r.resultQuery, "hover" .= r.resultHover, "definitions" .= r.resultDefinitions, "completions" .= r.resultCompletions, "start" .= r.resultReplacementStart, "length" .= r.resultReplacementLength]
instance FromJSON PositionResult where
  parseJSON = withObject "position result" $ \v -> PositionResult <$> v .: "query" <*> v .:? "hover" <*> v .: "definitions" <*> v .: "completions" <*> v .: "start" <*> v .: "length"
