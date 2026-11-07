module Main (main) where
import System.Environment (getArgs)
import qualified Session
import qualified Coordinator
main :: IO ()
main = do
  arguments <- getArgs
  if "--session-worker" `elem` arguments then Session.main else Coordinator.main
