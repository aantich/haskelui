import Distribution.Simple
import Control.Monad (unless)
import System.Directory (doesFileExist)
main :: IO ()
main = defaultMainWithHooks simpleUserHooks
  { preConf = \arguments flags -> do
      exists <- doesFileExist "src/Generated.hs"
      unless exists (writeFile "src/Generated.hs" "module Generated (answer) where\nanswer :: Int\nanswer = 42\n")
      preConf simpleUserHooks arguments flags
  }
