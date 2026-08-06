{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TupleSections #-}

module VisualHaskell.TextMate.Tokenizer
  ( TokenizedDocument
  , Tokenizer
  , TokenizerError (..)
  , newTokenizer
  , tokenizeIncremental
  , tokenizedSnapshot
  ) where

import Control.Applicative ((<|>))
import qualified Data.ByteString as ByteString
import Data.IORef
  ( IORef
  , atomicModifyIORef'
  , newIORef
  , readIORef
  )
import Data.List
  ( find
  , minimumBy
  )
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe
  ( catMaybes
  , fromMaybe
  , isJust
  )
import Data.Ord (comparing)
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import HaskeLUI.Core
  ( TextRange (..)
  , TextRevision
  )
import VisualHaskell.TextMate.Grammar
import VisualHaskell.TextMate.Oniguruma
import VisualHaskell.TextMate.Types

data Tokenizer = Tokenizer
  { tokenizerRegexCache :: !(IORef (Map Text (Either RegexError CompiledRegex)))
  , tokenizerMaximumMatchesPerLine :: !Int
  }

newtype TokenizerError = TokenizerError {unTokenizerError :: Text}
  deriving stock (Eq, Show)

data RuleFrame = RuleFrame
  { frameRule :: !Rule
  , frameEndPattern :: !(Maybe Text)
  , frameWhilePattern :: !(Maybe Text)
  }
  deriving stock (Eq, Show)

data TokenizedLine = TokenizedLine
  { tokenizedLineText :: !Text
  , tokenizedLineIncoming :: ![RuleFrame]
  , tokenizedLineSpans :: ![ScopeSpan]
  , tokenizedLineOutgoing :: ![RuleFrame]
  }
  deriving stock (Eq, Show)

data TokenizedDocument = TokenizedDocument
  { tokenizedDocumentRevision :: !TextRevision
  , tokenizedDocumentHash :: !ContentHash
  , tokenizedDocumentRootScope :: !ScopeName
  , tokenizedDocumentLines :: ![TokenizedLine]
  }
  deriving stock (Eq, Show)

data CandidateKind
  = EndCandidate !RuleFrame
  | MatchCandidate !Rule
  | BeginCandidate !Rule
  deriving stock (Eq, Show)

data Candidate = Candidate
  { candidateOrder :: !Int
  , candidateKind :: !CandidateKind
  , candidateMatch :: !Match
  }
  deriving stock (Eq, Show)

newTokenizer :: Int -> IO Tokenizer
newTokenizer maximumMatches =
  Tokenizer
    <$> newIORef Map.empty
    <*> pure (max 32 maximumMatches)

tokenizeIncremental
  :: Tokenizer
  -> Grammar
  -> HighlightSnapshot
  -> Maybe TokenizedDocument
  -> IO (Either TokenizerError TokenizedDocument)
tokenizeIncremental tokenizer grammar snapshot previous = do
  let lineTexts = splitLinesPreservingTerminators snapshot.highlightText
      reusable =
        case previous of
          Just old
            | old.tokenizedDocumentRootScope == grammar.grammarRootScope ->
                commonPrefixLines lineTexts old.tokenizedDocumentLines
          _ -> []
      incoming = maybe [] (.tokenizedLineOutgoing) (lastMaybe reusable)
      startIndex = length reusable
  remaining <- tokenizeRemaining startIndex incoming lineTexts reusable
  pure $ do
    linesResult <- remaining
    Right
      TokenizedDocument
        { tokenizedDocumentRevision = snapshot.highlightRevision
        , tokenizedDocumentHash = snapshot.highlightContentHash
        , tokenizedDocumentRootScope = grammar.grammarRootScope
        , tokenizedDocumentLines = linesResult
        }
  where
    oldLines = maybe [] (.tokenizedDocumentLines) previous

    tokenizeRemaining index incoming lineTexts accumulated
      | index >= length lineTexts = pure (Right accumulated)
      | canReuseSuffix index incoming lineTexts oldLines =
          pure (Right (accumulated <> drop index oldLines))
      | otherwise = do
          result <- tokenizeLine tokenizer grammar incoming (lineTexts !! index)
          case result of
            Left failure -> pure (Left failure)
            Right line ->
              tokenizeRemaining
                (index + 1)
                line.tokenizedLineOutgoing
                lineTexts
                (accumulated <> [line])

tokenizedSnapshot :: TokenizedDocument -> TokenizedSnapshot
tokenizedSnapshot document =
  TokenizedSnapshot
    { tokenizedRevision = document.tokenizedDocumentRevision
    , tokenizedContentHash = document.tokenizedDocumentHash
    , tokenizedSpans = mergeAdjacentScopeSpans (collect 0 document.tokenizedDocumentLines)
    }
  where
    collect :: Int -> [TokenizedLine] -> [ScopeSpan]
    collect _ [] = []
    collect offset (line : remaining) =
      fmap (offsetSpan offset) line.tokenizedLineSpans
        <> collect (offset + Text.length line.tokenizedLineText) remaining
    offsetSpan :: Int -> ScopeSpan -> ScopeSpan
    offsetSpan offset scopeSpan =
      scopeSpan
        { scopeSpanRange =
            scopeSpan.scopeSpanRange
              { textRangeStart = scopeSpan.scopeSpanRange.textRangeStart + offset
              }
        }

tokenizeLine
  :: Tokenizer
  -> Grammar
  -> [RuleFrame]
  -> Text
  -> IO (Either TokenizerError TokenizedLine)
tokenizeLine tokenizer grammar incoming lineText = do
  let bytes = TextEncoding.encodeUtf8 lineText
      boundaries = scalarBoundaries lineText
  prepared <- applyWhileRules tokenizer bytes incoming
  case prepared of
    Left failure -> pure (Left failure)
    Right (frames, whileSpans) -> do
      result <- walk bytes boundaries frames 0 0 whileSpans
      pure $ do
        (spans, outgoing) <- result
        Right
          TokenizedLine
            { tokenizedLineText = lineText
            , tokenizedLineIncoming = incoming
            , tokenizedLineSpans = mergeAdjacentScopeSpans spans
            , tokenizedLineOutgoing = outgoing
            }
  where
    walk bytes boundaries frames byteOffset iteration spans
      | byteOffset >= ByteString.length bytes =
          pure (Right (spans, frames))
      | iteration >= tokenizer.tokenizerMaximumMatchesPerLine =
          pure
            ( Left
                ( TokenizerError
                    ( "TextMate grammar exceeded the per-line match limit in scope "
                        <> grammar.grammarRootScope.unScopeName
                    )
                )
            )
      | otherwise = do
          next <- nextCandidate tokenizer grammar bytes frames byteOffset
          case next of
            Left failure -> pure (Left failure)
            Right Nothing ->
              pure
                ( Right
                    ( spans
                        <> scopeSpanFromBytes
                          boundaries
                          byteOffset
                          (ByteString.length bytes)
                          (contentScopes grammar frames)
                    , frames
                    )
                )
            Right (Just candidate) -> do
              let matched = candidate.candidateMatch
                  leading =
                    scopeSpanFromBytes
                      boundaries
                      byteOffset
                      matched.matchByteStart
                      (contentScopes grammar frames)
                  (newFrames, matchScopes, captureRules) =
                    applyCandidate grammar bytes frames candidate
                  matchedSpans =
                    scopeSpanFromBytes
                      boundaries
                      matched.matchByteStart
                      matched.matchByteEnd
                      matchScopes
                  captureSpans =
                    capturesToSpans
                      boundaries
                      matchScopes
                      captureRules
                      matched.matchCaptures
                  nextOffset
                    | matched.matchByteEnd > byteOffset = matched.matchByteEnd
                    | newFrames /= frames = byteOffset
                    | otherwise = nextUtf8Boundary boundaries byteOffset
              walk
                bytes
                boundaries
                newFrames
                nextOffset
                (iteration + 1)
                (spans <> leading <> matchedSpans <> captureSpans)

nextCandidate
  :: Tokenizer
  -> Grammar
  -> ByteString.ByteString
  -> [RuleFrame]
  -> Int
  -> IO (Either TokenizerError (Maybe Candidate))
nextCandidate tokenizer grammar bytes frames startOffset = do
  endCandidate <-
    case lastMaybe frames >>= (\frame -> (,frame) <$> frame.frameEndPattern) of
      Nothing -> pure (Right Nothing)
      Just (patternSource, frame) ->
        fmap (fmap (fmap (Candidate endOrder (EndCandidate frame))))
          (search tokenizer patternSource bytes startOffset)
  patternCandidates <-
    traverse
      (\(order, rule) -> candidateForRule tokenizer bytes startOffset order rule)
      (zip [0 ..] (eligibleRules grammar frames))
  pure $ do
    end <- endCandidate
    patterns <- sequence patternCandidates
    let candidates = catMaybes (end : patterns)
    Right
      ( case candidates of
          [] -> Nothing
          _ -> Just (minimumBy compareCandidates candidates)
      )
  where
    topApplyEndLast = maybe False (.frameRule.ruleApplyEndPatternLast) (lastMaybe frames)
    endOrder = if topApplyEndLast then maxBound else -1

compareCandidates :: Candidate -> Candidate -> Ordering
compareCandidates left right =
  comparing (.candidateMatch.matchByteStart) left right
    <> comparing (.candidateOrder) left right

candidateForRule
  :: Tokenizer
  -> ByteString.ByteString
  -> Int
  -> Int
  -> Rule
  -> IO (Either TokenizerError (Maybe Candidate))
candidateForRule tokenizer bytes startOffset order rule =
  case (rule.ruleMatch, rule.ruleBegin) of
    (Just patternSource, _) ->
      fmap (fmap (fmap (Candidate order (MatchCandidate rule))))
        (search tokenizer patternSource bytes startOffset)
    (_, Just patternSource) ->
      fmap (fmap (fmap (Candidate order (BeginCandidate rule))))
        (search tokenizer patternSource bytes startOffset)
    _ -> pure (Right Nothing)

search
  :: Tokenizer
  -> Text
  -> ByteString.ByteString
  -> Int
  -> IO (Either TokenizerError (Maybe Match))
search tokenizer patternSource bytes offset = do
  compiled <- compiledRegex tokenizer patternSource
  case compiled of
    Left errorValue -> pure (Left (TokenizerError errorValue.unRegexError))
    Right regex -> fmap (mapLeft (TokenizerError . (.unRegexError))) (searchRegex regex bytes offset)

compiledRegex :: Tokenizer -> Text -> IO (Either RegexError CompiledRegex)
compiledRegex tokenizer source = do
  cached <- readIORef tokenizer.tokenizerRegexCache
  case Map.lookup source cached of
    Just result -> pure result
    Nothing -> do
      result <- compileRegex source
      atomicModifyIORef' tokenizer.tokenizerRegexCache $ \current ->
        (Map.insert source result current, ())
      pure result

eligibleRules :: Grammar -> [RuleFrame] -> [Rule]
eligibleRules grammar frames =
  expandRules grammar repositories Set.empty patterns
  where
    patterns = maybe grammar.grammarPatterns (.frameRule.rulePatterns) (lastMaybe frames)
    repositories =
      reverse (fmap (.frameRule.ruleRepository) frames)
        <> [grammar.grammarRepository]

expandRules
  :: Grammar
  -> [Map Text Rule]
  -> Set Text
  -> [Rule]
  -> [Rule]
expandRules grammar repositories visited = concatMap expand
  where
    expand rule =
      case rule.ruleInclude of
        Just include@"$self"
          | Set.notMember include visited ->
              expandRules grammar repositories (Set.insert include visited) grammar.grammarPatterns
        Just include@"$base"
          | Set.notMember include visited ->
              expandRules grammar repositories (Set.insert include visited) grammar.grammarPatterns
        Just include
          | Just name <- Text.stripPrefix "#" include
          , Set.notMember name visited
          , Just referenced <- firstMapLookup name repositories ->
              expandRules grammar repositories (Set.insert name visited) [referenced]
        Just _ -> []
        Nothing
          | isExecutableRule rule -> [rule]
          | otherwise ->
              expandRules
                grammar
                (rule.ruleRepository : repositories)
                visited
                rule.rulePatterns

isExecutableRule :: Rule -> Bool
isExecutableRule rule = isJust rule.ruleMatch || isJust rule.ruleBegin

firstMapLookup :: Ord key => key -> [Map key value] -> Maybe value
firstMapLookup _ [] = Nothing
firstMapLookup key (values : remaining) =
  Map.lookup key values <|> firstMapLookup key remaining

applyCandidate
  :: Grammar
  -> ByteString.ByteString
  -> [RuleFrame]
  -> Candidate
  -> ([RuleFrame], ScopeStack, Map Int CaptureRule)
applyCandidate grammar bytes frames candidate =
  case candidate.candidateKind of
    MatchCandidate rule ->
      ( frames
      , appendScope rule.ruleName (contentScopes grammar frames)
      , rule.ruleCaptures
      )
    BeginCandidate rule ->
      let endPattern = fmap (substituteBackReferences bytes candidate.candidateMatch) rule.ruleEnd
          whilePattern = fmap (substituteBackReferences bytes candidate.candidateMatch) rule.ruleWhile
          frame = RuleFrame rule endPattern whilePattern
       in ( frames <> [frame]
          , appendScope rule.ruleName (contentScopes grammar frames)
          , rule.ruleBeginCaptures
          )
    EndCandidate frame ->
      ( dropLast frames
      , delimiterScopes grammar frames
      , frame.frameRule.ruleEndCaptures
      )

contentScopes :: Grammar -> [RuleFrame] -> ScopeStack
contentScopes grammar frames =
  ScopeStack
    ( grammar.grammarRootScope
        : concatMap
          (\frame -> catMaybes [frame.frameRule.ruleName, frame.frameRule.ruleContentName])
          frames
    )

delimiterScopes :: Grammar -> [RuleFrame] -> ScopeStack
delimiterScopes grammar frames =
  case unsnoc frames of
    Nothing -> contentScopes grammar []
    Just (outer, frame) -> appendScope frame.frameRule.ruleName (contentScopes grammar outer)

appendScope :: Maybe ScopeName -> ScopeStack -> ScopeStack
appendScope Nothing scopes = scopes
appendScope (Just scope) (ScopeStack scopes) = ScopeStack (scopes <> [scope])

capturesToSpans
  :: Map Int Int
  -> ScopeStack
  -> Map Int CaptureRule
  -> [Capture]
  -> [ScopeSpan]
capturesToSpans boundaries parentScopes rules = concatMap captureSpan
  where
    captureSpan :: Capture -> [ScopeSpan]
    captureSpan capture =
      case Map.lookup capture.captureIndex rules of
        Nothing -> []
        Just captureRule ->
          scopeSpanFromBytes
            boundaries
            capture.captureByteStart
            capture.captureByteEnd
            (appendScope captureRule.captureRuleName parentScopes)

scopeSpanFromBytes
  :: Map Int Int
  -> Int
  -> Int
  -> ScopeStack
  -> [ScopeSpan]
scopeSpanFromBytes boundaries byteStart byteEnd scopes =
  case (Map.lookup byteStart boundaries, Map.lookup byteEnd boundaries) of
    (Just scalarStart, Just scalarEnd)
      | scalarEnd > scalarStart ->
          [ScopeSpan (TextRange scalarStart (scalarEnd - scalarStart)) scopes]
    _ -> []

scalarBoundaries :: Text -> Map Int Int
scalarBoundaries source =
  Map.fromList (scan 0 0 (Text.unpack source))
  where
    scan byteOffset scalarOffset [] = [(byteOffset, scalarOffset)]
    scan byteOffset scalarOffset (character : remaining) =
      (byteOffset, scalarOffset)
        : scan
          (byteOffset + ByteString.length (TextEncoding.encodeUtf8 (Text.singleton character)))
          (scalarOffset + 1)
          remaining

nextUtf8Boundary :: Map Int Int -> Int -> Int
nextUtf8Boundary boundaries current =
  fromMaybe current
    (fst <$> find ((> current) . fst) (Map.toAscList boundaries))

substituteBackReferences :: ByteString.ByteString -> Match -> Text -> Text
substituteBackReferences bytes matched source =
  foldl'
    ( \result capture ->
        Text.replace
          ("\\" <> Text.pack (show capture.captureIndex))
          (regexEscape (captureText capture))
          result
    )
    source
    (reverse matched.matchCaptures)
  where
    captureText :: Capture -> Text
    captureText capture =
      TextEncoding.decodeUtf8With
        (\_ _ -> Just '\xfffd')
        ( ByteString.take
            (capture.captureByteEnd - capture.captureByteStart)
            (ByteString.drop capture.captureByteStart bytes)
        )

regexEscape :: Text -> Text
regexEscape = Text.concatMap escape
  where
    escape character
      | character `elem` ("\\.^$|?*+()[]{}-" :: String) = Text.pack ['\\', character]
      | otherwise = Text.singleton character

applyWhileRules
  :: Tokenizer
  -> ByteString.ByteString
  -> [RuleFrame]
  -> IO (Either TokenizerError ([RuleFrame], [ScopeSpan]))
applyWhileRules tokenizer bytes = go
  where
    go :: [RuleFrame] -> IO (Either TokenizerError ([RuleFrame], [ScopeSpan]))
    go [] = pure (Right ([], []))
    go frames =
      case lastMaybe frames >>= (\frame -> (,frame) <$> frame.frameWhilePattern) of
        Nothing -> pure (Right (frames, []))
        Just (patternSource, _) -> do
          found <- search tokenizer patternSource bytes 0
          case found of
            Left failure -> pure (Left failure)
            Right (Just matchValue)
              | matchValue.matchByteStart == 0 -> pure (Right (frames, []))
            _ -> go (dropLast frames)

splitLinesPreservingTerminators :: Text -> [Text]
splitLinesPreservingTerminators source
  | Text.null source = [""]
  | otherwise = go source
  where
    go remaining =
      let (before, after) = Text.breakOn "\n" remaining
       in if Text.null after
            then [before]
            else
              let line = before <> "\n"
                  rest = Text.drop 1 after
               in line : if Text.null rest then [""] else go rest

commonPrefixLines :: [Text] -> [TokenizedLine] -> [TokenizedLine]
commonPrefixLines (new : newRest) (old : oldRest)
  | new == old.tokenizedLineText = old : commonPrefixLines newRest oldRest
commonPrefixLines _ _ = []

canReuseSuffix :: Int -> [RuleFrame] -> [Text] -> [TokenizedLine] -> Bool
canReuseSuffix index incoming newLines oldLines =
  case drop index oldLines of
    firstOld : _ ->
      incoming == firstOld.tokenizedLineIncoming
        && drop index newLines == fmap (.tokenizedLineText) (drop index oldLines)
    [] -> False

mergeAdjacentScopeSpans :: [ScopeSpan] -> [ScopeSpan]
mergeAdjacentScopeSpans = foldr merge []
  where
    merge current (next : remaining)
      | current.scopeSpanStack == next.scopeSpanStack
      , current.scopeSpanRange.textRangeStart + current.scopeSpanRange.textRangeLength
          == next.scopeSpanRange.textRangeStart =
          current
            { scopeSpanRange =
                current.scopeSpanRange
                  { textRangeLength =
                      current.scopeSpanRange.textRangeLength
                        + next.scopeSpanRange.textRangeLength
                  }
            }
            : remaining
    merge current remaining = current : remaining

dropLast :: [value] -> [value]
dropLast [] = []
dropLast values = init values

lastMaybe :: [value] -> Maybe value
lastMaybe [] = Nothing
lastMaybe values = Just (last values)

unsnoc :: [value] -> Maybe ([value], value)
unsnoc [] = Nothing
unsnoc values = Just (init values, last values)

mapLeft :: (left -> other) -> Either left right -> Either other right
mapLeft change = either (Left . change) Right
