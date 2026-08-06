{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedRecordDot #-}

module VisualHaskell.Paths
  ( VisualHaskellPaths (..)
  , ensureVisualHaskellPaths
  , resolveVisualHaskellPaths
  ) where

import Control.Monad (forM_)
import System.Directory
  ( XdgDirectory (XdgCache, XdgState)
  , createDirectoryIfMissing
  , getHomeDirectory
  , getXdgDirectory
  )
import System.Environment (lookupEnv)
import System.FilePath ((</>), normalise)

-- | All process-wide paths used by Visual Haskell. User-installable,
-- portable resources deliberately live under @~/.vh@; mutable runtime state
-- and caches continue to follow the host platform's XDG locations.
data VisualHaskellPaths = VisualHaskellPaths
  { visualHaskellHome :: !FilePath
  , visualHaskellExtensionDirectory :: !FilePath
  , visualHaskellGrammarDirectory :: !FilePath
  , visualHaskellThemeDirectory :: !FilePath
  , visualHaskellSettingsPath :: !FilePath
  , visualHaskellStateDirectory :: !FilePath
  , visualHaskellCacheDirectory :: !FilePath
  , visualHaskellLogDirectory :: !FilePath
  , visualHaskellLastWorkspacePath :: !FilePath
  }
  deriving stock (Eq, Show)

-- | Resolve paths without touching the filesystem. @VH_HOME@ is an explicit
-- portability/test override; otherwise the public resource root is @~/.vh@.
resolveVisualHaskellPaths :: IO VisualHaskellPaths
resolveVisualHaskellPaths = do
  override <- lookupEnv "VH_HOME"
  userHome <- getHomeDirectory
  stateDirectory <- getXdgDirectory XdgState "visual-haskell"
  cacheDirectory <- getXdgDirectory XdgCache "visual-haskell"
  let resourceHome = normalise (maybe (userHome </> ".vh") id override)
  pure
    VisualHaskellPaths
      { visualHaskellHome = resourceHome
      , visualHaskellExtensionDirectory = resourceHome </> "extensions"
      , visualHaskellGrammarDirectory = resourceHome </> "grammars"
      , visualHaskellThemeDirectory = resourceHome </> "themes"
      , visualHaskellSettingsPath = resourceHome </> "settings.json"
      , visualHaskellStateDirectory = stateDirectory
      , visualHaskellCacheDirectory = cacheDirectory
      , visualHaskellLogDirectory = stateDirectory </> "logs"
      , visualHaskellLastWorkspacePath = stateDirectory </> "last-workspace"
      }

-- | Create only directories. Visual Haskell does not manufacture a settings
-- file until there are settings to persist, so an absent file remains a
-- meaningful "use defaults" state.
ensureVisualHaskellPaths :: VisualHaskellPaths -> IO ()
ensureVisualHaskellPaths paths =
  forM_
    [ paths.visualHaskellHome
    , paths.visualHaskellExtensionDirectory
    , paths.visualHaskellGrammarDirectory
    , paths.visualHaskellThemeDirectory
    , paths.visualHaskellStateDirectory
    , paths.visualHaskellCacheDirectory
    , paths.visualHaskellLogDirectory
    ]
    (createDirectoryIfMissing True)
