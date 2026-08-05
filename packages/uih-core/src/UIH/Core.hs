{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

module UIH.Core
  ( Action
  , App (..)
  , AppView (..)
  , AttributedText
  , Color (..)
  , CommandId (..)
  , CommandSpec (..)
  , Control (..)
  , Effect (..)
  , EffectKey (..)
  , ElementKey (..)
  , FontFamily (..)
  , FontSlant (..)
  , FontWeight (..)
  , Rect (..)
  , TextEditorSpec (..)
  , TextLayer (..)
  , TextLayerKey (..)
  , TextRange (..)
  , TextRevision (..)
  , TextRun (..)
  , TextSpan (..)
  , TextStyle (..)
  , Transaction (..)
  , UIEvent (..)
  , UnderlineStyle (..)
  , UndoGroup (..)
  , UndoPolicy (..)
  , WindowKey (..)
  , WindowSpec (..)
  , action
  , applyTransaction
  , attributedTextFromRuns
  , attributedTextFromSpans
  , attributedTextSpans
  , attributedTextToRuns
  , attributedTextValue
  , noTransaction
  , requestEffect
  , resolveTextLayers
  , transaction
  , transactionWithEffects
  ) where

import Control.Applicative ((<|>))
import Data.List (group, sort)
import Data.Maybe (listToMaybe, mapMaybe)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word64)

newtype WindowKey = WindowKey {unWindowKey :: Word64}
  deriving stock (Eq, Ord, Show)

newtype ElementKey = ElementKey {unElementKey :: Word64}
  deriving stock (Eq, Ord, Show)

newtype CommandId = CommandId {unCommandId :: Word64}
  deriving stock (Eq, Ord, Show)

newtype EffectKey = EffectKey {unEffectKey :: Word64}
  deriving stock (Eq, Ord, Show)

newtype TextRevision = TextRevision {unTextRevision :: Word64}
  deriving stock (Eq, Ord, Show)

newtype TextLayerKey = TextLayerKey {unTextLayerKey :: Word64}
  deriving stock (Eq, Ord, Show)

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

-- | Partial portable inline styling. 'Nothing' means that the property does not
-- override the style supplied by an earlier text layer.
data TextStyle = TextStyle
  { textForeground :: !(Maybe Color)
  , textBackground :: !(Maybe Color)
  , textFontFamily :: !(Maybe FontFamily)
  , textFontSize :: !(Maybe Double)
  , textFontWeight :: !(Maybe FontWeight)
  , textFontSlant :: !(Maybe FontSlant)
  , textUnderline :: !(Maybe UnderlineStyle)
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
      , textStrikethrough = Nothing
      , textLetterSpacing = Nothing
      , textBaselineOffset = Nothing
      }

-- | A range between Unicode scalar-value boundaries in an immutable text
-- snapshot. Backends translate these offsets to their native indexing units.
data TextRange = TextRange
  { textRangeStart :: !Int
  , textRangeLength :: !Int
  }
  deriving stock (Eq, Ord, Show)

data TextSpan value = TextSpan
  { textSpanRange :: !TextRange
  , textSpanValue :: !value
  }
  deriving stock (Eq, Functor, Show)

-- | An ergonomic construction unit for authored rich text. The canonical
-- 'AttributedText' representation stores one character snapshot plus spans.
data TextRun = TextRun
  { textRunValue :: !Text
  , textRunStyle :: !TextStyle
  }
  deriving stock (Eq, Show)

data AttributedText = AttributedText
  !Text
  ![TextSpan TextStyle]
  deriving stock (Eq, Show)

attributedTextValue :: AttributedText -> Text
attributedTextValue (AttributedText value _) = value

attributedTextSpans :: AttributedText -> [TextSpan TextStyle]
attributedTextSpans (AttributedText _ spans) = spans

attributedTextFromRuns :: [TextRun] -> AttributedText
attributedTextFromRuns runs =
  AttributedText
    (foldMap textRunValue runs)
    (mergeAdjacent (buildSpans 0 runs))
  where
    buildSpans _ [] = []
    buildSpans offset (TextRun value style : rest)
      | Text.null value = buildSpans offset rest
      | otherwise =
          let runLength = Text.length value
           in TextSpan (TextRange offset runLength) style
                : buildSpans (offset + runLength) rest

attributedTextFromSpans
  :: Text
  -> [TextSpan TextStyle]
  -> Either Text AttributedText
attributedTextFromSpans value spans
  | all validRange spans =
      Right
        ( AttributedText
            value
            ( resolveTextLayers
                textLength
                mempty
                revision
                [TextLayer (TextLayerKey 0) revision spans]
            )
        )
  | otherwise = Left "Attributed-text spans must be non-empty and contained in their text snapshot"
  where
    textLength = Text.length value
    revision = TextRevision 0
    validRange :: TextSpan TextStyle -> Bool
    validRange textSpan =
      let TextRange start rangeLength = textSpan.textSpanRange
       in start >= 0
            && rangeLength > 0
            && start <= textLength
            && rangeLength <= textLength - start

attributedTextToRuns :: AttributedText -> [TextRun]
attributedTextToRuns (AttributedText value spans) =
  [ TextRun
      (Text.take range.textRangeLength (Text.drop range.textRangeStart value))
      textSpan.textSpanValue
  | textSpan <- spans
  , let range = textSpan.textSpanRange
  ]

-- | A revision-bound, non-authoritative presentation layer. Layers are applied
-- in list order and later properties override earlier ones.
data TextLayer = TextLayer
  { textLayerKey :: !TextLayerKey
  , textLayerRevision :: !TextRevision
  , textLayerSpans :: ![TextSpan TextStyle]
  }
  deriving stock (Eq, Show)

data TextEditorSpec = TextEditorSpec
  { textEditorKey :: !ElementKey
  , textEditorFrame :: !Rect
  , textEditorText :: !Text
  , textEditorRevision :: !TextRevision
  , textEditorBaseStyle :: !TextStyle
  , textEditorLayers :: ![TextLayer]
  , textEditorFocused :: !Bool
  }
  deriving stock (Eq, Show)

data Control
  = Label
      !ElementKey
      !Rect
      !Text
  | Button
      !ElementKey
      !Rect
      !Text
      !CommandId
      !Bool
  | TextField
      !ElementKey
      !Rect
      !Text
      !Text
      !Bool
  | TextEditor !TextEditorSpec
  deriving stock (Eq, Show)

-- | Resolve ordered, potentially overlapping presentation layers into
-- validated, non-overlapping runs. Stale layers and invalid ranges are ignored.
resolveTextLayers
  :: Int
  -> TextStyle
  -> TextRevision
  -> [TextLayer]
  -> [TextSpan TextStyle]
resolveTextLayers textLength baseStyle revision layers
  | textLength <= 0 = []
  | otherwise = mergeAdjacent (fmap resolveSegment segments)
  where
    currentSpans =
      [ textSpan
      | layer <- layers
      , layer.textLayerRevision == revision
      , textSpan <- layer.textLayerSpans
      , validRange textSpan.textSpanRange
      ]
    boundaries =
      mapMaybe listToMaybe . group . sort $
        0 : textLength : concatMap spanBoundaries currentSpans
    segments = zip boundaries (drop 1 boundaries)
    resolveSegment (segmentStart, segmentEnd) =
      TextSpan
        { textSpanRange = TextRange segmentStart (segmentEnd - segmentStart)
        , textSpanValue =
            foldl'
              (<>)
              baseStyle
              [ textSpan.textSpanValue
              | textSpan <- currentSpans
              , covers segmentStart segmentEnd textSpan.textSpanRange
              ]
        }
    validRange (TextRange start rangeLength) =
      start >= 0
        && rangeLength > 0
        && start <= textLength
        && rangeLength <= textLength - start
    spanBoundaries :: TextSpan TextStyle -> [Int]
    spanBoundaries textSpan =
      let TextRange start rangeLength = textSpan.textSpanRange
       in [start, start + rangeLength]
    covers segmentStart segmentEnd (TextRange start rangeLength) =
      start <= segmentStart && start + rangeLength >= segmentEnd

mergeAdjacent :: [TextSpan TextStyle] -> [TextSpan TextStyle]
mergeAdjacent = foldr merge []
  where
    merge current [] = [current]
    merge current (next : rest)
      | current.textSpanValue == next.textSpanValue
          && rangeEnd current.textSpanRange == next.textSpanRange.textRangeStart =
          TextSpan
            { textSpanRange =
                TextRange
                  current.textSpanRange.textRangeStart
                  (current.textSpanRange.textRangeLength + next.textSpanRange.textRangeLength)
            , textSpanValue = current.textSpanValue
            }
            : rest
      | otherwise = current : next : rest
    rangeEnd :: TextRange -> Int
    rangeEnd range = range.textRangeStart + range.textRangeLength

data WindowSpec = WindowSpec
  { windowKey :: !WindowKey
  , windowTitle :: !Text
  , windowFrame :: !Rect
  , windowControls :: ![Control]
  }
  deriving stock (Eq, Show)

data CommandSpec = CommandSpec
  { commandId :: !CommandId
  , commandTitle :: !Text
  , commandKeyEquivalent :: !(Maybe Text)
  , commandEnabled :: !Bool
  }
  deriving stock (Eq, Show)

data AppView = AppView
  { appWindows :: ![WindowSpec]
  , appCommands :: ![CommandSpec]
  }
  deriving stock (Eq, Show)

data UIEvent
  = CommandInvoked !CommandId
  | TextChanged !ElementKey !Text
  | WindowCloseRequested !WindowKey
  | WindowActivated !WindowKey
  | TextFileChosen !FilePath
  | TextFileRead !FilePath !(Either Text Text)
  | TextFileWritten !EffectKey !FilePath !Text !(Either Text ())
  deriving stock (Eq, Show)

data Effect
  = RequestOpenTextFiles
  | ReadTextFile !FilePath
  | WriteTextFile !EffectKey !FilePath !Text
  deriving stock (Eq, Show)

data App model = App
  { appInitialModel :: !model
  , appView :: model -> AppView
  , appHandleEvent :: UIEvent -> model -> Transaction model
  }

data Action model = Action
  !Text
  (model -> model)

action :: Text -> (model -> model) -> Action model
action = Action

newtype UndoGroup = UndoGroup Text
  deriving stock (Eq, Show)

data UndoPolicy
  = NoUndo
  | UndoEveryEdit
  | Coalesce !UndoGroup
  | SingleUndo !UndoGroup
  deriving stock (Eq, Show)

data Transaction model = Transaction
  { transactionAction :: !(Action model)
  , transactionUndo :: !UndoPolicy
  , transactionDescription :: !(Maybe Text)
  , transactionEffects :: ![Effect]
  }

transaction
  :: Text
  -> UndoPolicy
  -> (model -> model)
  -> Transaction model
transaction description undo change =
  transactionWithEffects description undo [] change

transactionWithEffects
  :: Text
  -> UndoPolicy
  -> [Effect]
  -> (model -> model)
  -> Transaction model
transactionWithEffects description undo effects change =
  Transaction
    { transactionAction = action description change
    , transactionUndo = undo
    , transactionDescription = Just description
    , transactionEffects = effects
    }

requestEffect :: Text -> Effect -> Transaction model
requestEffect description requested =
  transactionWithEffects description NoUndo [requested] id

noTransaction :: Transaction model
noTransaction =
  Transaction
    { transactionAction = action "No operation" id
    , transactionUndo = NoUndo
    , transactionDescription = Nothing
    , transactionEffects = []
    }

applyTransaction :: Transaction model -> model -> model
applyTransaction (Transaction (Action _ change) _ _ _) = change
