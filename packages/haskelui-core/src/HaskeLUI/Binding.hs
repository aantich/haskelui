{-# LANGUAGE GADTs #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Pure typed editing protocols built on 'HaskeLUI.Property'.
--
-- A binding separates authoritative model values from control drafts. It owns
-- formatting, parsing, synchronous validation, commit timing, undo metadata,
-- and three-way external-update reconciliation, but never performs IO.
module HaskeLUI.Binding
  ( Binding
  , BindingCodec
  , BindingConflict (..)
  , BindingIssue (..)
  , BindingOption
  , CommitPolicy (..)
  , DraftBaseline
  , DraftSyncPolicy (..)
  , DraftSyncResult (..)
  , EditDecision (..)
  , EditTrigger (..)
  , TextCodec
  , alsoWrite
  , bind
  , bindText
  , bindWithCodec
  , bindWith
  , bindingCommitPolicy
  , bindingPropertyId
  , bindingSyncPolicy
  , bindingTransactionDescription
  , bindingUndoPolicy
  , captureDraftBaseline
  , commitPolicy
  , codec
  , controlled
  , controlledWith
  , editBinding
  , equivalentWith
  , labelTransaction
  , readBinding
  , reconcileDraft
  , syncPolicy
  , textCodec
  , undoPolicy
  , validateBinding
  , validateWith
  , validateWithModel
  , writeWith
  ) where

import Data.Maybe (fromMaybe)
import Data.Text (Text)
import HaskeLUI.Core
  ( Action
  , PropertyId (..)
  , Transaction (..)
  , UndoPolicy (..)
  , batchActions
  )
import HaskeLUI.Property
  ( PropertyTarget
  , asProperty
  , get
  , propertyId
  , (.=)
  )

data BindingIssue = BindingIssue
  { issueCode :: !Text
  , issueMessage :: !Text
  }
  deriving stock (Eq, Show)

data CommitPolicy
  = Live
  | OnEnter
  | OnBlur
  | OnEnterOrBlur
  | ExplicitApply
  deriving stock (Eq, Ord, Show)

data DraftSyncPolicy
  = RefreshIfPristine
  | PreserveLocalDraft
  | DetectConcurrentChange
  deriving stock (Eq, Ord, Show)

data EditTrigger
  = InputChanged
  | EnterPressed
  | FocusLost
  | ApplyRequested
  deriving stock (Eq, Ord, Show)

-- | The authoritative value is existential: a text control can edit a
-- formatted number without exposing that hidden number type at use sites.
data Binding model control where
  Binding
    :: Maybe PropertyId
    -> (model -> value)
    -> (value -> control)
    -> (control -> Either BindingIssue value)
    -> (value -> value -> Bool)
    -> [model -> value -> Either BindingIssue ()]
    -> (value -> Action model)
    -> CommitPolicy
    -> UndoPolicy
    -> DraftSyncPolicy
    -> Maybe Text
    -> Binding model control

data BindingOption model value control
  = WriteWithOption (value -> Action model)
  | AlsoWriteOption (value -> Action model)
  | ValidateWithOption (model -> value -> Either BindingIssue ())
  | EquivalentWithOption (value -> value -> Bool)
  | CommitPolicyOption !CommitPolicy
  | UndoPolicyOption !UndoPolicy
  | SyncPolicyOption !DraftSyncPolicy
  | TransactionLabelOption !Text

data BindingConfig model value = BindingConfig
  { configWrite :: value -> Action model
  , configAlsoWrite :: [value -> Action model]
  , configValidators :: [model -> value -> Either BindingIssue ()]
  , configEquivalent :: value -> value -> Bool
  , configCommit :: !CommitPolicy
  , configUndo :: !UndoPolicy
  , configSync :: !(Maybe DraftSyncPolicy)
  , configTransactionLabel :: !(Maybe Text)
  }

bind
  :: (Eq value, PropertyTarget target model value)
  => target
  -> Binding model value
bind target = bindWith target []

bindWith
  :: (Eq value, PropertyTarget target model value)
  => target
  -> [BindingOption model value value]
  -> Binding model value
bindWith targetSource =
  makeBinding
    (Just (propertyId target))
    (get target)
    id
    Right
    (target .=)
  where
    target = asProperty targetSource

data BindingCodec value control = BindingCodec
  (value -> control)
  (control -> Either BindingIssue value)

type TextCodec value = BindingCodec value Text

codec
  :: (value -> control)
  -> (control -> Either BindingIssue value)
  -> BindingCodec value control
codec = BindingCodec

textCodec
  :: (value -> Text)
  -> (Text -> Either BindingIssue value)
  -> TextCodec value
textCodec = codec

bindWithCodec
  :: (Eq value, PropertyTarget target model value)
  => target
  -> BindingCodec value control
  -> [BindingOption model value control]
  -> Binding model control
bindWithCodec targetSource (BindingCodec format parse) =
  makeBinding
    (Just (propertyId target))
    (get target)
    format
    parse
    (target .=)
  where
    target = asProperty targetSource

-- | Text-specialized spelling of 'BindingCodec'.
bindText
  :: (Eq value, PropertyTarget target model value)
  => target
  -> TextCodec value
  -> [BindingOption model value Text]
  -> Binding model Text
bindText = bindWithCodec

-- | Callback-style controlled state remains available when no useful model
-- property exists. The next view construction supplies a fresh current value.
controlled
  :: Eq control
  => control
  -> (control -> Action model)
  -> Binding model control
controlled current writer = controlledWith current writer []

controlledWith
  :: Eq control
  => control
  -> (control -> Action model)
  -> [BindingOption model control control]
  -> Binding model control
controlledWith current writer =
  makeBinding Nothing (const current) id Right writer

makeBinding
  :: Eq value
  => Maybe PropertyId
  -> (model -> value)
  -> (value -> control)
  -> (control -> Either BindingIssue value)
  -> (value -> Action model)
  -> [BindingOption model value control]
  -> Binding model control
makeBinding identifier reader formatter decoder defaultWrite options =
  Binding
    identifier
    reader
    formatter
    decoder
    finalConfig.configEquivalent
    finalConfig.configValidators
    writeActions
    finalConfig.configCommit
    finalConfig.configUndo
    resolvedSyncPolicy
    finalConfig.configTransactionLabel
  where
    initialConfig =
      BindingConfig
        { configWrite = defaultWrite
        , configAlsoWrite = []
        , configValidators = []
        , configEquivalent = (==)
        , configCommit = Live
        , configUndo = NoUndo
        , configSync = Nothing
        , configTransactionLabel =
            (\propertyIdentifier -> "Edit " <> unPropertyId propertyIdentifier) <$> identifier
        }
    finalConfig = foldl' applyBindingOption initialConfig options
    resolvedSyncPolicy =
      fromMaybe (defaultSyncPolicy finalConfig.configCommit) finalConfig.configSync
    writeActions value =
      batchActions
        (fromMaybe "Edit controlled value" finalConfig.configTransactionLabel)
        ( finalConfig.configWrite value
            : fmap ($ value) finalConfig.configAlsoWrite
        )

applyBindingOption
  :: BindingConfig model value
  -> BindingOption model value control
  -> BindingConfig model value
applyBindingOption config option =
  case option of
    WriteWithOption writer -> config {configWrite = writer}
    AlsoWriteOption writer ->
      config {configAlsoWrite = config.configAlsoWrite <> [writer]}
    ValidateWithOption validator ->
      config {configValidators = config.configValidators <> [validator]}
    EquivalentWithOption equivalent -> config {configEquivalent = equivalent}
    CommitPolicyOption policy -> config {configCommit = policy}
    UndoPolicyOption policy -> config {configUndo = policy}
    SyncPolicyOption policy -> config {configSync = Just policy}
    TransactionLabelOption description ->
      config {configTransactionLabel = Just description}

writeWith
  :: (value -> Action model)
  -> BindingOption model value control
writeWith = WriteWithOption

alsoWrite
  :: (value -> Action model)
  -> BindingOption model value control
alsoWrite = AlsoWriteOption

validateWith
  :: (value -> Either BindingIssue ())
  -> BindingOption model value control
validateWith validator = ValidateWithOption (const validator)

-- | Add a pure synchronous validator that can inspect other authoritative
-- model state. Validators that perform IO belong in the separate async layer.
validateWithModel
  :: (model -> value -> Either BindingIssue ())
  -> BindingOption model value control
validateWithModel = ValidateWithOption

equivalentWith
  :: (value -> value -> Bool)
  -> BindingOption model value control
equivalentWith = EquivalentWithOption

commitPolicy :: CommitPolicy -> BindingOption model value control
commitPolicy = CommitPolicyOption

undoPolicy :: UndoPolicy -> BindingOption model value control
undoPolicy = UndoPolicyOption

syncPolicy :: DraftSyncPolicy -> BindingOption model value control
syncPolicy = SyncPolicyOption

labelTransaction :: Text -> BindingOption model value control
labelTransaction = TransactionLabelOption

bindingPropertyId :: Binding model control -> Maybe PropertyId
bindingPropertyId (Binding identifier _ _ _ _ _ _ _ _ _ _) = identifier

bindingCommitPolicy :: Binding model control -> CommitPolicy
bindingCommitPolicy (Binding _ _ _ _ _ _ _ policy _ _ _) = policy

bindingUndoPolicy :: Binding model control -> UndoPolicy
bindingUndoPolicy (Binding _ _ _ _ _ _ _ _ policy _ _) = policy

bindingSyncPolicy :: Binding model control -> DraftSyncPolicy
bindingSyncPolicy (Binding _ _ _ _ _ _ _ _ _ policy _) = policy

bindingTransactionDescription :: Binding model control -> Maybe Text
bindingTransactionDescription (Binding _ _ _ _ _ _ _ _ _ _ description) = description

readBinding :: Binding model control -> model -> control
readBinding (Binding _ reader formatter _ _ _ _ _ _ _ _) = formatter . reader

validateBinding :: model -> Binding model control -> control -> [BindingIssue]
validateBinding model (Binding _ _ _ decoder _ validators _ _ _ _ _) draft =
  case decoder draft of
    Left issue -> [issue]
    Right value -> validationIssues validators model value

data EditDecision model control
  = DraftStaged !control
  | DraftInvalid !control ![BindingIssue]
  | EditCommitted !control !(Transaction model)

editBinding
  :: model
  -> EditTrigger
  -> Binding model control
  -> control
  -> EditDecision model control
editBinding
  model
  trigger
  (Binding _ _ _ decoder _ validators writer policy undo _ description)
  draft =
    case decoder draft of
      Left issue -> DraftInvalid draft [issue]
      Right value ->
        case validationIssues validators model value of
          []
            | shouldCommit policy trigger ->
                EditCommitted
                  draft
                  Transaction
                    { transactionAction = writer value
                    , transactionUndo = undo
                    , transactionDescription = description
                    , transactionEffects = []
                    }
            | otherwise -> DraftStaged draft
          issues -> DraftInvalid draft issues

validationIssues
  :: [model -> value -> Either BindingIssue ()]
  -> model
  -> value
  -> [BindingIssue]
validationIssues validators model value =
  [issue | validator <- validators, Left issue <- [validator model value]]

shouldCommit :: CommitPolicy -> EditTrigger -> Bool
shouldCommit Live InputChanged = True
shouldCommit Live _ = False
shouldCommit OnEnter EnterPressed = True
shouldCommit OnEnter _ = False
shouldCommit OnBlur FocusLost = True
shouldCommit OnBlur _ = False
shouldCommit OnEnterOrBlur EnterPressed = True
shouldCommit OnEnterOrBlur FocusLost = True
shouldCommit OnEnterOrBlur _ = False
shouldCommit ExplicitApply ApplyRequested = True
shouldCommit ExplicitApply _ = False

defaultSyncPolicy :: CommitPolicy -> DraftSyncPolicy
defaultSyncPolicy Live = RefreshIfPristine
defaultSyncPolicy _ = DetectConcurrentChange

data BindingConflict control = BindingConflict
  { conflictOriginal :: !control
  , conflictLocalDraft :: !control
  , conflictAuthoritative :: !control
  }
  deriving stock (Eq, Show)

data DraftSyncResult control
  = DraftPreserved !control
  | DraftRefreshed !control
  | DraftConflictDetected !(BindingConflict control)
  deriving stock (Eq, Show)

data DraftBaseline model control where
  DraftBaseline
    :: (model -> value)
    -> (value -> control)
    -> (control -> Either BindingIssue value)
    -> (value -> value -> Bool)
    -> DraftSyncPolicy
    -> value
    -> DraftBaseline model control

captureDraftBaseline
  :: Binding model control
  -> model
  -> DraftBaseline model control
captureDraftBaseline
  (Binding _ reader formatter decoder equivalent _ _ _ _ policy _)
  model =
    DraftBaseline reader formatter decoder equivalent policy (reader model)

reconcileDraft
  :: DraftBaseline model control
  -> model
  -> control
  -> DraftSyncResult control
reconcileDraft
  (DraftBaseline reader formatter decoder equivalent policy original)
  model
  localDraft
    | equivalent authoritative original = DraftPreserved localDraft
    | localMatchesAuthoritative = DraftPreserved localDraft
    | otherwise =
        case policy of
          PreserveLocalDraft -> DraftPreserved localDraft
          RefreshIfPristine
            | localIsPristine -> DraftRefreshed authoritativeControl
            | otherwise -> DraftPreserved localDraft
          DetectConcurrentChange
            | localIsPristine -> DraftRefreshed authoritativeControl
            | otherwise ->
                DraftConflictDetected
                  BindingConflict
                    { conflictOriginal = formatter original
                    , conflictLocalDraft = localDraft
                    , conflictAuthoritative = authoritativeControl
                    }
  where
    authoritative = reader model
    authoritativeControl = formatter authoritative
    decodedLocal = decoder localDraft
    localIsPristine =
      case decodedLocal of
        Right localValue -> equivalent localValue original
        Left _ -> False
    localMatchesAuthoritative =
      case decodedLocal of
        Right localValue -> equivalent localValue authoritative
        Left _ -> False
