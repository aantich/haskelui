{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

module VisualHaskell.Semantic.FunctionUniverse
  ( FunctionNode (..)
  , buildFunctionUniverse
  , renderFunctionUniverseDebug
  ) where

import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.List (sortOn)
import Data.Text (Text)
import qualified Data.Text as Text
import VisualHaskell.Semantic.Types

-- | One application port and its result preserve Haskell's currying. A result
-- may itself be a function; a wire never silently saturates extra arguments.
data FunctionNode range = FunctionNode
  { functionIdentity :: !DeclarationId
  , functionName :: !Text
  , functionRange :: !range
  , functionSignature :: !Text
  , functionInput :: !Text
  , functionOutput :: !Text
  }
  deriving stock (Eq, Show)

buildFunctionUniverse :: AnalysisSnapshot range -> [FunctionNode range]
buildFunctionUniverse snapshot = sortOn (.functionName)
  [ FunctionNode declaration.declarationId declaration.declarationName
      declaration.declarationSelectionRange (maybe "" id declaration.declarationSignatureText)
      (render Set.empty input) (render Set.empty output)
  | declaration <- snapshot.analysisDeclarations
  , declaration.declarationKind == ValueDeclaration
  , Just identifier <- [declaration.declarationType]
  , Just (input, output) <- [ports Set.empty identifier]
  ]
  where
    table = snapshot.analysisTypes
    ports seen identifier
      | Set.member identifier seen = Nothing
      | otherwise = case Map.lookup identifier table of
          Just (ForallType _ body) -> ports (Set.insert identifier seen) body
          Just (ConstrainedType _ body) -> ports (Set.insert identifier seen) body
          Just (FunctionType input output) -> Just (input, output)
          _ -> Nothing
    render seen identifier
      | Set.member identifier seen = "…"
      | otherwise =
          let child = render (Set.insert identifier seen)
           in case Map.lookup identifier table of
             Just (TypeVariable name) -> name
             Just (TypeConstructor name) -> name
             Just (TypeApplication constructor arguments) -> child constructor <> " " <> Text.unwords (fmap (\argument -> "(" <> child argument <> ")") arguments)
             Just (FunctionType input output) -> "(" <> child input <> " -> " <> child output <> ")"
             Just (ForallType variables body) -> "forall " <> Text.unwords variables <> ". " <> child body
             Just (ConstrainedType constraints body) -> Text.intercalate ", " (fmap child constraints) <> " => " <> child body
             Just (TupleType elements) -> "(" <> Text.intercalate ", " (fmap child elements) <> ")"
             Just (ListType element) -> "[" <> child element <> "]"
             Just (LiteralType value) -> value
             Just (UnsupportedType value) -> value
             Nothing -> "?"

renderFunctionUniverseDebug :: [FunctionNode range] -> Text
renderFunctionUniverseDebug nodes = "function-universe/v1\n" <> Text.unlines
  [ node.functionIdentity.unDeclarationId <> "\n  " <> node.functionName <> " :: " <> node.functionSignature
      <> "\n  input: " <> node.functionInput <> "\n  output: " <> node.functionOutput
  | node <- nodes
  ]
