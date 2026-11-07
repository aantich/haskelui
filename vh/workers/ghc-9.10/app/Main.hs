{-# LANGUAGE OverloadedStrings #-}
module Main (main) where
import Data.Aeson (eitherDecodeFileStrict', encode, object, (.=))
import qualified Data.ByteString.Lazy.Char8 as Bytes
import qualified Data.Text.IO as Text
import System.Environment (getArgs, lookupEnv, setEnv)
import System.Directory (getCurrentDirectory)
import Control.Monad (unless)
import System.IO (stderr, hSetBuffering, BufferMode (LineBuffering))
import VisualHaskell.Analysis.Ghc910 (prepareProjectContext, probeCradleCompiler)
import VisualHaskell.Projects (runToolInExistingGroup)
import VisualHaskell.Projects.Toolchains
import VisualHaskell.Semantic (CompilerIdentity (..))
import VisualHaskell.Analysis.Ghc910.Version
import System.Posix.Process (executeFile)
import qualified Session
main :: IO ()
main = do
  arguments <- getArgs
  case arguments of
    ["--worker-info"] -> Bytes.putStrLn (encode (object
      ["compilerVersion" .= compilerVersionText, "compilerFingerprint" .= compilerFingerprintText,
       "compilerTarget" .= compilerTargetText, "workerApi" .= workerApiVersion]))
    ["--probe-cradle", request] -> Session.withParentLifetime $ do
      hSetBuffering stderr LineBuffering
      (root, configuration, installed) <- eitherDecodeFileStrict' request >>= either fail pure
      compiler <- probeCradleCompiler (runToolInExistingGroup (Text.hPutStrLn stderr)) root configuration installed
      Bytes.putStrLn (encode compiler)
    ["--prepare-context", request] -> Session.withParentLifetime $ do
      hSetBuffering stderr LineBuffering
      -- The coordinator launches this mode in its own process group. In
      -- particular, hie-bios's Cabal/Setup/compiler children inherit that group
      -- and cannot escape an ordinary preparation cancellation.
      (cache, catalog, component) <- eitherDecodeFileStrict' request >>= either fail pure
      let run = runToolInExistingGroup (Text.hPutStrLn stderr)
      path <- lookupEnv "VH_PROJECT_COMPILER" >>= maybe
        (resolveTool "VH_GHC" "ghc" >>= maybe (fail "Project compiler is unavailable") pure) pure
      directory <- getCurrentDirectory
      compiler <- inspectCompiler run directory "Preparation" path
      unless (compilerFingerprint compiler == compilerFingerprintText) (fail "Preparation worker does not match the project compiler ABI")
      -- This short-lived helper owns no UI/coordinator threads. hie-bios uses
      -- its process environment internally, rather than our ToolRunner.
      compilerEnvironment compiler >>= mapM_ (uncurry setEnv)
      runner <- projectToolRunnerWith run compiler
      context <- prepareProjectContext runner cache catalog component
      Bytes.putStrLn (encode context)
    _ | "--session-worker" `elem` arguments -> Session.main
    _ -> do
      coordinator <- resolveCoordinator
      executeFile coordinator False arguments Nothing
