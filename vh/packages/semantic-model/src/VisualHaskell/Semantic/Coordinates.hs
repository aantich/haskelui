{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

module VisualHaskell.Semantic.Coordinates
  ( CoordinateError (..)
  , CoordinateIndex
  , CoordinateSpace (..)
  , RevisionedSourceRange (..)
  , SourcePosition (..)
  , buildCoordinateIndex
  , convertPosition
  , convertRange
  , positionToScalarOffset
  ) where

import Data.Aeson
  ( FromJSON (..)
  , ToJSON (..)
  , object
  , withObject
  , withText
  , (.:)
  , (.=)
  )
import Data.List (find)
import Data.Text (Text)
import qualified Data.Text as Text
import VisualHaskell.Semantic.Types (TextRevision (..))

-- | All positions are zero-based. GHC columns count tabs using an eight-column
-- tab stop; the other spaces count storage units within one logical line.
data CoordinateSpace
  = GhcColumn
  | Utf8ByteColumn
  | UnicodeScalarColumn
  | Utf16CodeUnitColumn
  deriving stock (Eq, Ord, Show)

instance ToJSON CoordinateSpace where
  toJSON space = toJSON $ case space of
    GhcColumn -> ("ghc-column" :: Text)
    Utf8ByteColumn -> "utf8-byte-column"
    UnicodeScalarColumn -> "unicode-scalar-column"
    Utf16CodeUnitColumn -> "utf16-code-unit-column"

instance FromJSON CoordinateSpace where
  parseJSON = withText "coordinate space" $ \value ->
    case value of
      "ghc-column" -> pure GhcColumn
      "utf8-byte-column" -> pure Utf8ByteColumn
      "unicode-scalar-column" -> pure UnicodeScalarColumn
      "utf16-code-unit-column" -> pure Utf16CodeUnitColumn
      _ -> fail ("unknown coordinate space " <> Text.unpack value)

data SourcePosition = SourcePosition
  { sourceLine :: !Int
  , sourceColumn :: !Int
  , sourceSpace :: !CoordinateSpace
  }
  deriving stock (Eq, Ord, Show)

instance ToJSON SourcePosition where
  toJSON position =
    object
      [ "line" .= position.sourceLine
      , "column" .= position.sourceColumn
      , "space" .= position.sourceSpace
      ]

instance FromJSON SourcePosition where
  parseJSON = withObject "source position" $ \value ->
    SourcePosition <$> value .: "line" <*> value .: "column" <*> value .: "space"

data RevisionedSourceRange = RevisionedSourceRange
  { sourceRangeRevision :: !TextRevision
  , sourceRangeStart :: !SourcePosition
  , sourceRangeEnd :: !SourcePosition
  }
  deriving stock (Eq, Ord, Show)

instance ToJSON RevisionedSourceRange where
  toJSON range =
    object
      [ "revision" .= range.sourceRangeRevision
      , "start" .= range.sourceRangeStart
      , "end" .= range.sourceRangeEnd
      ]

instance FromJSON RevisionedSourceRange where
  parseJSON = withObject "revision-bound source range" $ \value ->
    RevisionedSourceRange
      <$> value .: "revision"
      <*> value .: "start"
      <*> value .: "end"

data CoordinateError
  = NegativePosition !SourcePosition
  | LineOutOfBounds !Int
  | ColumnOutOfBounds !SourcePosition
  | ColumnInsideEncodingUnit !SourcePosition
  | MixedRangeSpaces !CoordinateSpace !CoordinateSpace
  | RangeRevisionMismatch !TextRevision !TextRevision
  | ReversedRange !SourcePosition !SourcePosition
  deriving stock (Eq, Show)

data CoordinateIndex = CoordinateIndex
  { coordinateRevision :: !TextRevision
  , coordinateLines :: ![LineIndex]
  }
  deriving stock (Eq, Show)

data LineIndex = LineIndex
  { lineScalarStart :: !Int
  , lineBoundaries :: ![Boundary]
  }
  deriving stock (Eq, Show)

data Boundary = Boundary
  { boundaryScalar :: !Int
  , boundaryUtf8 :: !Int
  , boundaryUtf16 :: !Int
  , boundaryGhc :: !Int
  }
  deriving stock (Eq, Show)

buildCoordinateIndex :: TextRevision -> Text -> CoordinateIndex
buildCoordinateIndex revision source =
  CoordinateIndex revision (buildLines 0 (Text.unpack source))

convertPosition
  :: CoordinateIndex
  -> CoordinateSpace
  -> SourcePosition
  -> Either CoordinateError SourcePosition
convertPosition index target position = do
  boundary <- boundaryFor index position
  pure
    SourcePosition
      { sourceLine = position.sourceLine
      , sourceColumn = boundaryColumn target boundary
      , sourceSpace = target
      }

convertRange
  :: CoordinateIndex
  -> CoordinateSpace
  -> RevisionedSourceRange
  -> Either CoordinateError RevisionedSourceRange
convertRange index target range
  | range.sourceRangeRevision /= index.coordinateRevision =
      Left (RangeRevisionMismatch index.coordinateRevision range.sourceRangeRevision)
  | range.sourceRangeStart.sourceSpace /= range.sourceRangeEnd.sourceSpace =
      Left
        ( MixedRangeSpaces
            range.sourceRangeStart.sourceSpace
            range.sourceRangeEnd.sourceSpace
        )
  | positionOrder range.sourceRangeStart > positionOrder range.sourceRangeEnd =
      Left (ReversedRange range.sourceRangeStart range.sourceRangeEnd)
  | otherwise =
      RevisionedSourceRange range.sourceRangeRevision
        <$> convertPosition index target range.sourceRangeStart
        <*> convertPosition index target range.sourceRangeEnd

positionToScalarOffset :: CoordinateIndex -> SourcePosition -> Either CoordinateError Int
positionToScalarOffset index position = do
  line <- lineFor index position
  boundary <- boundaryForLine position line
  pure (line.lineScalarStart + boundary.boundaryScalar)

boundaryFor :: CoordinateIndex -> SourcePosition -> Either CoordinateError Boundary
boundaryFor index position = do
  line <- lineFor index position
  boundaryForLine position line

lineFor :: CoordinateIndex -> SourcePosition -> Either CoordinateError LineIndex
lineFor index position
  | position.sourceLine < 0 || position.sourceColumn < 0 = Left (NegativePosition position)
  | otherwise =
      maybe
        (Left (LineOutOfBounds position.sourceLine))
        Right
        (atMay position.sourceLine index.coordinateLines)

boundaryForLine :: SourcePosition -> LineIndex -> Either CoordinateError Boundary
boundaryForLine position line =
  case find ((== position.sourceColumn) . boundaryColumn position.sourceSpace) line.lineBoundaries of
    Just boundary -> Right boundary
    Nothing
      | position.sourceColumn <= maximumColumn position.sourceSpace line ->
          Left (ColumnInsideEncodingUnit position)
      | otherwise -> Left (ColumnOutOfBounds position)

maximumColumn :: CoordinateSpace -> LineIndex -> Int
maximumColumn space line =
  case reverse line.lineBoundaries of
    boundary : _ -> boundaryColumn space boundary
    [] -> 0

boundaryColumn :: CoordinateSpace -> Boundary -> Int
boundaryColumn space boundary =
  case space of
    GhcColumn -> boundary.boundaryGhc
    Utf8ByteColumn -> boundary.boundaryUtf8
    UnicodeScalarColumn -> boundary.boundaryScalar
    Utf16CodeUnitColumn -> boundary.boundaryUtf16

buildLines :: Int -> String -> [LineIndex]
buildLines scalarStart characters =
  let (content, terminator, remaining) = takeLogicalLine characters
      line = LineIndex scalarStart (buildBoundaries content)
      nextStart = scalarStart + length content + length terminator
   in line : case remaining of
        []
          | null terminator -> []
          | otherwise -> [LineIndex nextStart [Boundary 0 0 0 0]]
        _ -> buildLines nextStart remaining

takeLogicalLine :: String -> (String, String, String)
takeLogicalLine = go []
  where
    go reversed [] = (reverse reversed, [], [])
    go reversed ('\r' : '\n' : remaining) = (reverse reversed, "\r\n", remaining)
    go reversed ('\r' : remaining) = (reverse reversed, "\r", remaining)
    go reversed ('\n' : remaining) = (reverse reversed, "\n", remaining)
    go reversed (character : remaining) = go (character : reversed) remaining

buildBoundaries :: String -> [Boundary]
buildBoundaries = scanl advance (Boundary 0 0 0 0)
  where
    advance :: Boundary -> Char -> Boundary
    advance boundary character =
      Boundary
        { boundaryScalar = boundary.boundaryScalar + 1
        , boundaryUtf8 = boundary.boundaryUtf8 + utf8Width character
        , boundaryUtf16 = boundary.boundaryUtf16 + utf16Width character
        , boundaryGhc =
            if character == '\t'
              then nextTabStop boundary.boundaryGhc
              else boundary.boundaryGhc + 1
        }

utf8Width :: Char -> Int
utf8Width character
  | code <= 0x7F = 1
  | code <= 0x7FF = 2
  | code <= 0xFFFF = 3
  | otherwise = 4
  where
    code = fromEnum character

utf16Width :: Char -> Int
utf16Width character = if fromEnum character <= 0xFFFF then 1 else 2

nextTabStop :: Int -> Int
nextTabStop column = ((column `div` 8) + 1) * 8

positionOrder :: SourcePosition -> (Int, Int)
positionOrder position = (position.sourceLine, position.sourceColumn)

atMay :: Int -> [value] -> Maybe value
atMay requested = go requested
  where
    go _ [] = Nothing
    go 0 (value : _) = Just value
    go remaining (_ : values) = go (remaining - 1) values
