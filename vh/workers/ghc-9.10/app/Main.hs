module Main (main) where
import Data.Aeson (eitherDecodeFileStrict', encode)
import qualified Data.ByteString.Lazy.Char8 as Bytes
import qualified Data.Text.IO as Text
import System.Environment (getArgs)
import System.IO (stderr, hSetBuffering, BufferMode (LineBuffering))
import VisualHaskell.Analysis.Ghc910 (prepareProjectContext)
import VisualHaskell.Projects (runTool)
import qualified Session
import qualified Coordinator
main :: IO ()
main = do
  arguments <- getArgs
  case arguments of
    ["--prepare-context", request] -> Session.withParentLifetime $ do
      hSetBuffering stderr LineBuffering
      -- The coordinator launches this mode in its own process group. In
      -- particular, hie-bios's Cabal/Setup/compiler children inherit that group
      -- and cannot escape an ordinary preparation cancellation.
      (cache, catalog, component) <- eitherDecodeFileStrict' request >>= either fail pure
      context <- prepareProjectContext (runTool (Text.hPutStrLn stderr)) cache catalog component
      Bytes.putStrLn (encode context)
    _ | "--session-worker" `elem` arguments -> Session.main
    _ -> Coordinator.main
