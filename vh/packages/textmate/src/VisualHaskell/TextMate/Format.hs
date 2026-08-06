{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module VisualHaskell.TextMate.Format
  ( readStructuredFile
  ) where

import Control.Exception (IOException, try)
import Data.Aeson
  ( Value (..)
  , eitherDecodeStrict'
  )
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KeyMap
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Lazy as LazyByteString
import Data.Scientific (fromFloatDigits)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Vector as Vector
import Text.Read (readMaybe)
import Text.XML
  ( Document (..)
  , Element (..)
  , Name (..)
  , Node (..)
  , def
  , parseLBS
  )

readStructuredFile :: Int -> FilePath -> IO (Either Text Value)
readStructuredFile maximumBytes path = do
  result <- try (ByteString.readFile path)
  pure $ case result of
    Left (exception :: IOException) -> Left (Text.pack (show exception))
    Right contents
      | ByteString.length contents > max 1 maximumBytes ->
          Left
            ( "File exceeds the configured size limit: "
                <> Text.pack path
            )
      | looksLikeXml contents -> decodePlist contents
      | otherwise ->
          case eitherDecodeStrict' (stripUtf8Bom contents) of
            Left message -> Left (Text.pack message)
            Right value -> Right value

looksLikeXml :: ByteString.ByteString -> Bool
looksLikeXml contents =
  case ByteString.uncons (ByteString.dropWhile isAsciiSpace (stripUtf8Bom contents)) of
    Just (firstByte, _) -> firstByte == fromIntegral (fromEnum '<')
    Nothing -> False
  where
    isAsciiSpace byte = byte `elem` [9, 10, 13, 32]

stripUtf8Bom :: ByteString.ByteString -> ByteString.ByteString
stripUtf8Bom contents
  | ByteString.take 3 contents == ByteString.pack [0xEF, 0xBB, 0xBF] =
      ByteString.drop 3 contents
  | otherwise = contents

decodePlist :: ByteString.ByteString -> Either Text Value
decodePlist contents = do
  document <-
    case parseLBS def (LazyByteString.fromStrict contents) of
      Left exception -> Left (Text.pack (show exception))
      Right parsed -> Right parsed
  let root = documentRoot document
  valueElement <-
    case localName (elementName root) of
      "plist" ->
        maybe
          (Left "plist does not contain a value")
          Right
          (firstElement (elementNodes root))
      _ -> Right root
  plistElementValue valueElement

plistElementValue :: Element -> Either Text Value
plistElementValue element =
  case localName (elementName element) of
    "dict" -> Object <$> plistDictionary (elementChildren (elementNodes element))
    "array" -> Array . Vector.fromList <$> traverse plistElementValue (elementChildren (elementNodes element))
    "string" -> Right (String (elementText element))
    "key" -> Right (String (elementText element))
    "integer" ->
      maybe
        (Left "invalid plist integer")
        (Right . Number . fromInteger)
        (readMaybe (Text.unpack (Text.strip (elementText element))))
    "real" ->
      maybe
        (Left "invalid plist real")
        (Right . Number . fromFloatDigits)
        (readMaybe (Text.unpack (Text.strip (elementText element))) :: Maybe Double)
    "true" -> Right (Bool True)
    "false" -> Right (Bool False)
    "data" -> Right (String (Text.strip (elementText element)))
    name -> Left ("unsupported plist value element: " <> name)

plistDictionary
  :: [Element]
  -> Either Text (KeyMap.KeyMap Value)
plistDictionary elements = go elements mempty
  where
    go [] values = Right values
    go (keyElement : valueElement : remaining) values
      | localName (elementName keyElement) == "key" = do
          value <- plistElementValue valueElement
          go
            remaining
            (KeyMap.insert (Key.fromText (elementText keyElement)) value values)
      | otherwise = Left "plist dictionary entry does not begin with key"
    go _ _ = Left "plist dictionary contains an unmatched key or value"

firstElement :: [Node] -> Maybe Element
firstElement [] = Nothing
firstElement (NodeElement element : _) = Just element
firstElement (_ : remaining) = firstElement remaining

elementChildren :: [Node] -> [Element]
elementChildren = foldr collect []
  where
    collect (NodeElement element) rest = element : rest
    collect _ rest = rest

elementText :: Element -> Text
elementText element = Text.concat (fmap nodeText (elementNodes element))
  where
    nodeText (NodeContent content) = content
    nodeText (NodeElement child) = elementText child
    nodeText _ = ""

localName :: Name -> Text
localName = nameLocalName
