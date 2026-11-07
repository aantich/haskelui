{-# LANGUAGE OverloadedRecordDot #-}
-- | Compiler sessions use canonical paths; editor buffers retain the paths
-- through which they were opened. Restore that identity at the process edge.
module VisualHaskell.Projects.SourcePaths (restoreSourcePaths) where

import Data.List (find)
import qualified Data.Map.Strict as Map
import System.FilePath (normalise)
import VisualHaskell.Analysis.Protocol
import VisualHaskell.Semantic

restoreSourcePaths
  :: Map.Map DocumentId DocumentSnapshot -> Map.Map DocumentId FilePath
  -> WorkerMessage -> WorkerMessage
restoreSourcePaths documents originals message = case message of
  PositionQueryCompleted result -> PositionQueryCompleted result
    {resultDefinitions = [target {definitionPath = originalPath target.definitionPath} | target <- result.resultDefinitions]}
  SymbolsFound result -> SymbolsFound result
    {symbolSearchSymbols = map restoreSymbol result.symbolSearchSymbols,
     symbolSearchPinned = map restoreSymbol result.symbolSearchPinned}
  _ -> message
  where
    originalPath path = case find ((== normalise path) . normalise . snapshotPath) (Map.elems documents) of
      Just document -> Map.findWithDefault path document.snapshotDocumentId originals
      Nothing -> path
    restoreSymbol symbol = symbol {indexedSourcePath = originalPath <$> symbol.indexedSourcePath}
