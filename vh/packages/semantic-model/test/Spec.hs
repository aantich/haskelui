{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Control.Monad (unless)
import Data.Aeson (decode, encode)
import VisualHaskell.Semantic

main :: IO ()
main = do
  let revision = TextRevision 7
      index = buildCoordinateIndex revision "a\t😀e\r\nλx\n"
      scalar column = SourcePosition 0 column UnicodeScalarColumn
  assertEqual "emoji UTF-8 boundary" (Right (SourcePosition 0 6 Utf8ByteColumn))
    (convertPosition index Utf8ByteColumn (scalar 3))
  assertEqual "emoji UTF-16 boundary" (Right (SourcePosition 0 4 Utf16CodeUnitColumn))
    (convertPosition index Utf16CodeUnitColumn (scalar 3))
  assertEqual "GHC tab stop" (Right (SourcePosition 0 8 GhcColumn))
    (convertPosition index GhcColumn (scalar 2))
  assertEqual "CRLF contributes two scalar offsets" (Right 6)
    (positionToScalarOffset index (SourcePosition 1 0 UnicodeScalarColumn))
  assertEqual "UTF-8 rejects an offset inside lambda" (Left (ColumnInsideEncodingUnit (SourcePosition 1 1 Utf8ByteColumn)))
    (convertPosition index UnicodeScalarColumn (SourcePosition 1 1 Utf8ByteColumn))
  let range = RevisionedSourceRange revision (scalar 2) (scalar 4)
  assertEqual "range conversion is revision-bound"
    (Right (RevisionedSourceRange revision (SourcePosition 0 2 Utf16CodeUnitColumn) (SourcePosition 0 5 Utf16CodeUnitColumn)))
    (convertRange index Utf16CodeUnitColumn range)
  assertEqual "stale range is rejected"
    (Left (RangeRevisionMismatch revision (TextRevision 6)))
    (convertRange index Utf8ByteColumn range {sourceRangeRevision = TextRevision 6})
  let snapshot =
        DocumentSnapshot
          (DocumentId "doc") "Main.hs" revision
          (contentHash "main = pure ()") "main = pure ()" LF
  assertEqual "document snapshot JSON round trip" (Just snapshot) (decode (encode snapshot))
  putStrLn "Visual Haskell semantic model tests passed"

assertEqual :: (Eq value, Show value) => String -> value -> value -> IO ()
assertEqual message expected actual =
  unless (expected == actual) $
    fail (message <> ": expected " <> show expected <> ", got " <> show actual)
