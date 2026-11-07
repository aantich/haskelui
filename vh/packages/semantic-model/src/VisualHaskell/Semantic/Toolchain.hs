{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
module VisualHaskell.Semantic.Toolchain
  ( CompilerIdentity (..), ToolchainInventory (..), WorkerManifest (..), emptyToolchainInventory
  ) where

import Data.Aeson (FromJSON, ToJSON)
import Data.Text (Text)
import GHC.Generics (Generic)

-- Paths are observations of the existing installation, not an IDE-owned
-- toolchain database. Fingerprints include the compiler's actual package ABI.
data CompilerIdentity = CompilerIdentity
  { compilerExecutable :: !FilePath
  , compilerVersion :: !Text
  , compilerLibDir :: !FilePath
  , compilerTarget :: !Text
  , compilerFingerprint :: !Text
  , compilerOrigin :: !Text
  } deriving (Eq, Show, Generic, FromJSON, ToJSON)

data ToolchainInventory = ToolchainInventory
  { installedCompilers :: ![CompilerIdentity]
  , selectedCompiler :: !(Maybe CompilerIdentity)
  , selectedWorker :: !(Maybe FilePath)
  , ghcupExecutable :: !(Maybe FilePath)
  , toolchainWarnings :: ![Text]
  } deriving (Eq, Show, Generic, FromJSON, ToJSON)

data WorkerManifest = WorkerManifest
  { manifestCompilerFingerprint :: !Text
  , manifestCompilerVersion :: !Text
  , manifestSourceFingerprint :: !Text
  , manifestProtocolMajor :: !Int
  } deriving (Eq, Show, Generic, FromJSON, ToJSON)

emptyToolchainInventory :: ToolchainInventory
emptyToolchainInventory = ToolchainInventory [] Nothing Nothing Nothing []
