{-# LANGUAGE OverloadedStrings #-}

module VisualHaskell.TextMate
  ( module VisualHaskell.TextMate.Grammar
  , module VisualHaskell.TextMate.Registry
  , module VisualHaskell.TextMate.Service
  , module VisualHaskell.TextMate.Theme
  , module VisualHaskell.TextMate.Tokenizer
  , module VisualHaskell.TextMate.Types
  , defaultTextMateConfiguration
  ) where

import System.FilePath ((</>))
import Paths_visual_haskell_textmate (getDataFileName)
import VisualHaskell.TextMate.Grammar
import VisualHaskell.TextMate.Registry
import VisualHaskell.TextMate.Service
import VisualHaskell.TextMate.Theme
import VisualHaskell.TextMate.Tokenizer
import VisualHaskell.TextMate.Types

defaultTextMateConfiguration :: FilePath -> IO TextMateConfiguration
defaultTextMateConfiguration userRoot = do
  bundledRoot <- getDataFileName "resources/extensions"
  pure
    TextMateConfiguration
      { bundledExtensionRoots = [bundledRoot]
      , userExtensionRoots = [userRoot </> "extensions"]
      , userGrammarRoots = [userRoot </> "grammars"]
      , userThemeRoots = [userRoot </> "themes"]
      , selectedTheme = Just (ThemeId "visual-haskell-light")
      , maximumGrammarBytes = 16 * 1024 * 1024
      , maximumThemeBytes = 8 * 1024 * 1024
      , maximumRuleCount = 50000
      , maximumMatchesPerLine = 20000
      }
