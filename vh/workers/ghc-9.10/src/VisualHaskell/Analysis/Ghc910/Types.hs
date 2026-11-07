{-# LANGUAGE DerivingStrategies #-}

module VisualHaskell.Analysis.Ghc910.Types
  ( CompilerInvocation (..)
  , GhcAnalysisFailure (..)
  ) where

import Data.Text (Text)
import VisualHaskell.Semantic (SessionId)

data CompilerInvocation = CompilerInvocation
  { invocationComponentRoot :: !FilePath
  , invocationCompilerOptions :: ![String]
  , invocationCradleDependencies :: ![FilePath]
  , invocationCompilerLibDir :: !FilePath
  , invocationCompilerVersion :: !Text
  , invocationPrimaryUnit :: !(Maybe Text)
  , invocationUnitRoots :: ![(Text, [FilePath])]
  , invocationSessionIdentity :: !(Maybe SessionId)
  , invocationUnitDirectories :: ![(Text, FilePath)]
  }
  deriving stock (Eq, Show)

data GhcAnalysisFailure = GhcAnalysisFailure
  { failureCode :: !Text
  , failureMessage :: !Text
  , failureRecoverable :: !Bool
  }
  deriving stock (Eq, Show)
