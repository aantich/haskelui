{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
module SymbolIndexSpec (runSymbolIndexChecks) where

import Control.Monad (unless)
import qualified Data.Map.Strict as Map
import qualified Data.Text as Text
import HaskeLUI.Core
import HaskeLUI.Property
import VisualHaskell
import qualified VisualHaskell.Semantic as S
import qualified VisualHaskell.Analysis.Client as Client
import qualified VisualHaskell.Analysis.Protocol as P
import VisualHaskell.Analysis.Service (defaultAnalysisConfiguration)
import qualified VisualHaskell.FunctionCanvas as F
import VisualHaskell.TextMate (defaultTextMateConfiguration)

-- Exercise the real UI transaction/freshness logic without launching services.
runSymbolIndexChecks :: IO ()
runSymbolIndexChecks = do
  configuration <- defaultTextMateConfiguration "/tmp/vh-index-model-test"
  let app = applicationWithAnalysisEnvironment "/tmp/vh-index-model-workspace" configuration
        (defaultAnalysisConfiguration "not-launched-by-model-test")
      source = "module A where\nlocal = 1\n"
      path = "/project/A.hs"
      docId = S.DocumentId (Text.pack path)
      opened = applyTransaction (app.appHandleEvent (TextFileRead path (Right source)) app.appInitialModel) app.appInitialModel
      doc = S.DocumentSnapshot docId path (S.TextRevision 0) (S.contentHash source) source S.LF
      session = S.SessionId "review"
      generation = S.WorkspaceGeneration 1
      worker = Client.WorkerGeneration 1
      functionId = S.DeclarationId "local:imported"
      libraryId = S.DeclarationId "library:length"
      functionType = S.TypeId "function"
      int = S.TypeId "int"
      string = S.TypeId "string"
      boolean = S.TypeId "bool"
      table input output = Map.fromList [(functionType, S.FunctionType input output), (int, S.TypeConstructor "Int"),
        (string, S.TypeConstructor "String"), (boolean, S.TypeConstructor "Bool")]
      symbol identity name moduleName input output signature = S.IndexedSymbol
        (S.Declaration identity name S.ValueDeclaration Nothing Nothing (Just functionType) (Just signature) Nothing)
        (table input output) (S.ModuleName moduleName) "unit" "package" "1" Nothing Nothing
      imported = symbol functionId "g" "B" int string "Int -> String"
      library = symbol libraryId "length" "Data.List" string int "String -> Int"
      changed = symbol functionId "g" "B" boolean boolean "Bool -> Bool"
      canvas = (F.connectFunctions 1 2 (F.addFunction libraryId (F.addFunction functionId F.emptyFunctionCanvas)))
        {F.canvasPositions = Map.singleton 1 (Point 36 28)}
      query = P.CompositionQuery [functionId,libraryId]
      analysis = S.AnalysisSnapshot generation session docId (S.TextRevision 0) (S.contentHash source)
        S.Typechecked S.CurrentAnalysis [] [] Map.empty
      context = Just (generation, Just worker, session, S.analysisInputsHash [doc])
      base = applyAction (batchActions "index regression setup"
        [ rootPath.projectRoot .= Just "/project"
        , rootPath.analysisWorkspaceTrusted .= True
        , rootPath.analysisWorkspaceGeneration .= generation
        , rootPath.analysisWorkerGeneration .= Just worker
        , rootPath.analysisComponent .= Just (S.ComponentInfo (S.ComponentId "lib") "/project" (S.CompilerVersion "9.10.3") session)
        , rootPath.analysisSnapshots .= Map.singleton docId analysis
        , rootPath.selectedInspectorTab .= TabKey 9000004
        , rootPath.functionCanvas .= canvas
        , rootPath.functionCanvasDocument .= Just docId
        , rootPath.symbolIndexContext .= context
        , rootPath.symbolIndexRevision .= Just (S.ContentHash 1)
        , rootPath.indexedSymbols .= Map.fromList [(functionId,imported),(libraryId,library)]
        ]) opened
      tick model = applyTransaction (app.appHandleEvent (ControlInvoked (ElementKey 999)) model) model
      requested = tick base
      oldRequest = get rootPath.functionCanvasRequest requested
      valid = applyAction (batchActions "accepted original result"
        [ rootPath.functionCanvasResult .= Just (P.CompositionResult query True (Just "Int -> Int") Nothing)
        , rootPath.functionCanvasStatus .= "Composes :: Int -> Int"
        ]) requested
      feedback model = Text.unlines [attributedTextValue rich.richTextValue | window <- (app.appView model).appWindows,
        RichText rich <- windowLeafControls window, rich.richTextKey == ElementKey 234]
  assert "imported composition receives a request" (oldRequest /= Nothing)
  assert "original composition feedback is visible" ("Composes ::" `Text.isInfixOf` feedback valid)
  let revised = applyAction (batchActions "accepted changed index"
        [ rootPath.symbolIndexRevision .= Just (S.ContentHash 2)
        , rootPath.indexedSymbols .= Map.fromList [(functionId,changed),(libraryId,library)]
        ]) valid
      rechecked = tick revised
  assert "revised imported types hide old feedback before any asynchronous reply"
    (not ("Composes ::" `Text.isInfixOf` feedback revised))
  assert "same document and IDs are rechecked on index revision change"
    (get rootPath.functionCanvasRequest rechecked /= oldRequest && get rootPath.functionCanvasResult rechecked == Nothing)
  let partialResult = S.SymbolSearchResult (S.SymbolQuery "length" S.FunctionSymbols 0 50 [functionId,libraryId])
        [library] [library] 1 0 10 0 ["local failure"] False (S.ContentHash 3)
      (symbols, stale) = S.reconcileSymbolPage partialResult (get rootPath.indexedSymbols valid)
      partial = applyAction (batchActions "accepted partial index"
        [rootPath.indexedSymbols .= symbols, rootPath.indexedStale .= stale,
         rootPath.symbolIndexRevision .= Just partialResult.symbolSearchRevision]) valid
      afterPartial = tick partial
      kept = get rootPath.functionCanvas afterPartial
  assert "partial indexes preserve pinned nodes, positions and wires"
    (kept.canvasNodes == canvas.canvasNodes && kept.canvasPositions == canvas.canvasPositions && kept.canvasEdges == canvas.canvasEdges)
  assert "unavailable pinned functions cannot reuse old successful feedback"
    (not ("Composes ::" `Text.isInfixOf` feedback afterPartial))
  assert "unavailable pinned functions do not dispatch a new composition check"
    (get rootPath.functionCanvasRequest afterPartial == oldRequest)
  let range = S.RevisionedSourceRange (S.TextRevision 0) (S.SourcePosition 0 0 S.UnicodeScalarColumn) (S.SourcePosition 0 6 S.UnicodeScalarColumn)
      navigable = imported {S.indexedSourcePath = Just path, S.indexedSourceHash = Just (S.contentHash source),
        S.indexedDeclaration = imported.indexedDeclaration {S.declarationSelectionRange = Just range}}
      navigationModel = applyAction (rootPath.indexedSymbols .= Map.fromList [(functionId,navigable),(libraryId,library)]) base
      doubleClick = DrawingInputReceived functionCanvasKey (DrawingPointerInput
        (DrawingPointerEvent (DrawingPointerId 1) DrawingPointerDown (Point 50 45) (Point 0 0) (Just PrimaryPointerButton)
          noDrawingPointerButtons noDrawingModifiers 2 Nothing))
      navigation = app.appHandleEvent doubleClick navigationModel
  assert "restored indexed paths navigate the existing buffer without reading disk"
    (null navigation.transactionEffects && get rootPath.pendingDefinition (applyTransaction navigation navigationModel) == Nothing)

assert :: String -> Bool -> IO ()
assert message condition = unless condition (fail message)
