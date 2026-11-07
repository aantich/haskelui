{-# LANGUAGE TemplateHaskell #-}
module VisualHaskell.Analysis.Ghc910.Version (compilerVersionText, compilerFingerprintText, compilerTargetText) where
import Data.Text (Text, pack)
import qualified GHC.Settings.Config as GHC
import Language.Haskell.TH (runIO, stringE)
import VisualHaskell.Projects.Toolchains (compilerIdentityAtBuild)
import VisualHaskell.Semantic (CompilerIdentity (..))
import qualified Data.Text as Text

compilerVersionText :: Text
-- System.Info.compilerVersion omits the patch level on older GHC releases.
-- Match --numeric-version exactly, not merely the major/minor API series.
compilerVersionText = pack GHC.cProjectVersion

compilerFingerprintText :: Text
compilerFingerprintText = pack $(do
  compiler <- runIO compilerIdentityAtBuild
  if compilerVersion compiler /= pack GHC.cProjectVersion || compilerTarget compiler /= pack GHC.cHostPlatformString
    then fail "Build compiler does not match the linked GHC API; set VH_PROJECT_COMPILER to the compiler used by Cabal"
    else stringE (Text.unpack (compilerFingerprint compiler)))

compilerTargetText :: Text
compilerTargetText = pack GHC.cHostPlatformString
