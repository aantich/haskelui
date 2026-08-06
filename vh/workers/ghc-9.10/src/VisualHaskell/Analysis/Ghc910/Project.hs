{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

module VisualHaskell.Analysis.Ghc910.Project
  ( discoverCompilerInvocation
  ) where

import Data.Text (Text)
import qualified Data.Text as Text
import HIE.Bios
  ( ComponentOptions (..)
  , CradleLoadResult (..)
  , findCradle
  , getCompilerOptions
  , loadCradle
  , loadImplicitCradle
  )
import HIE.Bios.Environment
  ( getRuntimeGhcLibDir
  , getRuntimeGhcVersion
  )
import HIE.Bios.Types (LoadStyle (..))
import VisualHaskell.Analysis.Ghc910.Types

discoverCompilerInvocation
  :: FilePath
  -> [FilePath]
  -> IO (Either GhcAnalysisFailure CompilerInvocation)
discoverCompilerInvocation primary context = do
  configured <- findCradle primary
  cradle <- maybe (loadImplicitCradle mempty primary) (loadCradle mempty) configured
  optionsResult <- getCompilerOptions primary (LoadWithContext context) cradle
  libDirResult <- getRuntimeGhcLibDir cradle
  versionResult <- getRuntimeGhcVersion cradle
  pure $ do
    options <- fromCradleResult "component-options" optionsResult
    libDir <- fromCradleResult "compiler-libdir" libDirResult
    version <- Text.pack <$> fromCradleResult "compiler-version" versionResult
    if version /= "9.10.3"
      then
        Left
          GhcAnalysisFailure
            { failureCode = "incompatible-compiler"
            , failureMessage =
                "This worker requires GHC 9.10.3, but the project cradle selected " <> version
            , failureRecoverable = False
            }
      else
        Right
          CompilerInvocation
            { invocationComponentRoot = options.componentRoot
            , invocationCompilerOptions = options.componentOptions
            , invocationCradleDependencies = options.componentDependencies
            , invocationCompilerLibDir = libDir
            , invocationCompilerVersion = version
            }

fromCradleResult :: Text -> CradleLoadResult value -> Either GhcAnalysisFailure value
fromCradleResult operation result =
  case result of
    CradleSuccess value -> Right value
    CradleNone ->
      Left
        GhcAnalysisFailure
          { failureCode = "cradle-none"
          , failureMessage = "No cradle accepted the " <> operation <> " request"
          , failureRecoverable = True
          }
    CradleFail cradleFailure ->
      Left
        GhcAnalysisFailure
          { failureCode = "cradle-failed"
          , failureMessage = operation <> " failed: " <> Text.pack (show cradleFailure)
          , failureRecoverable = True
          }
