{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

module VisualHaskell.Analysis.Ghc910.Engine
  ( analyzeWorkspace
  ) where

import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import VisualHaskell.Analysis.Ghc910.Compat
import VisualHaskell.Analysis.Ghc910.Project
import VisualHaskell.Analysis.Ghc910.Types
import VisualHaskell.Semantic

analyzeWorkspace
  :: FilePath
  -> Map DocumentId DocumentSnapshot
  -> DocumentId
  -> WorkspaceGeneration
  -> IO (Either GhcAnalysisFailure (AnalysisSnapshot RevisionedSourceRange))
analyzeWorkspace _ documents requested generation =
  case Map.lookup requested documents of
    Nothing ->
      pure
        ( Left
            GhcAnalysisFailure
              { failureCode = "document-unavailable"
              , failureMessage = "The requested document is not open"
              , failureRecoverable = True
              }
        )
    Just primary -> do
      let paths = fmap snapshotPath (Map.elems documents)
      discovered <- discoverCompilerInvocation primary.snapshotPath paths
      case discovered of
        Left failure -> pure (Left failure)
        Right invocation -> analyzeWithGhc910 invocation documents requested generation
