{-# LANGUAGE DerivingStrategies #-}

module UIH.Backend.AppKit.Internal.Capabilities
  ( AppKitCapabilities (..)
  , MacOSVersion (..)
  , queryAppKitCapabilities
  ) where

import UIH.Backend.AppKit.Internal.FFI
  ( c_versionMajor
  , c_versionMinor
  , c_versionPatch
  )

data MacOSVersion = MacOSVersion
  { macOSMajor :: !Int
  , macOSMinor :: !Int
  , macOSPatch :: !Int
  }
  deriving stock (Eq, Show)

data AppKitCapabilities = AppKitCapabilities
  { appKitVersion :: !MacOSVersion
  , supportsNativeWindowTabbing :: !Bool
  , supportsModernTextControls :: !Bool
  }
  deriving stock (Eq, Show)

queryAppKitCapabilities :: IO AppKitCapabilities
queryAppKitCapabilities = do
  major <- fromIntegral <$> c_versionMajor
  minor <- fromIntegral <$> c_versionMinor
  patch <- fromIntegral <$> c_versionPatch
  pure
    AppKitCapabilities
      { appKitVersion = MacOSVersion major minor patch
      , supportsNativeWindowTabbing = major >= 10
      , supportsModernTextControls = major >= 10
      }
