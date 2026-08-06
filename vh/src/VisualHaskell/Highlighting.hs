{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

module VisualHaskell.Highlighting
  ( SyntaxClass (..)
  , codeEditorBaseStyle
  , haskellSyntaxLayer
  , highlightHaskell
  , syntaxStyle
  ) where

import Data.Char
  ( isAlpha
  , isAlphaNum
  , isDigit
  , isSpace
  , isUpper
  )
import Data.Text (Text)
import qualified Data.Text as Text
import HaskeLUI.Core

data SyntaxClass
  = SyntaxKeyword
  | SyntaxComment
  | SyntaxString
  | SyntaxCharacter
  | SyntaxNumber
  | SyntaxTypeName
  | SyntaxOperator
  deriving stock (Eq, Ord, Show)

syntaxLayerKey :: TextLayerKey
syntaxLayerKey = TextLayerKey 1

-- | Foreground/background are deliberately inherited from the native editor.
-- AppKit therefore uses dynamic text/text-background semantic colors without
-- waiting for an application event; syntax layers use the reported scheme.
codeEditorBaseStyle :: TextStyle
codeEditorBaseStyle =
  mempty
    { textFontFamily = Just MonospaceFont
    , textFontSize = Just 13
    , textFontWeight = Just Regular
    , textFontSlant = Just Upright
    }

haskellSyntaxLayer :: ColorScheme -> TextRevision -> Text -> TextLayer
haskellSyntaxLayer scheme revision source =
  TextLayer
    { textLayerKey = syntaxLayerKey
    , textLayerRevision = revision
    , textLayerSpans = fmap (fmap (syntaxStyle scheme)) (highlightHaskell source)
    }

syntaxStyle :: ColorScheme -> SyntaxClass -> TextStyle
syntaxStyle scheme syntaxClass =
  case syntaxClass of
    SyntaxKeyword ->
      mempty
        { textForeground = Just (schemeColor scheme (RGBA 0.48 0.18 0.58 1) (RGBA 0.78 0.54 0.88 1))
        , textFontWeight = Just SemiBold
        }
    SyntaxComment ->
      mempty
        { textForeground = Just (schemeColor scheme (RGBA 0.18 0.43 0.24 1) (RGBA 0.42 0.72 0.48 1))
        , textFontSlant = Just Italic
        }
    SyntaxString ->
      mempty {textForeground = Just (schemeColor scheme (RGBA 0.72 0.16 0.18 1) (RGBA 0.94 0.48 0.45 1))}
    SyntaxCharacter ->
      mempty {textForeground = Just (schemeColor scheme (RGBA 0.72 0.16 0.18 1) (RGBA 0.94 0.48 0.45 1))}
    SyntaxNumber ->
      mempty {textForeground = Just (schemeColor scheme (RGBA 0.12 0.30 0.72 1) (RGBA 0.48 0.68 0.96 1))}
    SyntaxTypeName ->
      mempty {textForeground = Just (schemeColor scheme (RGBA 0.02 0.42 0.52 1) (RGBA 0.40 0.78 0.86 1))}
    SyntaxOperator ->
      mempty {textForeground = Just (schemeColor scheme (RGBA 0.64 0.30 0.08 1) (RGBA 0.90 0.64 0.36 1))}

schemeColor :: ColorScheme -> Color -> Color -> Color
schemeColor scheme light dark =
  case scheme of
    LightColorScheme -> light
    DarkColorScheme -> dark

highlightHaskell :: Text -> [TextSpan SyntaxClass]
highlightHaskell = go 0 . Text.unpack
  where
    go _ [] = []
    go offset characters@(first : rest)
      | "--" `prefixOf` characters =
          emit offset SyntaxComment (takeUntilLineEnd characters)
      | "{-" `prefixOf` characters =
          emit offset SyntaxComment (blockCommentLength characters)
      | first == '"' =
          emit offset SyntaxString (quotedLength '"' characters)
      | first == '\''
      , Just lengthOfCharacter <- characterLiteralLength characters =
          emit offset SyntaxCharacter lengthOfCharacter
      | isDigit first =
          emit offset SyntaxNumber (tokenLength isNumberCharacter characters)
      | isIdentifierStart first =
          let lengthOfIdentifier = tokenLength isIdentifierContinue characters
              identifier = take lengthOfIdentifier characters
              syntaxClass
                | identifier `elem` haskellKeywords = Just SyntaxKeyword
                | isUpper first = Just SyntaxTypeName
                | otherwise = Nothing
           in maybe
                (go (offset + lengthOfIdentifier) (drop lengthOfIdentifier characters))
                (\classification -> emit offset classification lengthOfIdentifier)
                syntaxClass
      | isOperatorCharacter first =
          emit offset SyntaxOperator (tokenLength isOperatorCharacter characters)
      | isSpace first = go (offset + 1) rest
      | otherwise = go (offset + 1) rest
      where
        emit start classification lengthOfToken =
          TextSpan
            { textSpanRange = TextRange start lengthOfToken
            , textSpanValue = classification
            }
            : go
                (start + lengthOfToken)
                (drop lengthOfToken characters)

isIdentifierStart :: Char -> Bool
isIdentifierStart character = isAlpha character || character == '_'

isIdentifierContinue :: Char -> Bool
isIdentifierContinue character =
  isAlphaNum character || character == '_' || character == '\''

isNumberCharacter :: Char -> Bool
isNumberCharacter character =
  isAlphaNum character || character `elem` ("._" :: String)

isOperatorCharacter :: Char -> Bool
isOperatorCharacter character =
  character `elem` ("!#$%&*+./<=>?@\\^|-~:" :: String)

tokenLength :: (Char -> Bool) -> String -> Int
tokenLength predicate = length . takeWhile predicate

takeUntilLineEnd :: String -> Int
takeUntilLineEnd = length . takeWhile (/= '\n')

quotedLength :: Char -> String -> Int
quotedLength quote = walk 0 False
  where
    walk consumed _ [] = consumed
    walk consumed escaped (character : rest)
      | consumed > 0 && not escaped && character == quote = consumed + 1
      | consumed > 0 && not escaped && character == '\n' = consumed
      | escaped = walk (consumed + 1) False rest
      | character == '\\' = walk (consumed + 1) True rest
      | otherwise = walk (consumed + 1) False rest

characterLiteralLength :: String -> Maybe Int
characterLiteralLength characters =
  let lengthOfLiteral = quotedLength '\'' characters
      literal = take lengthOfLiteral characters
   in if lengthOfLiteral >= 3 && not (null literal) && last literal == '\''
        then Just lengthOfLiteral
        else Nothing

blockCommentLength :: String -> Int
blockCommentLength = walk 0 0
  where
    walk _ consumed [] = consumed
    walk depth consumed characters
      | "{-" `prefixOf` characters = walk (depth + 1) (consumed + 2) (drop 2 characters)
      | "-}" `prefixOf` characters =
          if depth <= 1
            then consumed + 2
            else walk (depth - 1) (consumed + 2) (drop 2 characters)
      | otherwise = walk depth (consumed + 1) (drop 1 characters)

prefixOf :: String -> String -> Bool
prefixOf expected actual = take (length expected) actual == expected

haskellKeywords :: [String]
haskellKeywords =
  [ "as"
  , "case"
  , "class"
  , "data"
  , "default"
  , "deriving"
  , "do"
  , "else"
  , "family"
  , "foreign"
  , "hiding"
  , "if"
  , "import"
  , "in"
  , "infix"
  , "infixl"
  , "infixr"
  , "instance"
  , "let"
  , "mdo"
  , "module"
  , "newtype"
  , "of"
  , "pattern"
  , "qualified"
  , "role"
  , "safe"
  , "then"
  , "type"
  , "unsafe"
  , "via"
  , "where"
  ]
