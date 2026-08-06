{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

module VisualHaskell.Analysis.Protocol.Framing
  ( FrameError (..)
  , FrameLimits (..)
  , defaultFrameLimits
  , readFrame
  , writeFrame
  ) where

import Control.Exception (IOException, displayException, try)
import Data.Aeson (FromJSON, ToJSON, eitherDecodeStrict', encode)
import Data.Bits ((.|.), shiftL, shiftR)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Lazy as LazyByteString
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word32, Word8)
import System.IO (Handle, hFlush)

newtype FrameLimits = FrameLimits
  { maximumFrameBytes :: Word32
  }
  deriving stock (Eq, Show)

defaultFrameLimits :: FrameLimits
defaultFrameLimits = FrameLimits (16 * 1024 * 1024)

data FrameError
  = FrameEndOfInput
  | FrameUnexpectedEnd !Int !Int
  | FrameTooLarge !Word32 !Word32
  | FrameInvalidJson !Text
  | FrameIoFailure !Text
  deriving stock (Eq, Show)

writeFrame :: ToJSON value => FrameLimits -> Handle -> value -> IO (Either FrameError ())
writeFrame limits handle value = do
  let payload = LazyByteString.toStrict (encode value)
      payloadLength = ByteString.length payload
      maximumLength = fromIntegral limits.maximumFrameBytes
  if payloadLength > maximumLength || toInteger payloadLength > toInteger (maxBound :: Word32)
    then pure (Left (FrameTooLarge (fromIntegral (min payloadLength (fromIntegral (maxBound :: Word32)))) limits.maximumFrameBytes))
    else do
      attempted <- try $ do
        ByteString.hPut handle (encodeLength (fromIntegral payloadLength))
        ByteString.hPut handle payload
        hFlush handle
      pure $ either (Left . FrameIoFailure . Text.pack . displayException) Right (attempted :: Either IOException ())

readFrame :: FromJSON value => FrameLimits -> Handle -> IO (Either FrameError value)
readFrame limits handle = do
  headerResult <- readExactly handle 4
  case headerResult of
    Left failure -> pure (Left failure)
    Right header -> do
      let payloadLength = decodeLength header
      if payloadLength > limits.maximumFrameBytes
        then pure (Left (FrameTooLarge payloadLength limits.maximumFrameBytes))
        else do
          payloadResult <- readExactly handle (fromIntegral payloadLength)
          pure $ do
            payload <- payloadResult
            either (Left . FrameInvalidJson . Text.pack) Right (eitherDecodeStrict' payload)

readExactly :: Handle -> Int -> IO (Either FrameError ByteString.ByteString)
readExactly handle requested = go [] 0
  where
    go chunks received
      | received == requested = pure (Right (ByteString.concat (reverse chunks)))
      | otherwise = do
          attempted <- try (ByteString.hGet handle (requested - received))
          case attempted of
            Left exception -> pure (Left (FrameIoFailure (Text.pack (displayException (exception :: IOException)))))
            Right bytes
              | ByteString.null bytes ->
                  pure $ Left $ if received == 0 then FrameEndOfInput else FrameUnexpectedEnd requested received
              | otherwise -> go (bytes : chunks) (received + ByteString.length bytes)

encodeLength :: Word32 -> ByteString.ByteString
encodeLength value = ByteString.pack
  [ byte 24, byte 16, byte 8, byte 0 ]
  where
    byte shift = fromIntegral (value `shiftR` shift) :: Word8

decodeLength :: ByteString.ByteString -> Word32
decodeLength bytes =
  foldl
    (\accumulator byte -> (accumulator `shiftL` 8) .|. fromIntegral byte)
    0
    (ByteString.unpack bytes)
