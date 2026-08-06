{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TupleSections #-}

module VisualHaskell.TextMate.Grammar
  ( CaptureRule (..)
  , Grammar (..)
  , GrammarError (..)
  , Rule (..)
  , grammarRuleCount
  , loadGrammar
  , parseGrammarValue
  ) where

import Data.Aeson
  ( FromJSON (..)
  , Object
  , Value (..)
  , withObject
  , (.:)
  , (.:?)
  , (.!=)
  )
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KeyMap
import Data.Aeson.Types (Parser, parseEither)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (catMaybes)
import Data.Text (Text)
import qualified Data.Text as Text
import Text.Read (readMaybe)
import VisualHaskell.TextMate.Format (readStructuredFile)
import VisualHaskell.TextMate.Types
  ( ScopeName (..)
  )

data Grammar = Grammar
  { grammarDisplayName :: !(Maybe Text)
  , grammarRootScope :: !ScopeName
  , grammarFileTypes :: ![Text]
  , grammarPatterns :: ![Rule]
  , grammarRepository :: !(Map Text Rule)
  , grammarInjections :: !(Map Text Rule)
  }
  deriving stock (Eq, Show)

data Rule = Rule
  { ruleName :: !(Maybe ScopeName)
  , ruleContentName :: !(Maybe ScopeName)
  , ruleMatch :: !(Maybe Text)
  , ruleBegin :: !(Maybe Text)
  , ruleEnd :: !(Maybe Text)
  , ruleWhile :: !(Maybe Text)
  , ruleInclude :: !(Maybe Text)
  , rulePatterns :: ![Rule]
  , ruleCaptures :: !(Map Int CaptureRule)
  , ruleBeginCaptures :: !(Map Int CaptureRule)
  , ruleEndCaptures :: !(Map Int CaptureRule)
  , ruleWhileCaptures :: !(Map Int CaptureRule)
  , ruleRepository :: !(Map Text Rule)
  , ruleApplyEndPatternLast :: !Bool
  }
  deriving stock (Eq, Show)

data CaptureRule = CaptureRule
  { captureRuleName :: !(Maybe ScopeName)
  , captureRulePatterns :: ![Rule]
  }
  deriving stock (Eq, Show)

data GrammarError = GrammarError
  { grammarErrorPath :: !FilePath
  , grammarErrorMessage :: !Text
  }
  deriving stock (Eq, Show)

loadGrammar :: Int -> Int -> FilePath -> IO (Either GrammarError Grammar)
loadGrammar maximumBytes maximumRules path = do
  decoded <- readStructuredFile maximumBytes path
  pure $ do
    value <- mapLeft (GrammarError path) decoded
    grammar <- mapLeft (GrammarError path . Text.pack) (parseGrammarValue value)
    let count = grammarRuleCount grammar
    if count > max 1 maximumRules
      then
        Left
          ( GrammarError
              path
              ( "Grammar contains "
                  <> Text.pack (show count)
                  <> " rules, above the configured limit"
              )
          )
      else Right grammar

parseGrammarValue :: Value -> Either String Grammar
parseGrammarValue = parseEither parseJSON

instance FromJSON Grammar where
  parseJSON = withObject "TextMate grammar" $ \object ->
    Grammar
      <$> object .:? "name"
      <*> (ScopeName <$> object .: "scopeName")
      <*> object .:? "fileTypes" .!= []
      <*> object .:? "patterns" .!= []
      <*> parseRuleMapField object "repository"
      <*> parseRuleMapField object "injections"

instance FromJSON Rule where
  parseJSON = withObject "TextMate rule" $ \object -> do
    captures <- parseCaptureMapField object "captures"
    beginCaptures <- parseCaptureMapField object "beginCaptures"
    endCaptures <- parseCaptureMapField object "endCaptures"
    whileCaptures <- parseCaptureMapField object "whileCaptures"
    applyEndPatternLast <- (== Just (1 :: Int)) <$> object .:? "applyEndPatternLast"
    Rule
      <$> fmap (fmap ScopeName) (object .:? "name")
      <*> fmap (fmap ScopeName) (object .:? "contentName")
      <*> object .:? "match"
      <*> object .:? "begin"
      <*> object .:? "end"
      <*> object .:? "while"
      <*> object .:? "include"
      <*> object .:? "patterns" .!= []
      <*> pure captures
      <*> pure (if Map.null beginCaptures then captures else beginCaptures)
      <*> pure (if Map.null endCaptures then captures else endCaptures)
      <*> pure (if Map.null whileCaptures then captures else whileCaptures)
      <*> parseRuleMapField object "repository"
      <*> pure applyEndPatternLast

instance FromJSON CaptureRule where
  parseJSON = withObject "TextMate capture" $ \object ->
    CaptureRule
      <$> fmap (fmap ScopeName) (object .:? "name")
      <*> object .:? "patterns" .!= []

parseRuleMapField :: Object -> Key.Key -> Parser (Map Text Rule)
parseRuleMapField object field = do
  nested <- object .:? field
  case nested of
    Nothing -> pure Map.empty
    Just values -> parseRuleMap values

parseRuleMap :: Object -> Parser (Map Text Rule)
parseRuleMap object =
  Map.fromList
    <$> traverse
      (\(key, value) -> (Key.toText key,) <$> parseJSON value)
      (KeyMap.toList object)

parseCaptureMapField :: Object -> Key.Key -> Parser (Map Int CaptureRule)
parseCaptureMapField object field = do
  nested <- object .:? field
  case nested of
    Nothing -> pure Map.empty
    Just values -> fmap Map.fromList . fmap catMaybes . traverse parseEntry $ KeyMap.toList values
  where
    parseEntry (key, value) =
      case readMaybe (Text.unpack (Key.toText key)) of
        Nothing -> pure Nothing
        Just index -> Just . (index,) <$> parseJSON value

grammarRuleCount :: Grammar -> Int
grammarRuleCount grammar =
  sum (fmap countRule grammar.grammarPatterns)
    + sum (fmap countRule (Map.elems grammar.grammarRepository))
    + sum (fmap countRule (Map.elems grammar.grammarInjections))
  where
    countRule :: Rule -> Int
    countRule rule =
      1
        + sum (fmap countRule rule.rulePatterns)
        + sum (fmap countRule (Map.elems rule.ruleRepository))
        + sum
          [ sum (fmap (sum . fmap countRule . captureRulePatterns) (Map.elems captures))
          | captures <-
              [ rule.ruleCaptures
              , rule.ruleBeginCaptures
              , rule.ruleEndCaptures
              , rule.ruleWhileCaptures
              ]
          ]

mapLeft :: (left -> other) -> Either left right -> Either other right
mapLeft change = either (Left . change) Right
