{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

module VisualHaskell.Semantic.Types
  ( AnalysisCompleteness (..)
  , AnalysisFreshness (..)
  , AnalysisSnapshot (..)
  , ComponentId (..)
  , ComponentInfo (..)
  , CompilerVersion (..)
  , ContentHash (..)
  , Declaration (..)
  , DeclarationId (..)
  , DeclarationKind (..)
  , Diagnostic (..)
  , DiagnosticId (..)
  , DiagnosticSeverity (..)
  , DocumentId (..)
  , DocumentSnapshot (..)
  , LineEndingPolicy (..)
  , ModuleName (..)
  , RelatedLocation (..)
  , SessionId (..)
  , StructuredType (..)
  , TextRevision (..)
  , TypeId (..)
  , TypeTable
  , WorkspaceGeneration (..)
  , WorkspaceId (..)
  , contentHash
  ) where

import Data.Aeson
  ( FromJSON (..)
  , FromJSONKey
  , ToJSON (..)
  , ToJSONKey
  , Value
  , object
  , withObject
  , withText
  , (.:)
  , (.:?)
  , (.=)
  )
import Data.Aeson.Types (Parser)
import Data.Bits (xor)
import qualified Data.ByteString as ByteString
import Data.Map.Strict (Map)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import Data.Word (Word64)

newtype WorkspaceId = WorkspaceId {unWorkspaceId :: Text}
  deriving stock (Eq, Ord, Show)
  deriving newtype (FromJSON, ToJSON)

newtype WorkspaceGeneration = WorkspaceGeneration {unWorkspaceGeneration :: Word64}
  deriving stock (Eq, Ord, Show)
  deriving newtype (FromJSON, ToJSON)

newtype SessionId = SessionId {unSessionId :: Text}
  deriving stock (Eq, Ord, Show)
  deriving newtype (FromJSON, ToJSON)

newtype ComponentId = ComponentId {unComponentId :: Text}
  deriving stock (Eq, Ord, Show)
  deriving newtype (FromJSON, ToJSON)

newtype DocumentId = DocumentId {unDocumentId :: Text}
  deriving stock (Eq, Ord, Show)
  deriving newtype (FromJSON, ToJSON)

newtype TextRevision = TextRevision {unTextRevision :: Word64}
  deriving stock (Eq, Ord, Show)
  deriving newtype (FromJSON, ToJSON)

newtype ContentHash = ContentHash {unContentHash :: Word64}
  deriving stock (Eq, Ord, Show)
  deriving newtype (FromJSON, ToJSON)

newtype CompilerVersion = CompilerVersion {unCompilerVersion :: Text}
  deriving stock (Eq, Ord, Show)
  deriving newtype (FromJSON, ToJSON)

newtype ModuleName = ModuleName {unModuleName :: Text}
  deriving stock (Eq, Ord, Show)
  deriving newtype (FromJSON, ToJSON)

newtype DiagnosticId = DiagnosticId {unDiagnosticId :: Text}
  deriving stock (Eq, Ord, Show)
  deriving newtype (FromJSON, ToJSON)

newtype DeclarationId = DeclarationId {unDeclarationId :: Text}
  deriving stock (Eq, Ord, Show)
  deriving newtype (FromJSON, ToJSON)

newtype TypeId = TypeId {unTypeId :: Text}
  deriving stock (Eq, Ord, Show)
  deriving newtype (FromJSON, FromJSONKey, ToJSON, ToJSONKey)

data LineEndingPolicy = LF | CRLF | MixedLineEndings | UnknownLineEndings
  deriving stock (Eq, Ord, Show)

data DocumentSnapshot = DocumentSnapshot
  { snapshotDocumentId :: !DocumentId
  , snapshotPath :: !FilePath
  , snapshotRevision :: !TextRevision
  , snapshotContentHash :: !ContentHash
  , snapshotText :: !Text
  , snapshotLineEnding :: !LineEndingPolicy
  }
  deriving stock (Eq, Show)

data ComponentInfo = ComponentInfo
  { componentId :: !ComponentId
  , componentRoot :: !FilePath
  , componentCompilerVersion :: !CompilerVersion
  , componentSession :: !SessionId
  }
  deriving stock (Eq, Show)

data DiagnosticSeverity = DiagnosticError | DiagnosticWarning | DiagnosticInformation | DiagnosticHint
  deriving stock (Eq, Ord, Show)

data RelatedLocation range = RelatedLocation
  { relatedDocument :: !DocumentId
  , relatedRange :: !range
  , relatedMessage :: !Text
  }
  deriving stock (Eq, Show)

data Diagnostic range = Diagnostic
  { diagnosticId :: !DiagnosticId
  , diagnosticSeverity :: !DiagnosticSeverity
  , diagnosticSource :: !Text
  , diagnosticCode :: !(Maybe Text)
  , diagnosticMessage :: !Text
  , diagnosticRange :: !range
  , diagnosticRelated :: ![RelatedLocation range]
  }
  deriving stock (Eq, Show)

data DeclarationKind
  = ValueDeclaration
  | TypeDeclaration
  | DataConstructorDeclaration
  | ClassDeclaration
  | InstanceDeclaration
  | ModuleDeclaration
  | UnsupportedDeclaration !Text
  deriving stock (Eq, Ord, Show)

data Declaration range = Declaration
  { declarationId :: !DeclarationId
  , declarationName :: !Text
  , declarationKind :: !DeclarationKind
  , declarationRange :: !range
  , declarationSelectionRange :: !range
  , declarationType :: !(Maybe TypeId)
  , declarationSignatureText :: !(Maybe Text)
  }
  deriving stock (Eq, Show)

data StructuredType
  = TypeVariable !Text
  | TypeConstructor !Text
  | TypeApplication !TypeId ![TypeId]
  | FunctionType !TypeId !TypeId
  | ForallType ![Text] !TypeId
  | ConstrainedType ![TypeId] !TypeId
  | TupleType ![TypeId]
  | ListType !TypeId
  | LiteralType !Text
  | UnsupportedType !Text
  deriving stock (Eq, Show)

type TypeTable = Map TypeId StructuredType

data AnalysisCompleteness = ParseOnly | Renamed | Typechecked | Indexed | PartiallyFailed
  deriving stock (Eq, Ord, Show)

data AnalysisFreshness = CurrentAnalysis | StaleAnalysis
  deriving stock (Eq, Ord, Show)

data AnalysisSnapshot range = AnalysisSnapshot
  { analysisWorkspaceGeneration :: !WorkspaceGeneration
  , analysisSession :: !SessionId
  , analysisDocument :: !DocumentId
  , analysisRevision :: !TextRevision
  , analysisContentHash :: !ContentHash
  , analysisCompleteness :: !AnalysisCompleteness
  , analysisFreshness :: !AnalysisFreshness
  , analysisDiagnostics :: ![Diagnostic range]
  , analysisDeclarations :: ![Declaration range]
  , analysisTypes :: !TypeTable
  }
  deriving stock (Eq, Show)

contentHash :: Text -> ContentHash
contentHash =
  ContentHash
    . ByteString.foldl'
      (\hash byte -> (hash `xor` fromIntegral byte) * 1099511628211)
      14695981039346656037
    . TextEncoding.encodeUtf8

instance ToJSON LineEndingPolicy where
  toJSON policy = toJSON $ case policy of
    LF -> ("lf" :: Text)
    CRLF -> "crlf"
    MixedLineEndings -> "mixed"
    UnknownLineEndings -> "unknown"

instance FromJSON LineEndingPolicy where
  parseJSON = parseTextEnum "line-ending policy"
    [ ("lf", LF), ("crlf", CRLF), ("mixed", MixedLineEndings), ("unknown", UnknownLineEndings) ]

instance ToJSON DocumentSnapshot where
  toJSON snapshot = object
    [ "document" .= snapshot.snapshotDocumentId
    , "path" .= snapshot.snapshotPath
    , "revision" .= snapshot.snapshotRevision
    , "contentHash" .= snapshot.snapshotContentHash
    , "text" .= snapshot.snapshotText
    , "lineEnding" .= snapshot.snapshotLineEnding
    ]

instance FromJSON DocumentSnapshot where
  parseJSON = withObject "document snapshot" $ \value ->
    DocumentSnapshot
      <$> value .: "document"
      <*> value .: "path"
      <*> value .: "revision"
      <*> value .: "contentHash"
      <*> value .: "text"
      <*> value .: "lineEnding"

instance ToJSON ComponentInfo where
  toJSON component = object
    [ "id" .= component.componentId
    , "root" .= component.componentRoot
    , "compilerVersion" .= component.componentCompilerVersion
    , "session" .= component.componentSession
    ]

instance FromJSON ComponentInfo where
  parseJSON = withObject "component info" $ \value ->
    ComponentInfo
      <$> value .: "id"
      <*> value .: "root"
      <*> value .: "compilerVersion"
      <*> value .: "session"

instance ToJSON DiagnosticSeverity where
  toJSON severity = toJSON $ case severity of
    DiagnosticError -> ("error" :: Text)
    DiagnosticWarning -> "warning"
    DiagnosticInformation -> "information"
    DiagnosticHint -> "hint"

instance FromJSON DiagnosticSeverity where
  parseJSON = parseTextEnum "diagnostic severity"
    [ ("error", DiagnosticError), ("warning", DiagnosticWarning)
    , ("information", DiagnosticInformation), ("hint", DiagnosticHint)
    ]

instance ToJSON range => ToJSON (RelatedLocation range) where
  toJSON location = object
    [ "document" .= location.relatedDocument
    , "range" .= location.relatedRange
    , "message" .= location.relatedMessage
    ]

instance FromJSON range => FromJSON (RelatedLocation range) where
  parseJSON = withObject "related location" $ \value ->
    RelatedLocation <$> value .: "document" <*> value .: "range" <*> value .: "message"

instance ToJSON range => ToJSON (Diagnostic range) where
  toJSON diagnostic = object
    [ "id" .= diagnostic.diagnosticId
    , "severity" .= diagnostic.diagnosticSeverity
    , "source" .= diagnostic.diagnosticSource
    , "code" .= diagnostic.diagnosticCode
    , "message" .= diagnostic.diagnosticMessage
    , "range" .= diagnostic.diagnosticRange
    , "related" .= diagnostic.diagnosticRelated
    ]

instance FromJSON range => FromJSON (Diagnostic range) where
  parseJSON = withObject "diagnostic" $ \value ->
    Diagnostic
      <$> value .: "id" <*> value .: "severity" <*> value .: "source"
      <*> value .:? "code" <*> value .: "message" <*> value .: "range"
      <*> value .: "related"

instance ToJSON DeclarationKind where
  toJSON kind = case kind of
    UnsupportedDeclaration description -> object ["kind" .= ("unsupported" :: Text), "description" .= description]
    _ -> object ["kind" .= declarationKindText kind]

instance FromJSON DeclarationKind where
  parseJSON = withObject "declaration kind" $ \value -> do
    kind <- value .: "kind"
    case (kind :: Text) of
      "value" -> pure ValueDeclaration
      "type" -> pure TypeDeclaration
      "data-constructor" -> pure DataConstructorDeclaration
      "class" -> pure ClassDeclaration
      "instance" -> pure InstanceDeclaration
      "module" -> pure ModuleDeclaration
      "unsupported" -> UnsupportedDeclaration <$> value .: "description"
      _ -> fail ("unknown declaration kind " <> Text.unpack kind)

instance ToJSON range => ToJSON (Declaration range) where
  toJSON declaration = object
    [ "id" .= declaration.declarationId
    , "name" .= declaration.declarationName
    , "kind" .= declaration.declarationKind
    , "range" .= declaration.declarationRange
    , "selectionRange" .= declaration.declarationSelectionRange
    , "type" .= declaration.declarationType
    , "signatureText" .= declaration.declarationSignatureText
    ]

instance FromJSON range => FromJSON (Declaration range) where
  parseJSON = withObject "declaration" $ \value ->
    Declaration
      <$> value .: "id" <*> value .: "name" <*> value .: "kind"
      <*> value .: "range" <*> value .: "selectionRange"
      <*> value .:? "type" <*> value .:? "signatureText"

instance ToJSON StructuredType where
  toJSON structured = case structured of
    TypeVariable name -> tagged "variable" ["name" .= name]
    TypeConstructor name -> tagged "constructor" ["name" .= name]
    TypeApplication function arguments -> tagged "application" ["function" .= function, "arguments" .= arguments]
    FunctionType argument result -> tagged "function" ["argument" .= argument, "result" .= result]
    ForallType variables body -> tagged "forall" ["variables" .= variables, "body" .= body]
    ConstrainedType constraints body -> tagged "constrained" ["constraints" .= constraints, "body" .= body]
    TupleType elements -> tagged "tuple" ["elements" .= elements]
    ListType element -> tagged "list" ["element" .= element]
    LiteralType value -> tagged "literal" ["value" .= value]
    UnsupportedType description -> tagged "unsupported" ["description" .= description]
    where tagged kind fields = object (("kind" .= (kind :: Text)) : fields)

instance FromJSON StructuredType where
  parseJSON = withObject "structured type" $ \value -> do
    kind <- value .: "kind"
    case (kind :: Text) of
      "variable" -> TypeVariable <$> value .: "name"
      "constructor" -> TypeConstructor <$> value .: "name"
      "application" -> TypeApplication <$> value .: "function" <*> value .: "arguments"
      "function" -> FunctionType <$> value .: "argument" <*> value .: "result"
      "forall" -> ForallType <$> value .: "variables" <*> value .: "body"
      "constrained" -> ConstrainedType <$> value .: "constraints" <*> value .: "body"
      "tuple" -> TupleType <$> value .: "elements"
      "list" -> ListType <$> value .: "element"
      "literal" -> LiteralType <$> value .: "value"
      "unsupported" -> UnsupportedType <$> value .: "description"
      _ -> fail ("unknown structured type kind " <> Text.unpack kind)

instance ToJSON AnalysisCompleteness where
  toJSON completeness = toJSON $ case completeness of
    ParseOnly -> ("parse-only" :: Text)
    Renamed -> "renamed"
    Typechecked -> "typechecked"
    Indexed -> "indexed"
    PartiallyFailed -> "partially-failed"

instance FromJSON AnalysisCompleteness where
  parseJSON = parseTextEnum "analysis completeness"
    [ ("parse-only", ParseOnly), ("renamed", Renamed), ("typechecked", Typechecked)
    , ("indexed", Indexed), ("partially-failed", PartiallyFailed)
    ]

instance ToJSON AnalysisFreshness where
  toJSON freshness = toJSON $ case freshness of
    CurrentAnalysis -> ("current" :: Text)
    StaleAnalysis -> "stale"

instance FromJSON AnalysisFreshness where
  parseJSON = parseTextEnum "analysis freshness" [("current", CurrentAnalysis), ("stale", StaleAnalysis)]

instance ToJSON range => ToJSON (AnalysisSnapshot range) where
  toJSON snapshot = object
    [ "workspaceGeneration" .= snapshot.analysisWorkspaceGeneration
    , "session" .= snapshot.analysisSession
    , "document" .= snapshot.analysisDocument
    , "revision" .= snapshot.analysisRevision
    , "contentHash" .= snapshot.analysisContentHash
    , "completeness" .= snapshot.analysisCompleteness
    , "freshness" .= snapshot.analysisFreshness
    , "diagnostics" .= snapshot.analysisDiagnostics
    , "declarations" .= snapshot.analysisDeclarations
    , "types" .= snapshot.analysisTypes
    ]

instance FromJSON range => FromJSON (AnalysisSnapshot range) where
  parseJSON = withObject "analysis snapshot" $ \value ->
    AnalysisSnapshot
      <$> value .: "workspaceGeneration" <*> value .: "session"
      <*> value .: "document" <*> value .: "revision" <*> value .: "contentHash"
      <*> value .: "completeness" <*> value .: "freshness"
      <*> value .: "diagnostics" <*> value .: "declarations" <*> value .: "types"

declarationKindText :: DeclarationKind -> Text
declarationKindText kind = case kind of
  ValueDeclaration -> "value"
  TypeDeclaration -> "type"
  DataConstructorDeclaration -> "data-constructor"
  ClassDeclaration -> "class"
  InstanceDeclaration -> "instance"
  ModuleDeclaration -> "module"
  UnsupportedDeclaration _ -> "unsupported"

parseTextEnum :: String -> [(Text, value)] -> Value -> Parser value
parseTextEnum label alternatives = withText label $ \value ->
  maybe (fail ("unknown " <> label <> " " <> Text.unpack value)) pure (lookup value alternatives)
