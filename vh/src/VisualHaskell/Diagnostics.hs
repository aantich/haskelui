{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedRecordDot #-}

-- | Pure projection of revision-bound compiler diagnostics into portable
-- HaskeLUI text ranges and presentation layers.
--
-- Compiler output is advisory.  This module deliberately refuses to project
-- a snapshot whose document, revision, content hash, freshness, or individual
-- range revision does not match the immutable editor snapshot supplied by the
-- caller.  That invariant prevents late worker results from decorating newer
-- text.
module VisualHaskell.Diagnostics
  ( ProjectedDiagnostic (..)
  , diagnosticTextLayer
  , projectCurrentDiagnostics
  ) where

import Data.Maybe (mapMaybe)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified HaskeLUI.Core as UI
import qualified VisualHaskell.Semantic as Semantic

data ProjectedDiagnostic = ProjectedDiagnostic
  { projectedDiagnosticId :: !Semantic.DiagnosticId
  , projectedSeverity :: !Semantic.DiagnosticSeverity
  , projectedSource :: !Text
  , projectedCode :: !(Maybe Text)
  , projectedMessage :: !Text
  , projectedRange :: !UI.TextRange
  , projectedHighlightRange :: !(Maybe UI.TextRange)
  , projectedLine :: !Int
  , projectedColumn :: !Int
  }
  deriving stock (Eq, Show)

-- | Convert a current compiler snapshot into Unicode-scalar ranges used by
-- HaskeLUI.  A zero-width compiler range remains zero-width for navigation,
-- while its visual range expands by one scalar where possible so the marker
-- can still be seen.
projectCurrentDiagnostics
  :: Semantic.DocumentId
  -> UI.TextRevision
  -> Text
  -> Semantic.AnalysisSnapshot Semantic.RevisionedSourceRange
  -> [ProjectedDiagnostic]
projectCurrentDiagnostics documentId revision source snapshot
  | snapshot.analysisDocument /= documentId = []
  | snapshot.analysisRevision /= semanticRevision = []
  | snapshot.analysisContentHash /= Semantic.contentHash source = []
  | snapshot.analysisFreshness /= Semantic.CurrentAnalysis = []
  | otherwise = mapMaybe (projectDiagnostic semanticRevision index sourceLength) snapshot.analysisDiagnostics
  where
    semanticRevision = Semantic.TextRevision revision.unTextRevision
    index = Semantic.buildCoordinateIndex semanticRevision source
    sourceLength = Text.length source

projectDiagnostic
  :: Semantic.TextRevision
  -> Semantic.CoordinateIndex
  -> Int
  -> Semantic.Diagnostic Semantic.RevisionedSourceRange
  -> Maybe ProjectedDiagnostic
projectDiagnostic expectedRevision index sourceLength diagnostic
  | range.sourceRangeRevision /= expectedRevision = Nothing
  | otherwise = do
      start <- either (const Nothing) Just (Semantic.positionToScalarOffset index range.sourceRangeStart)
      end <- either (const Nothing) Just (Semantic.positionToScalarOffset index range.sourceRangeEnd)
      if start > end
        then Nothing
        else
          let exactRange = UI.TextRange start (end - start)
              visibleRange
                | end > start = Just exactRange
                | start < sourceLength = Just (UI.TextRange start 1)
                | otherwise = Nothing
           in Just
                ProjectedDiagnostic
                  { projectedDiagnosticId = diagnostic.diagnosticId
                  , projectedSeverity = diagnostic.diagnosticSeverity
                  , projectedSource = diagnostic.diagnosticSource
                  , projectedCode = diagnostic.diagnosticCode
                  , projectedMessage = diagnostic.diagnosticMessage
                  , projectedRange = exactRange
                  , projectedHighlightRange = visibleRange
                  , projectedLine = range.sourceRangeStart.sourceLine
                  , projectedColumn = range.sourceRangeStart.sourceColumn
                  }
  where
    range = diagnostic.diagnosticRange

-- | Build a generic text-decoration layer.  The foreground remains owned by
-- the syntax/theme layer; this layer contributes only underline shape and
-- colour, so syntax highlighting and diagnostics compose independently.
diagnosticTextLayer
  :: UI.ColorScheme
  -> UI.TextRevision
  -> [ProjectedDiagnostic]
  -> Maybe UI.TextLayer
diagnosticTextLayer scheme revision diagnostics
  | null spans = Nothing
  | otherwise =
      Just
        UI.TextLayer
          { UI.textLayerKey = UI.TextLayerKey 2
          , UI.textLayerRevision = revision
          , UI.textLayerSpans = spans
          }
  where
    spans =
      [ UI.TextSpan visibleRange (diagnosticStyle scheme diagnostic.projectedSeverity)
      | diagnostic <- diagnostics
      , visibleRange <- maybe [] pure diagnostic.projectedHighlightRange
      ]

diagnosticStyle :: UI.ColorScheme -> Semantic.DiagnosticSeverity -> UI.TextStyle
diagnosticStyle scheme severity =
  mempty
    { UI.textUnderline = Just underline
    , UI.textUnderlineColor = Just color
    }
  where
    underline =
      case severity of
        Semantic.DiagnosticError -> UI.UnderlineWavy
        Semantic.DiagnosticWarning -> UI.UnderlineWavy
        Semantic.DiagnosticInformation -> UI.UnderlineDotted
        Semantic.DiagnosticHint -> UI.UnderlineDotted
    color =
      case (scheme, severity) of
        (UI.LightColorScheme, Semantic.DiagnosticError) -> UI.RGBA 0.78 0.13 0.17 1
        (UI.DarkColorScheme, Semantic.DiagnosticError) -> UI.RGBA 1.0 0.36 0.38 1
        (UI.LightColorScheme, Semantic.DiagnosticWarning) -> UI.RGBA 0.78 0.45 0.0 1
        (UI.DarkColorScheme, Semantic.DiagnosticWarning) -> UI.RGBA 1.0 0.68 0.2 1
        (UI.LightColorScheme, Semantic.DiagnosticInformation) -> UI.RGBA 0.05 0.38 0.74 1
        (UI.DarkColorScheme, Semantic.DiagnosticInformation) -> UI.RGBA 0.35 0.66 1.0 1
        (UI.LightColorScheme, Semantic.DiagnosticHint) -> UI.RGBA 0.38 0.42 0.48 1
        (UI.DarkColorScheme, Semantic.DiagnosticHint) -> UI.RGBA 0.66 0.7 0.76 1
