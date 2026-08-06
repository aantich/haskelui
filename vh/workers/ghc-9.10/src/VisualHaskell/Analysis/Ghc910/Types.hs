{-# LANGUAGE DerivingStrategies #-}

module VisualHaskell.Analysis.Ghc910.Types
  ( CompilerInvocation (..)
  , GhcAnalysisFailure (..)
  ) where

import Data.Text (Text)

data CompilerInvocation = CompilerInvocation
  { invocationComponentRoot :: !FilePath
  , invocationCompilerOptions :: ![String]
  , invocationCradleDependencies :: ![FilePath]
  , invocationCompilerLibDir :: !FilePath
  , invocationCompilerVersion :: !Text
  }
  deriving stock (Eq, Show)

data GhcAnalysisFailure = GhcAnalysisFailure
  { failureCode :: !Text
  , failureMessage :: !Text
  , failureRecoverable :: !Bool
  }
  deriving stock (Eq, Show)
