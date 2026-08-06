{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

module VisualHaskell.TrustState
  ( TrustRegistry (..)
  , decodeTrustRegistry
  , emptyTrustRegistry
  , encodeTrustRegistry
  ) where

import Data.Aeson
  ( FromJSON (..)
  , ToJSON (..)
  , eitherDecodeStrict'
  , encode
  , object
  , withObject
  , (.:)
  , (.=)
  )
import qualified Data.ByteString.Lazy as LazyByteString
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import System.FilePath (isAbsolute, normalise)

-- | User-owned authority for workspace trust. Project metadata may request
-- restoration of trust, but only a path present here can grant it.
newtype TrustRegistry = TrustRegistry
  { trustedWorkspaceRoots :: Set FilePath
  }
  deriving stock (Eq, Show)

emptyTrustRegistry :: TrustRegistry
emptyTrustRegistry = TrustRegistry Set.empty

instance ToJSON TrustRegistry where
  toJSON registry =
    object
      [ "format" .= ("visual-haskell-trust-registry" :: Text)
      , "version" .= (1 :: Int)
      , "trustedWorkspaceRoots"
          .= fmap Text.pack (Set.toAscList registry.trustedWorkspaceRoots)
      ]

instance FromJSON TrustRegistry where
  parseJSON = withObject "Visual Haskell trust registry" $ \value -> do
    format <- value .: "format"
    version <- value .: "version"
    if (format :: Text) /= "visual-haskell-trust-registry"
      then fail "unexpected trust-registry format"
      else pure ()
    if (version :: Int) /= 1
      then fail ("unsupported trust-registry version " <> show version)
      else pure ()
    roots <- value .: "trustedWorkspaceRoots"
    validated <- traverse validateRoot roots
    pure (TrustRegistry (Set.fromList validated))
    where
      validateRoot raw
        | Text.null (Text.strip raw) = fail "trusted workspace path is empty"
        | not (isAbsolute path) = fail "trusted workspace path is not absolute"
        | otherwise = pure (normalise path)
        where
          path = Text.unpack raw

encodeTrustRegistry :: TrustRegistry -> Text
encodeTrustRegistry =
  TextEncoding.decodeUtf8
    . LazyByteString.toStrict
    . encode

decodeTrustRegistry :: Text -> Either Text TrustRegistry
decodeTrustRegistry =
  either (Left . Text.pack) Right
    . eitherDecodeStrict'
    . TextEncoding.encodeUtf8
