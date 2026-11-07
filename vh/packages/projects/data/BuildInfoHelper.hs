-- Compiled with the project's own compiler and Cabal library, not linked into
-- the IDE. Reads the configured build without rewriting any project files.
module Main (main) where
import Distribution.Pretty (prettyShow)
import Distribution.Simple.Compiler (compilerId)
import Distribution.Simple.Configure (getPersistBuildConfig)
import Distribution.Simple.LocalBuildInfo
import Distribution.PackageDescription (getComponent, hsSourceDirs)
import Distribution.Types.Component (componentBuildInfo)
import Distribution.Utils.Path (getSymbolicPath)
import Distribution.Simple.ShowBuildInfo (mkComponentInfo)
import Distribution.Simple.Utils (cabalVersion)
import Distribution.Utils.Json
import qualified Data.ByteString.Lazy.Char8 as Bytes
import System.Environment (getArgs)

main :: IO ()
main = do
  arguments <- getArgs
  case arguments of
    _ | "--prepare-only" `elem` arguments -> pure ()
    [root, dist] -> do
      config <- getPersistBuildConfig dist
      let describe unit = case snd (mkComponentInfo root (localPkgDescr config) config unit) of
            JsonObject fields -> JsonObject
              (("context-name", JsonString (prettyShow (componentLocalName unit))) :
               ("context-dependencies", JsonArray [JsonString (prettyShow identifier) | (identifier, _) <- componentPackageDeps unit]) :
               ("context-source-roots", JsonArray [JsonString (getSymbolicPath path) |
                 path <- hsSourceDirs (componentBuildInfo (getComponent (localPkgDescr config) (componentLocalName unit)))]) : fields)
            other -> other
          components = map describe (allComponentsInBuildOrder config)
      Bytes.putStrLn $ renderJson $ JsonObject
        [("cabal-lib-version", JsonString (prettyShow cabalVersion)),
         ("compiler", JsonObject [("compiler-id", JsonString (prettyShow (compilerId (compiler config))))]),
         ("components", JsonArray components)]
    _ -> fail "Usage: build-info-helper PACKAGE_ROOT DIST_DIRECTORY"
