{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

module VisualHaskell.TextMate.Oniguruma
  ( Capture (..)
  , CompiledRegex
  , Match (..)
  , RegexError (..)
  , compileRegex
  , onigurumaVersion
  , regexSource
  , searchRegex
  ) where

import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Unsafe as ByteStringUnsafe
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import Data.Word (Word8)
import Foreign
  ( ForeignPtr
  , FunPtr
  , Ptr
  , alloca
  , allocaArray
  , allocaBytes
  , castPtr
  , newForeignPtr
  , nullPtr
  , peek
  , peekArray
  , poke
  , pokeByteOff
  , withForeignPtr
  )
import Foreign.C
  ( CChar
  , CInt (..)
  , CSize (..)
  , CString
  , peekCString
  )

data NativeRegex

data CompiledRegex = CompiledRegex
  { regexSource :: !Text
  , regexHandle :: !(ForeignPtr NativeRegex)
  , regexCaptureGroups :: !Int
  }

data Capture = Capture
  { captureIndex :: !Int
  , captureByteStart :: !Int
  , captureByteEnd :: !Int
  }
  deriving stock (Eq, Show)

data Match = Match
  { matchByteStart :: !Int
  , matchByteEnd :: !Int
  , matchCaptures :: ![Capture]
  }
  deriving stock (Eq, Show)

newtype RegexError = RegexError {unRegexError :: Text}
  deriving stock (Eq, Show)

compileRegex :: Text -> IO (Either RegexError CompiledRegex)
compileRegex source = do
  let encoded = TextEncoding.encodeUtf8 source
  ByteStringUnsafe.unsafeUseAsCStringLen encoded $ \(patternPointer, patternLength) ->
    alloca $ \resultPointer ->
      alloca $ \captureCountPointer ->
        withErrorBuffer $ \errorPointer -> do
          poke resultPointer nullPtr
          poke captureCountPointer 0
          code <-
            c_compile
              (castPtr patternPointer)
              (fromIntegral patternLength)
              resultPointer
              captureCountPointer
              errorPointer
              errorBufferSize
          if code == 0
            then do
              native <- peek resultPointer
              captureCount <- fromIntegral <$> peek captureCountPointer
              managed <- newForeignPtr c_regexFreeFinalizer native
              pure
                ( Right
                    CompiledRegex
                      { regexSource = source
                      , regexHandle = managed
                      , regexCaptureGroups = captureCount
                      }
                )
            else Left <$> readRegexError source errorPointer

searchRegex
  :: CompiledRegex
  -> ByteString.ByteString
  -> Int
  -> IO (Either RegexError (Maybe Match))
searchRegex compiled subject requestedOffset =
  ByteStringUnsafe.unsafeUseAsCStringLen subject $ \(subjectPointer, subjectLength) ->
    withForeignPtr compiled.regexHandle $ \native -> do
      let startOffset = max 0 (min subjectLength requestedOffset)
          groupCapacity = compiled.regexCaptureGroups + 1
          pairCapacity = groupCapacity * 2
      allocaArray pairCapacity $ \pairsPointer ->
        alloca $ \captureCountPointer ->
          withErrorBuffer $ \errorPointer -> do
            poke captureCountPointer 0
            code <-
              c_search
                native
                (castPtr subjectPointer)
                (fromIntegral subjectLength)
                (fromIntegral startOffset)
                pairsPointer
                (fromIntegral pairCapacity)
                captureCountPointer
                errorPointer
                errorBufferSize
            case compare code 0 of
              LT -> Left <$> readRegexError compiled.regexSource errorPointer
              EQ -> pure (Right Nothing)
              GT -> do
                captureCount <- fromIntegral <$> peek captureCountPointer
                pairs <- fmap fromIntegral <$> peekArray (captureCount * 2) pairsPointer
                pure (Right (matchFromPairs pairs))

onigurumaVersion :: IO Text
onigurumaVersion = Text.pack <$> (c_version >>= peekCString)

matchFromPairs :: [Int] -> Maybe Match
matchFromPairs (start : end : remaining)
  | start >= 0 && end >= start =
      Just
        Match
          { matchByteStart = start
          , matchByteEnd = end
          , matchCaptures = capturePairs 1 remaining
          }
matchFromPairs _ = Nothing

capturePairs :: Int -> [Int] -> [Capture]
capturePairs _ [] = []
capturePairs index (start : end : remaining) =
  [ Capture index start end
  | start >= 0
  , end >= start
  ]
    <> capturePairs (index + 1) remaining
capturePairs _ _ = []

errorBufferSize :: CSize
errorBufferSize = 512

withErrorBuffer :: (Ptr CChar -> IO value) -> IO value
withErrorBuffer use =
  allocaBytes (fromIntegral errorBufferSize) $ \pointer -> do
    pokeByteOff pointer 0 (0 :: CChar)
    use pointer

readRegexError :: Text -> Ptr CChar -> IO RegexError
readRegexError source pointer = do
  message <- Text.pack <$> peekCString pointer
  pure
    ( RegexError
        ( if Text.null message
            then "Oniguruma rejected pattern: " <> source
            else message <> " in pattern " <> source
        )
    )

foreign import ccall safe "visual_haskell_textmate_compile"
  c_compile
    :: Ptr Word8
    -> CSize
    -> Ptr (Ptr NativeRegex)
    -> Ptr CInt
    -> Ptr CChar
    -> CSize
    -> IO CInt

foreign import ccall safe "visual_haskell_textmate_search"
  c_search
    :: Ptr NativeRegex
    -> Ptr Word8
    -> CSize
    -> CSize
    -> Ptr CInt
    -> CSize
    -> Ptr CInt
    -> Ptr CChar
    -> CSize
    -> IO CInt

foreign import ccall unsafe "&visual_haskell_textmate_regex_free"
  c_regexFreeFinalizer :: FunPtr (Ptr NativeRegex -> IO ())

foreign import ccall unsafe "visual_haskell_textmate_oniguruma_version"
  c_version :: IO CString
