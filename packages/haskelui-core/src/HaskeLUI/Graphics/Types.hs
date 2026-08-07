{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedRecordDot #-}

-- | Backend-neutral geometry, colour, and typography values shared by
-- controls and drawing surfaces.
module HaskeLUI.Graphics.Types
  ( Rect (..)
  , Color (..)
  , ColorScheme (..)
  , FontFamily (..)
  , FontWeight (..)
  , FontSlant (..)
  , UnderlineStyle (..)
  , TextStyle (..)
  ) where

import Control.Applicative ((<|>))
import Data.Text (Text)

data Rect = Rect
  { rectX :: !Double
  , rectY :: !Double
  , rectWidth :: !Double
  , rectHeight :: !Double
  }
  deriving stock (Eq, Show)

data Color = RGBA
  { colorRed :: !Double
  , colorGreen :: !Double
  , colorBlue :: !Double
  , colorAlpha :: !Double
  }
  deriving stock (Eq, Show)

-- | The light/dark color scheme selected by the host environment. This is
-- deliberately independent from an application's named theme: a theme may
-- provide one palette for each system scheme.
data ColorScheme
  = LightColorScheme
  | DarkColorScheme
  deriving stock (Eq, Ord, Show)

data FontFamily
  = SystemFont
  | MonospaceFont
  | NamedFont !Text
  deriving stock (Eq, Show)

data FontWeight
  = Thin
  | ExtraLight
  | Light
  | Regular
  | Medium
  | SemiBold
  | Bold
  | ExtraBold
  | Black
  deriving stock (Eq, Ord, Show)

data FontSlant
  = Upright
  | Italic
  | Oblique
  deriving stock (Eq, Ord, Show)

data UnderlineStyle
  = UnderlineNone
  | UnderlineSingle
  | UnderlineDouble
  | UnderlineThick
  | UnderlineDotted
  | UnderlineDashed
  | UnderlineWavy
  deriving stock (Eq, Ord, Show)

-- | Partial portable inline styling. 'Nothing' leaves the corresponding
-- property at its inherited or platform-default value.
data TextStyle = TextStyle
  { textForeground :: !(Maybe Color)
  , textBackground :: !(Maybe Color)
  , textFontFamily :: !(Maybe FontFamily)
  , textFontSize :: !(Maybe Double)
  , textFontWeight :: !(Maybe FontWeight)
  , textFontSlant :: !(Maybe FontSlant)
  , textUnderline :: !(Maybe UnderlineStyle)
  , textUnderlineColor :: !(Maybe Color)
  , textStrikethrough :: !(Maybe Bool)
  , textLetterSpacing :: !(Maybe Double)
  , textBaselineOffset :: !(Maybe Double)
  }
  deriving stock (Eq, Show)

-- Later layers override earlier layers one property at a time.
instance Semigroup TextStyle where
  earlier <> later =
    TextStyle
      { textForeground = later.textForeground <|> earlier.textForeground
      , textBackground = later.textBackground <|> earlier.textBackground
      , textFontFamily = later.textFontFamily <|> earlier.textFontFamily
      , textFontSize = later.textFontSize <|> earlier.textFontSize
      , textFontWeight = later.textFontWeight <|> earlier.textFontWeight
      , textFontSlant = later.textFontSlant <|> earlier.textFontSlant
      , textUnderline = later.textUnderline <|> earlier.textUnderline
      , textUnderlineColor = later.textUnderlineColor <|> earlier.textUnderlineColor
      , textStrikethrough = later.textStrikethrough <|> earlier.textStrikethrough
      , textLetterSpacing = later.textLetterSpacing <|> earlier.textLetterSpacing
      , textBaselineOffset = later.textBaselineOffset <|> earlier.textBaselineOffset
      }

instance Monoid TextStyle where
  mempty =
    TextStyle
      { textForeground = Nothing
      , textBackground = Nothing
      , textFontFamily = Nothing
      , textFontSize = Nothing
      , textFontWeight = Nothing
      , textFontSlant = Nothing
      , textUnderline = Nothing
      , textUnderlineColor = Nothing
      , textStrikethrough = Nothing
      , textLetterSpacing = Nothing
      , textBaselineOffset = Nothing
      }
