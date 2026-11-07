{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

-- | An index is component-scoped, not a claim that every project component
-- has been loaded. Each symbol owns its type table: pretty-printed type IDs
-- from different compiler projections must never be unified by string equality.
module VisualHaskell.Semantic.SymbolIndex
  ( IndexedSymbol (..), SymbolKind (..), SymbolQuery (..)
  , SymbolSearchResult (..), symbolFunction, searchSymbols, reconcileSymbolPage
  ) where

import Data.Aeson (FromJSON, ToJSON)
import Data.List (sortOn)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text
import GHC.Generics (Generic)
import VisualHaskell.Semantic.Coordinates
import VisualHaskell.Semantic.FunctionUniverse
import VisualHaskell.Semantic.Types

data IndexedSymbol = IndexedSymbol
  { indexedDeclaration :: !(Declaration (Maybe RevisionedSourceRange))
  , indexedTypes :: !TypeTable
  , indexedModule :: !ModuleName -- ^ Importable export module, not hidden defining module.
  , indexedUnit :: !Text
  , indexedPackage :: !Text
  , indexedPackageVersion :: !Text
  , indexedSourcePath :: !(Maybe FilePath)
  , indexedSourceHash :: !(Maybe ContentHash)
  }
  deriving (Eq, Show, Generic, ToJSON, FromJSON)

data SymbolKind = AllSymbols | FunctionSymbols | TypeSymbols
  deriving (Eq, Ord, Show, Generic, ToJSON, FromJSON)

data SymbolQuery = SymbolQuery
  { symbolQueryText :: !Text
  , symbolQueryKind :: !SymbolKind
  , symbolQueryOffset :: !Int
  , symbolQueryLimit :: !Int
  , symbolQueryPinned :: ![DeclarationId]
  }
  deriving (Eq, Show, Generic, ToJSON, FromJSON)

data SymbolSearchResult = SymbolSearchResult
  { symbolSearchQuery :: !SymbolQuery
  , symbolSearchSymbols :: ![IndexedSymbol]
  , symbolSearchPinned :: ![IndexedSymbol]
  , symbolSearchTotal :: !Int
  , symbolSearchLocalModules :: !Int
  , symbolSearchLibraryModules :: !Int
  , symbolSearchCacheHits :: !Int
  , symbolSearchWarnings :: ![Text]
  , symbolSearchComplete :: !Bool -- ^ Missing pins imply deletion only with complete coverage.
  , symbolSearchRevision :: !ContentHash -- ^ Component inputs, including closed/TH dependencies.
  }
  deriving (Eq, Show, Generic, ToJSON, FromJSON)

-- | A partial page cannot revoke earlier pinned declarations. Keep their
-- presentation, but explicitly mark them unavailable for semantic operations.
reconcileSymbolPage
  :: SymbolSearchResult -> Map.Map DeclarationId IndexedSymbol
  -> (Map.Map DeclarationId IndexedSymbol, Set.Set DeclarationId)
reconcileSymbolPage result previous = (Map.union fresh retained, Map.keysSet retained)
  where
    fresh = Map.fromList [(symbol.indexedDeclaration.declarationId, symbol)
      | symbol <- result.symbolSearchPinned <> result.symbolSearchSymbols]
    retained
      | result.symbolSearchComplete = Map.empty
      | otherwise = Map.withoutKeys
          (Map.restrictKeys previous (Set.fromList (take 64 result.symbolSearchQuery.symbolQueryPinned)))
          (Map.keysSet fresh)

symbolFunction :: IndexedSymbol -> Maybe (FunctionNode (Maybe RevisionedSourceRange))
symbolFunction symbol = case buildFunctionNodes symbol.indexedTypes [symbol.indexedDeclaration] of
  node : _ -> Just node {functionName = symbol.indexedModule.unModuleName <> "." <> node.functionName}
  [] -> Nothing

-- | Bounded pages prevent the entire package database crossing the protocol.
-- Filter before de-duplicating so a requested re-export module stays usable.
searchSymbols :: SymbolQuery -> [IndexedSymbol] -> (Int, [IndexedSymbol])
searchSymbols query symbols = (length ordered, take (max 1 (min 100 query.symbolQueryLimit)) (drop (max 0 query.symbolQueryOffset) ordered))
  where
    terms = Text.words (Text.toCaseFold query.symbolQueryText)
    matching symbol = all (`Text.isInfixOf` searchable symbol) terms && kindMatches symbol
    searchable :: IndexedSymbol -> Text
    searchable symbol = Text.toCaseFold (Text.unwords
      [symbol.indexedModule.unModuleName <> "." <> symbol.indexedDeclaration.declarationName,
       symbol.indexedPackage, symbol.indexedPackageVersion,
       maybe "" id symbol.indexedDeclaration.declarationSignatureText])
    kindMatches symbol = case query.symbolQueryKind of
      AllSymbols -> True
      FunctionSymbols -> case symbolFunction symbol of Just _ -> True; Nothing -> False
      TypeSymbols -> symbol.indexedDeclaration.declarationKind `elem` [TypeDeclaration, ClassDeclaration]
    ordered = sortOn (\symbol -> (symbol.indexedSourcePath == Nothing, symbol.indexedModule,
                                 symbol.indexedDeclaration.declarationName))
      (Map.elems (Map.fromListWith (flip const)
        [(symbol.indexedDeclaration.declarationId, symbol) | symbol <- sortOn routeRank (filter matching symbols)]))
    -- Prefer the public qualified route actually typed by the user over a
    -- longer internal-module re-export that happens to contain the same text.
    routeRank :: IndexedSymbol -> Int
    routeRank symbol = if any (`Text.isPrefixOf` qualified) terms then 0 else 1
      where qualified = Text.toCaseFold (symbol.indexedModule.unModuleName <> "." <> symbol.indexedDeclaration.declarationName)
