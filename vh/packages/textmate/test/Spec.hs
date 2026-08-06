{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Control.Monad (unless)
import qualified Data.Map.Strict as Map
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import HaskeLUI.Core
  ( DocumentKey (..)
  , TextLayer (..)
  , TextLayerKey (..)
  , TextRevision (..)
  )
import System.FilePath ((</>))
import VisualHaskell.TextMate
import VisualHaskell.TextMate.Oniguruma

main :: IO ()
main = do
  testOniguruma
  testPlistGrammar
  testBundledRegistryAndIncrementalTokenization
  putStrLn "Visual Haskell TextMate tests passed"

testOniguruma :: IO ()
testOniguruma = do
  version <- onigurumaVersion
  assert "vendored Oniguruma reports a version" (not (Text.null version))
  compiled <- requireRight "compile Unicode regular expression" =<< compileRegex "λ|[a-z]+"
  matched <- requireRight "run Unicode regular expression" =<< searchRegex compiled (TextEncoding.encodeUtf8 "λ value") 0
  case matched of
    Just value -> do
      assertEqual "Unicode match starts at byte zero" 0 value.matchByteStart
      assertEqual "Unicode match uses UTF-8 byte offsets" 2 value.matchByteEnd
    Nothing -> fail "Oniguruma did not match a Unicode subject"

testPlistGrammar :: IO ()
testPlistGrammar = do
  grammar <- requireRight "load XML plist grammar" =<< loadGrammar 100000 1000 fixturePath
  assertEqual "plist scope" (ScopeName "source.fixture") grammar.grammarRootScope
  assertEqual "plist pattern count" 1 (length grammar.grammarPatterns)
  where
    fixturePath = "test" </> "fixtures" </> "minimal.tmLanguage"

testBundledRegistryAndIncrementalTokenization :: IO ()
testBundledRegistryAndIncrementalTokenization = do
  configuration <- defaultTextMateConfiguration "/path/that/does/not/exist"
  registry <- loadProviderRegistry configuration
  let expectedLanguages = LanguageId <$> ["haskell", "javascript", "json", "markdown", "python"]
  mapM_
    (\identifier -> assert ("bundled language " <> show identifier) (Map.member identifier registry.registryLanguages))
    expectedLanguages
  assertEqual "bundled registry has no diagnostics" [] registry.registryDiagnostics
  mapM_
    (\(identity, identifier, path, source) ->
      testBundledGrammar configuration registry identity identifier path source
    )
    [ (2, LanguageId "javascript", "sample.js", "const value = \"hello\"; // comment\n")
    , (3, LanguageId "json", "sample.json", "{\"enabled\": true, \"count\": 3}\n")
    , (4, LanguageId "python", "sample.py", "def greet(name):\n    return f\"Hello {name}\"\n")
    , (5, LanguageId "markdown", "README.md", markdownFixture)
    ]

  testMarkdownScopes configuration registry

  grammarDescriptor <-
    maybe (fail "No bundled Haskell grammar") pure (grammarForLanguage registry (LanguageId "haskell"))
  grammar <-
    requireRight "load bundled Haskell grammar"
      =<< loadGrammar
        configuration.maximumGrammarBytes
        configuration.maximumRuleCount
        grammarDescriptor.grammarPath
  themeDescriptor <-
    maybe (fail "No bundled light theme") pure (themeForIdentifier registry (ThemeId "visual-haskell-light"))
  theme <- requireRight "load bundled light theme" =<< loadTheme configuration.maximumThemeBytes themeDescriptor.themePath

  tokenizer <- newTokenizer configuration.maximumMatchesPerLine
  let source1 = "module Main where\n\nvalue = \"hello\" -- comment\n"
      source2 = "module Main where\n\nvalue = \"hello!\" -- comment\n"
      snapshot1 = highlightSnapshot (DocumentKey 1) (TextRevision 1) "Main.hs" source1
      snapshot2 = highlightSnapshot (DocumentKey 1) (TextRevision 2) "Main.hs" source2
  document1 <- requireRight "tokenize initial Haskell" =<< tokenizeIncremental tokenizer grammar snapshot1 Nothing
  incremental <- requireRight "incrementally retokenize Haskell" =<< tokenizeIncremental tokenizer grammar snapshot2 (Just document1)
  freshTokenizer <- newTokenizer configuration.maximumMatchesPerLine
  fresh <- requireRight "fully retokenize edited Haskell" =<< tokenizeIncremental freshTokenizer grammar snapshot2 Nothing
  assertEqual "incremental and full tokenization agree" (tokenizedSnapshot fresh) (tokenizedSnapshot incremental)

  let tokenized = tokenizedSnapshot incremental
      layer = themeTextLayer (TextLayerKey 99) snapshot2.highlightRevision theme tokenized
  assert "tokenizer emits scoped spans" (not (null tokenized.tokenizedSpans))
  assert "theme produces styled spans" (not (null layer.textLayerSpans))
  assertEqual "theme layer is revision-bound" snapshot2.highlightRevision layer.textLayerRevision

markdownFixture :: Text.Text
markdownFixture =
  Text.unlines
    [ "# Visual Haskell"
    , ""
    , "- [x] **Native** and *typed* with [documentation](https://example.com)."
    , ""
    , "> A portable UI library."
    , ""
    , "```haskell"
    , "main = putStrLn \"hello\""
    , "```"
    ]

testMarkdownScopes :: TextMateConfiguration -> ProviderRegistry -> IO ()
testMarkdownScopes configuration registry = do
  descriptor <-
    maybe (fail "No bundled Markdown grammar") pure (grammarForLanguage registry (LanguageId "markdown"))
  grammar <-
    requireRight "load bundled Markdown grammar"
      =<< loadGrammar configuration.maximumGrammarBytes configuration.maximumRuleCount descriptor.grammarPath
  tokenizer <- newTokenizer configuration.maximumMatchesPerLine
  document <-
    requireRight "tokenize representative Markdown"
      =<< tokenizeIncremental
        tokenizer
        grammar
        (highlightSnapshot (DocumentKey 6) (TextRevision 1) "README.md" markdownFixture)
        Nothing
  let scopeNames =
        [ scopeName
        | scopeSpan <- (tokenizedSnapshot document).tokenizedSpans
        , scopeName <- unScopeStack scopeSpan.scopeSpanStack
        ]
      hasScope scope = ScopeName scope `elem` scopeNames
  mapM_
    (\(description, scope) -> assert ("Markdown recognizes " <> description) (hasScope scope))
    [ ("ATX headings", "markup.heading.atx.markdown")
    , ("task lists", "constant.language.task-list.markdown")
    , ("bold emphasis", "markup.bold.markdown")
    , ("italic emphasis", "markup.italic.markdown")
    , ("links", "markup.underline.link.markdown")
    , ("block quotes", "markup.quote.markdown")
    , ("fenced code", "markup.fenced_code.block.markdown")
    ]

testBundledGrammar
  :: TextMateConfiguration
  -> ProviderRegistry
  -> Word
  -> LanguageId
  -> FilePath
  -> Text.Text
  -> IO ()
testBundledGrammar configuration registry identity identifier path source = do
  descriptor <-
    maybe (fail ("No bundled grammar for " <> show identifier)) pure (grammarForLanguage registry identifier)
  grammar <-
    requireRight ("load bundled grammar " <> show identifier)
      =<< loadGrammar configuration.maximumGrammarBytes configuration.maximumRuleCount descriptor.grammarPath
  tokenizer <- newTokenizer configuration.maximumMatchesPerLine
  document <-
    requireRight ("tokenize bundled grammar " <> show identifier)
      =<< tokenizeIncremental
        tokenizer
        grammar
        (highlightSnapshot (DocumentKey (fromIntegral identity)) (TextRevision 1) path source)
        Nothing
  assert ("bundled grammar emits spans " <> show identifier) (not (null (tokenizedSnapshot document).tokenizedSpans))

assert :: String -> Bool -> IO ()
assert message condition = unless condition (fail message)

assertEqual :: (Eq value, Show value) => String -> value -> value -> IO ()
assertEqual message expected actual =
  assert (message <> ": expected " <> show expected <> ", got " <> show actual) (expected == actual)

requireRight :: Show failure => String -> Either failure value -> IO value
requireRight message = either (fail . ((message <> ": ") <>) . show) pure
