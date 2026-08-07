{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Control.Monad (unless)
import Data.Aeson (decode, encode)
import qualified Data.Map.Strict as Map
import qualified Data.Text as Text
import VisualHaskell.Semantic

main :: IO ()
main = do
  let revision = TextRevision 7
      index = buildCoordinateIndex revision "a\t😀e\r\nλx\n"
      scalar column = SourcePosition 0 column UnicodeScalarColumn
  assertEqual "emoji UTF-8 boundary" (Right (SourcePosition 0 6 Utf8ByteColumn))
    (convertPosition index Utf8ByteColumn (scalar 3))
  assertEqual "emoji UTF-16 boundary" (Right (SourcePosition 0 4 Utf16CodeUnitColumn))
    (convertPosition index Utf16CodeUnitColumn (scalar 3))
  assertEqual "GHC tab stop" (Right (SourcePosition 0 8 GhcColumn))
    (convertPosition index GhcColumn (scalar 2))
  assertEqual "CRLF contributes two scalar offsets" (Right 6)
    (positionToScalarOffset index (SourcePosition 1 0 UnicodeScalarColumn))
  assertEqual "UTF-8 rejects an offset inside lambda" (Left (ColumnInsideEncodingUnit (SourcePosition 1 1 Utf8ByteColumn)))
    (convertPosition index UnicodeScalarColumn (SourcePosition 1 1 Utf8ByteColumn))
  let range = RevisionedSourceRange revision (scalar 2) (scalar 4)
  assertEqual "range conversion is revision-bound"
    (Right (RevisionedSourceRange revision (SourcePosition 0 2 Utf16CodeUnitColumn) (SourcePosition 0 5 Utf16CodeUnitColumn)))
    (convertRange index Utf16CodeUnitColumn range)
  assertEqual "stale range is rejected"
    (Left (RangeRevisionMismatch revision (TextRevision 6)))
    (convertRange index Utf8ByteColumn range {sourceRangeRevision = TextRevision 6})
  let snapshot =
        DocumentSnapshot
          (DocumentId "doc") "Main.hs" revision
          (contentHash "main = pure ()") "main = pure ()" LF
  assertEqual "document snapshot JSON round trip" (Just snapshot) (decode (encode snapshot))

  let boxType = TypeId "type:Box"
      boxConstructorType = TypeId "constructor:Box"
      kindType = TypeId "kind:Type"
      valueType = TypeId "type:Int-to-Box"
      boxDeclaration =
        Declaration
          { declarationId = DeclarationId "decl:Box"
          , declarationName = "Box"
          , declarationKind = TypeDeclaration
          , declarationRange = (10 :: Int)
          , declarationSelectionRange = 11
          , declarationType = Just boxType
          , declarationSignatureText = Just "Type"
          , declarationTypeSemantics =
              Just
                TypeDeclarationSemantics
                  { typeDeclarationSemanticConstructor = boxConstructorType
                  , typeDeclarationSemanticParameters =
                      [TypeParameterSemantics "a" (Just kindType)]
                  , typeDeclarationSemanticDefinition =
                      AlgebraicTypeSemantics
                        [ TypeConstructorSemantics
                            { typeConstructorSemanticId = "constructor:MkBox"
                            , typeConstructorSemanticName = "MkBox"
                            , typeConstructorSemanticExistentials = []
                            , typeConstructorSemanticConstraints = []
                            , typeConstructorSemanticArguments = [boxConstructorType]
                            , typeConstructorSemanticFields =
                                [ TypeFieldSemantics
                                    { typeFieldSemanticId = "field:next"
                                    , typeFieldSemanticName = "next"
                                    , typeFieldSemanticType = boxConstructorType
                                    , typeFieldSemanticRange = Just 12
                                    }
                                ]
                            , typeConstructorSemanticResult = Just boxConstructorType
                            , typeConstructorSemanticRange = Just 13
                            }
                        ]
                  }
          }
      valueDeclaration =
        Declaration
          { declarationId = DeclarationId "decl:box"
          , declarationName = "box"
          , declarationKind = ValueDeclaration
          , declarationRange = 20
          , declarationSelectionRange = 21
          , declarationType = Just valueType
          , declarationSignatureText = Just "Int -> Box"
          , declarationTypeSemantics = Nothing
          }
      firstAnalysis =
        AnalysisSnapshot
          { analysisWorkspaceGeneration = WorkspaceGeneration 3
          , analysisSession = SessionId "session"
          , analysisDocument = DocumentId "/project/A.hs"
          , analysisRevision = TextRevision 4
          , analysisContentHash = contentHash "data Box = Box Int"
          , analysisCompleteness = Typechecked
          , analysisFreshness = CurrentAnalysis
          , analysisDiagnostics = []
          , analysisDeclarations = [boxDeclaration, valueDeclaration]
          , analysisTypes =
              Map.fromList
                [ (boxType, TypeConstructor "Type")
                , (boxConstructorType, TypeConstructor "A.Box")
                , (kindType, TypeConstructor "GHC.Types.Type")
                , (valueType, UnsupportedType "Int -> Box")
                ]
          }
      secondAnalysis =
        firstAnalysis
          { analysisDocument = DocumentId "/project/B.hs"
          , analysisDeclarations =
              [ boxDeclaration
                  { declarationId = DeclarationId "decl:Other"
                  , declarationName = "Other"
                  , declarationTypeSemantics = Nothing
                  }
              ]
          }
      currentUniverse =
        buildTypeUniverse
          (CurrentDocumentTypes (DocumentId "/project/A.hs"))
          [firstAnalysis, secondAnalysis]
      projectUniverse =
        buildTypeUniverse
          (ProjectTypes (WorkspaceId "/project") (Just (DocumentId "/project/A.hs")))
          [firstAnalysis, secondAnalysis]
      debugProjection = renderTypeUniverseDebug (Text.pack . show) currentUniverse
  assertEqual "current-file universe filters its sources" 1 (length currentUniverse.typeUniverseSources)
  assertEqual
    "current-file universe reports exact document coverage"
    (ExactDocumentCoverage (DocumentId "/project/A.hs"))
    currentUniverse.typeUniverseCoverage
  assertEqual "type declarations become stable universe entities" 1 (Map.size currentUniverse.typeUniverseEntities)
  assertEqual "all declaration type attachments remain available" 2 (length currentUniverse.typeUniverseUsages)
  assertEqual "recursive definitions produce a reference and a recursion marker" 2 (length currentUniverse.typeUniverseRelations)
  assertEqual "project universe combines accepted document snapshots" 2 (Map.size projectUniverse.typeUniverseEntities)
  assert
    "project origin distinguishes focused and workspace documents"
    ( let origins = map (.typeEntityOrigin) (Map.elems projectUniverse.typeUniverseEntities)
       in CurrentDocumentOrigin (DocumentId "/project/A.hs") `elem` origins
            && WorkspaceDocumentOrigin (DocumentId "/project/B.hs") `elem` origins
    )
  assert
    "debug mode exposes the exact semantic projection"
    ( all
        (`Text.isInfixOf` debugProjection)
        [ "type-universe/v1"
        , "scope: current-document /project/A.hs"
        , "coverage: exact-document /project/A.hs"
        , "name: Box"
        , "name: box"
        , "type-constructor: constructor:Box"
        , "parameters: [a :: kind:Type]"
        , "definition: algebraic (1 constructors)"
        , "constructor-id: constructor:MkBox"
        , "name: next"
        , "result: constructor:Box"
        , "structured-types: 4"
        , "relations: 2"
        , "--recursive-reference-->"
        ]
    )
  assertEqual
    "analysis JSON preserves rich declared-type semantics"
    (Just firstAnalysis)
    (decode (encode firstAnalysis))
  putStrLn "Visual Haskell semantic model tests passed"

assert :: String -> Bool -> IO ()
assert message condition = unless condition (fail message)

assertEqual :: (Eq value, Show value) => String -> value -> value -> IO ()
assertEqual message expected actual =
  unless (expected == actual) $
    fail (message <> ": expected " <> show expected <> ", got " <> show actual)
