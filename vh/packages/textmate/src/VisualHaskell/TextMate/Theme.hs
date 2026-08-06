{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

module VisualHaskell.TextMate.Theme
  ( ScopeSelector (..)
  , TextMateTheme (..)
  , ThemeError (..)
  , ThemeRule (..)
  , fallbackTextMateTheme
  , loadTheme
  , parseScopeSelector
  , parseThemeValue
  , resolveScopeStyle
  , themeTextLayer
  ) where

import Data.Aeson
  ( Object
  , Value (..)
  , withObject
  , (.:?)
  , (.!=)
  )
import Data.Aeson.Types (Parser, parseEither)
import Data.List (sortOn)
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Vector as Vector
import Numeric (readHex)
import HaskeLUI.Core
  ( Color (..)
  , FontSlant (..)
  , FontWeight (..)
  , TextLayer (..)
  , TextLayerKey
  , TextRevision
  , TextSpan (..)
  , TextStyle (..)
  , UnderlineStyle (..)
  )
import VisualHaskell.TextMate.Format (readStructuredFile)
import VisualHaskell.TextMate.Types
  ( ScopeName (..)
  , ScopeSpan (..)
  , ScopeStack (..)
  , TokenizedSnapshot (..)
  )

fallbackTextMateTheme :: TextMateTheme
fallbackTextMateTheme =
  TextMateTheme
    { textMateThemeName = "Visual Haskell fallback"
    , textMateThemeDefaultStyle = mempty
    , textMateThemeRules = []
    }

data TextMateTheme = TextMateTheme
  { textMateThemeName :: !Text
  , textMateThemeDefaultStyle :: !TextStyle
  , textMateThemeRules :: ![ThemeRule]
  }
  deriving stock (Eq, Show)

data ThemeRule = ThemeRule
  { themeRuleSelectors :: ![ScopeSelector]
  , themeRuleStyle :: !TextStyle
  , themeRuleOrder :: !Int
  }
  deriving stock (Eq, Show)

data ScopeSelector = ScopeSelector
  { selectorRequiredScopes :: ![ScopeName]
  , selectorExcludedScopes :: ![ScopeName]
  }
  deriving stock (Eq, Show)

data ThemeError = ThemeError
  { themeErrorPath :: !FilePath
  , themeErrorMessage :: !Text
  }
  deriving stock (Eq, Show)

loadTheme :: Int -> FilePath -> IO (Either ThemeError TextMateTheme)
loadTheme maximumBytes path = do
  decoded <- readStructuredFile maximumBytes path
  pure $ do
    value <- mapLeft (ThemeError path) decoded
    mapLeft (ThemeError path . Text.pack) (parseThemeValue value)

parseThemeValue :: Value -> Either String TextMateTheme
parseThemeValue = parseEither parseTheme

parseTheme :: Value -> Parser TextMateTheme
parseTheme = withObject "TextMate theme" $ \object -> do
  name <- object .:? "name" .!= "TextMate theme"
  tokenColors <-
    object .:? "tokenColors"
      >>= maybe (object .:? "settings" .!= []) pure
  parsed <- traverse parseThemeEntry tokenColors
  let entries = zipWith (,) [0 ..] parsed
      defaultStyle = foldl' (<>) mempty [style | (_, ([], style)) <- entries]
      rules =
        [ ThemeRule selectors style order
        | (order, (selectors, style)) <- entries
        , not (null selectors)
        ]
  pure
    TextMateTheme
      { textMateThemeName = name
      , textMateThemeDefaultStyle = defaultStyle
      , textMateThemeRules = rules
      }

parseThemeEntry :: Value -> Parser ([ScopeSelector], TextStyle)
parseThemeEntry = withObject "TextMate theme rule" $ \object -> do
  selectors <- maybe (pure []) parseSelectorValue =<< object .:? "scope"
  settings <- object .:? "settings" .!= mempty
  style <- parseStyle settings
  pure (selectors, style)

parseSelectorValue :: Value -> Parser [ScopeSelector]
parseSelectorValue (String value) = pure (mapMaybe parseScopeSelector (Text.splitOn "," value))
parseSelectorValue (Array values) =
  fmap concat
    ( traverse
        (\case
          String value -> pure (mapMaybe parseScopeSelector (Text.splitOn "," value))
          _ -> fail "theme scope arrays must contain strings"
        )
        (Vector.toList values)
    )
parseSelectorValue _ = fail "theme scope must be a string or string array"

parseScopeSelector :: Text -> Maybe ScopeSelector
parseScopeSelector source
  | null required = Nothing
  | otherwise = Just (ScopeSelector (ScopeName <$> required) (ScopeName <$> excluded))
  where
    components = filter (not . Text.null) (Text.words (Text.strip source))
    (required, excluded) = collect False components [] []
    collect _ [] positive negative = (reverse positive, reverse negative)
    collect _ ("-" : rest) positive negative = collect True rest positive negative
    collect isNegative (component : rest) positive negative
      | Text.isPrefixOf "-" component =
          collect False rest positive (Text.drop 1 component : negative)
      | isNegative = collect False rest positive (component : negative)
      | otherwise = collect False rest (component : positive) negative

parseStyle :: Object -> Parser TextStyle
parseStyle settings = do
  foreground <- traverse parseColorValue =<< settings .:? "foreground"
  background <- traverse parseColorValue =<< settings .:? "background"
  fontStyle <- settings .:? "fontStyle"
  let styles = maybe [] (Text.words . Text.toLower) fontStyle
      explicitlyReset = fontStyle == Just ""
  pure
    mempty
      { textForeground = foreground
      , textBackground = background
      , textFontWeight =
          if "bold" `elem` styles
            then Just Bold
            else if explicitlyReset then Just Regular else Nothing
      , textFontSlant =
          if "italic" `elem` styles
            then Just Italic
            else if explicitlyReset then Just Upright else Nothing
      , textUnderline =
          if "underline" `elem` styles
            then Just UnderlineSingle
            else if explicitlyReset then Just UnderlineNone else Nothing
      , textStrikethrough =
          if "strikethrough" `elem` styles
            then Just True
            else if explicitlyReset then Just False else Nothing
      }

parseColorValue :: Text -> Parser Color
parseColorValue value =
  maybe (fail ("invalid theme color: " <> Text.unpack value)) pure (parseColor value)

parseColor :: Text -> Maybe Color
parseColor source =
  case Text.unpack (Text.dropWhile (== '#') (Text.strip source)) of
    [r, g, b] -> rgba [r, r, g, g, b, b, 'f', 'f']
    [r, g, b, a] -> rgba [r, r, g, g, b, b, a, a]
    digits@[_, _, _, _, _, _] -> rgba (digits <> "ff")
    digits@[_, _, _, _, _, _, _, _] -> rgba digits
    _ -> Nothing
  where
    rgba digits = do
      red <- hexByte (take 2 digits)
      green <- hexByte (take 2 (drop 2 digits))
      blue <- hexByte (take 2 (drop 4 digits))
      alpha <- hexByte (take 2 (drop 6 digits))
      pure
        ( RGBA
            (channel red)
            (channel green)
            (channel blue)
            (channel alpha)
        )
    hexByte digits = case readHex digits of
      [(value, "")] -> Just value
      _ -> Nothing
    channel value = fromIntegral (value :: Int) / 255

resolveScopeStyle :: TextMateTheme -> ScopeStack -> TextStyle
resolveScopeStyle theme (ScopeStack scopes) =
  foldl'
    (<>)
    theme.textMateThemeDefaultStyle
    [ rule.themeRuleStyle
    | (_, rule) <- sortOn fst matches
    ]
  where
    matches =
      [ ((specificity, rule.themeRuleOrder), rule)
      | rule <- theme.textMateThemeRules
      , selector <- rule.themeRuleSelectors
      , Just specificity <- [selectorSpecificity selector scopes]
      ]

selectorSpecificity :: ScopeSelector -> [ScopeName] -> Maybe Int
selectorSpecificity selector scopes
  | any (`matchesAnyScope` scopes) selector.selectorExcludedScopes = Nothing
  | otherwise = matchRequired (reverse selector.selectorRequiredScopes) (reverse scopes) 0
  where
    matchRequired [] _ score = Just score
    matchRequired _ [] _ = Nothing
    matchRequired required@(wanted : more) (actual : rest) score
      | scopeMatches wanted actual =
          matchRequired more rest (score + scopeSpecificity wanted)
      | otherwise = matchRequired required rest score

matchesAnyScope :: ScopeName -> [ScopeName] -> Bool
matchesAnyScope wanted = any (scopeMatches wanted)

scopeMatches :: ScopeName -> ScopeName -> Bool
scopeMatches (ScopeName wanted) (ScopeName actual) =
  wanted == actual || (wanted <> ".") `Text.isPrefixOf` actual

scopeSpecificity :: ScopeName -> Int
scopeSpecificity (ScopeName value) = Text.length value

themeTextLayer
  :: TextLayerKey
  -> TextRevision
  -> TextMateTheme
  -> TokenizedSnapshot
  -> TextLayer
themeTextLayer key revision theme snapshot =
  TextLayer
    { textLayerKey = key
    , textLayerRevision = revision
    , textLayerSpans =
        [ TextSpan scopeSpan.scopeSpanRange (resolveScopeStyle theme scopeSpan.scopeSpanStack)
        | scopeSpan <- snapshot.tokenizedSpans
        ]
    }

mapLeft :: (left -> other) -> Either left right -> Either other right
mapLeft change = either (Left . change) Right
