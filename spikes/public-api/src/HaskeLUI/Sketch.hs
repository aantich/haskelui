{-# LANGUAGE GADTs #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

module HaskeLUI.Sketch
  ( Action
  , App (..)
  , AsyncValidation
  , AsyncValidationOption
  , AsyncValidationResult (..)
  , Binding
  , BindingConflict (..)
  , BindingIssue (..)
  , BindingOption
  , ButtonOption
  , CommandId (..)
  , CommandOption
  , CommandSpec
  , Component
  , Effect
  , EffectId (..)
  , Event
  , EventId (..)
  , CommitPolicy (..)
  , DraftBaseline
  , DraftSyncPolicy (..)
  , DraftSyncResult (..)
  , EditDecision (..)
  , EditTrigger (..)
  , FocusKey (..)
  , Menu
  , Milliseconds (..)
  , Path
  , PendingCommitPolicy (..)
  , Property
  , PropertyTarget
  , Scene
  , SceneKey (..)
  , Shortcut (..)
  , Subscription
  , TextCodec
  , TextFieldOption
  , Transaction (..)
  , UndoGroup (..)
  , UndoPolicy (..)
  , View
  , ValidationId (..)
  , WindowOption
  , WindowSpec
  , WindowKey (..)
  , appWindowCount
  , alsoWrite
  , applyAction
  , applyTransaction
  , asProperty
  , asyncValidation
  , batch
  , bind
  , bindText
  , bindWith
  , button
  , checkbox
  , column
  , command
  , commandEnabled
  , commandIdentifier
  , commandItem
  , commandMenu
  , commitWhilePending
  , component
  , content
  , commitPolicy
  , controlled
  , controlEnabled
  , dialogScene
  , debounce
  , documentGroup
  , effect
  , editBinding
  , emit
  , enabledWhen
  , event
  , focusScope
  , get
  , handleCommand
  , invoke
  , label
  , labelTransaction
  , menuBar
  , modify
  , onClick
  , onCloseRequest
  , onFocus
  , opaque
  , placeholder
  , perform
  , rootPath
  , readBinding
  , reconcileDraft
  , row
  , sceneWindowCount
  , scopeAt
  , settingsScene
  , shortcut
  , start
  , subscription
  , syncPolicy
  , textArea
  , textCodec
  , textField
  , undoPolicy
  , validateWith
  , validationIdentifier
  , validateAsync
  , window
  , writeWith
  , captureDraftBaseline
  , (.=)
  ) where

import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import HaskeLUI.Property.Spike
  ( Action
  , Path
  , Property
  , asProperty
  , applyAction
  , batch
  , get
  , invokeNamed
  , modify
  , opaqueNamed
  , rootPath
  , startNamed
  , emitNamed
  , (.=)
  )

newtype SceneKey = SceneKey Text
  deriving stock (Eq, Ord, Show)

newtype WindowKey = WindowKey Text
  deriving stock (Eq, Ord, Show)

newtype FocusKey = FocusKey Text
  deriving stock (Eq, Ord, Show)

newtype CommandId = CommandId Text
  deriving stock (Eq, Ord, Show)

newtype EffectId = EffectId Text
  deriving stock (Eq, Ord, Show)

newtype EventId = EventId Text
  deriving stock (Eq, Ord, Show)

newtype Shortcut = Shortcut Text
  deriving stock (Eq, Ord, Show)

data App model = App
  { appInitial :: (model, [Action model])
  , appScenes :: model -> [Scene model]
  , appCommands :: model -> [CommandSpec model]
  , appSubscriptions :: model -> [Subscription model]
  }

data Scene model = Scene
  !SceneKey
  [WindowSpec model]

data WindowSpec model = WindowSpec
  !WindowKey
  !Text
  (View model)
  (Maybe (Action model))
  [Menu model]

data WindowOption model
  = ContentOption (View model)
  | CloseRequestOption (Action model)
  | MenuBarOption [Menu model]

window :: WindowKey -> Text -> [WindowOption model] -> WindowSpec model
window key title options =
  foldl' applyOption emptyWindow options
  where
    emptyWindow = WindowSpec key title (View 0) Nothing []

    applyOption (WindowSpec currentKey currentTitle currentContent currentClose currentMenus) option =
      case option of
        ContentOption newContent ->
          WindowSpec currentKey currentTitle newContent currentClose currentMenus
        CloseRequestOption closeAction ->
          WindowSpec currentKey currentTitle currentContent (Just closeAction) currentMenus
        MenuBarOption menus ->
          WindowSpec currentKey currentTitle currentContent currentClose menus

content :: View model -> WindowOption model
content = ContentOption

onCloseRequest :: Action model -> WindowOption model
onCloseRequest = CloseRequestOption

menuBar :: [Menu model] -> WindowOption model
menuBar = MenuBarOption

documentGroup :: SceneKey -> [WindowSpec model] -> Scene model
documentGroup = Scene

settingsScene :: WindowSpec model -> Scene model
settingsScene spec = Scene (SceneKey "settings") [spec]

dialogScene :: SceneKey -> WindowSpec model -> Scene model
dialogScene key spec = Scene key [spec]

sceneWindowCount :: Scene model -> Int
sceneWindowCount (Scene _ windows) = length windows

appWindowCount :: App model -> model -> Int
appWindowCount application model =
  sum (fmap sceneWindowCount (appScenes application model))

-- The phantom model parameter is the important part of this sketch. The
-- integer lets smoke tests inspect that a non-empty tree was built.
newtype View model = View Int

newtype Component model = Component (model -> View model)

component :: (model -> View model) -> Component model
component = Component

column :: [View model] -> View model
column children = View (1 + sum (fmap viewSize children))

row :: [View model] -> View model
row children = View (1 + sum (fmap viewSize children))

label :: Text -> View model
label _ = View 1

data ButtonOption model
  = ClickOption (Action model)
  | ButtonEnabledOption Bool

button :: Text -> [ButtonOption model] -> View model
button _ _ = View 1

onClick :: Action model -> ButtonOption model
onClick = ClickOption

controlEnabled :: Bool -> ButtonOption model
controlEnabled = ButtonEnabledOption

-- A binding deliberately hides the authoritative model value. A text
-- control may edit Text directly, or it may edit the textual representation
-- of an Int (or any other value) while retaining an invalid draft.
data Binding model control where
  Binding
    :: (model -> value)
    -> (value -> control)
    -> (control -> Either BindingIssue value)
    -> (value -> value -> Bool)
    -> [value -> Either BindingIssue ()]
    -> (value -> Action model)
    -> CommitPolicy
    -> UndoPolicy
    -> DraftSyncPolicy
    -> Maybe Text
    -> Binding model control

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
  deriving stock (Eq, Show)

newtype UndoGroup = UndoGroup Text
  deriving stock (Eq, Show)

data UndoPolicy
  = NoUndo
  | UndoEveryEdit
  | Coalesce !UndoGroup
  | SingleUndo !UndoGroup
  deriving stock (Eq, Show)

data DraftSyncPolicy
  = RefreshIfPristine
  | PreserveLocalDraft
  | DetectConcurrentChange
  deriving stock (Eq, Show)

-- A committed edit is an explicit pure transaction description. Runtime
-- origin information (element, scene, and document scope) is attached when
-- the control dispatches it.
data Transaction model = Transaction
  { transactionAction :: !(Action model)
  , transactionUndo :: !UndoPolicy
  , transactionDescription :: !(Maybe Text)
  }

applyTransaction :: Transaction model -> model -> model
applyTransaction transaction = applyAction transaction.transactionAction

data EditTrigger
  = InputChanged
  | EnterPressed
  | FocusLost
  | ApplyRequested
  deriving stock (Eq, Show)

-- Draft values belong to the retained element, not the application model.
-- A real runtime stores DraftStaged and DraftInvalid values in an
-- ElementProperty and dispatches only EditCommitted actions.
data EditDecision model control
  = DraftStaged !control
  | DraftInvalid !control ![BindingIssue]
  | EditCommitted !control !(Transaction model)

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

-- The existential baseline retains a typed authoritative value without
-- exposing that hidden type through Binding's public control-value surface.
data DraftBaseline model control where
  DraftBaseline
    :: (model -> value)
    -> (value -> control)
    -> (control -> Either BindingIssue value)
    -> (value -> value -> Bool)
    -> DraftSyncPolicy
    -> value
    -> DraftBaseline model control

data BindingOption model value control
  = WriteWithOption (value -> Action model)
  | AlsoWriteOption (value -> Action model)
  | ValidateWithOption (value -> Either BindingIssue ())
  | CommitPolicyOption !CommitPolicy
  | UndoPolicyOption !UndoPolicy
  | SyncPolicyOption !DraftSyncPolicy
  | TransactionLabelOption !Text

data BindingConfig model value = BindingConfig
  { configWrite :: value -> Action model
  , configAlsoWrite :: [value -> Action model]
  , configValidators :: [value -> Either BindingIssue ()]
  , configCommit :: !CommitPolicy
  , configUndo :: !UndoPolicy
  , configSync :: !(Maybe DraftSyncPolicy)
  , configTransactionLabel :: !(Maybe Text)
  }

-- Both an already named Property and the preferred dotted Path syntax are
-- accepted by binding constructors.
class PropertyTarget target model value | target -> model value where
  targetProperty :: target -> Property model value

instance PropertyTarget (Property model value) model value where
  targetProperty = id

instance PropertyTarget (Path model value) model value where
  targetProperty = asProperty

bind
  :: (Eq value, PropertyTarget target model value)
  => target
  -> Binding model value
bind target = bindWith target []

-- Callback-style controlled values remain available when there is no useful
-- model Property. The current value is captured while constructing the view;
-- the next model update constructs a fresh binding.
controlled
  :: Eq control
  => control
  -> (control -> Action model)
  -> Binding model control
controlled currentValue writer =
  Binding
    (const currentValue)
    id
    Right
    (==)
    []
    writer
    Live
    NoUndo
    RefreshIfPristine
    Nothing

bindWith
  :: (Eq value, PropertyTarget target model value)
  => target
  -> [BindingOption model value value]
  -> Binding model value
bindWith targetSource =
  makeBinding
    (get target)
    id
    Right
    (target .=)
  where
    target = targetProperty targetSource

data TextCodec value = TextCodec
  (value -> Text)
  (Text -> Either BindingIssue value)

textCodec
  :: (value -> Text)
  -> (Text -> Either BindingIssue value)
  -> TextCodec value
textCodec = TextCodec

bindText
  :: (Eq value, PropertyTarget target model value)
  => target
  -> TextCodec value
  -> [BindingOption model value Text]
  -> Binding model Text
bindText targetSource (TextCodec format parse) =
  makeBinding
    (get target)
    format
    parse
    (target .=)
  where
    target = targetProperty targetSource

makeBinding
  :: Eq value
  => (model -> value)
  -> (value -> control)
  -> (control -> Either BindingIssue value)
  -> (value -> Action model)
  -> [BindingOption model value control]
  -> Binding model control
makeBinding reader formatter decoder defaultWrite options =
  Binding
    reader
    formatter
    decoder
    (==)
    finalConfig.configValidators
    writeTransaction
    finalConfig.configCommit
    finalConfig.configUndo
    resolvedSyncPolicy
    finalConfig.configTransactionLabel
  where
    finalConfig = foldl' applyBindingOption initialConfig options

    initialConfig =
      BindingConfig
        { configWrite = defaultWrite
        , configAlsoWrite = []
        , configValidators = []
        , configCommit = Live
        , configUndo = NoUndo
        , configSync = Nothing
        , configTransactionLabel = Nothing
        }

    resolvedSyncPolicy =
      case finalConfig.configSync of
        Just policy -> policy
        Nothing -> defaultSyncPolicy finalConfig.configCommit

    writeTransaction newValue =
      batch
        ( finalConfig.configWrite newValue
            : fmap ($ newValue) finalConfig.configAlsoWrite
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
validateWith = ValidateWithOption

commitPolicy :: CommitPolicy -> BindingOption model value control
commitPolicy = CommitPolicyOption

undoPolicy :: UndoPolicy -> BindingOption model value control
undoPolicy = UndoPolicyOption

syncPolicy :: DraftSyncPolicy -> BindingOption model value control
syncPolicy = SyncPolicyOption

labelTransaction :: Text -> BindingOption model value control
labelTransaction = TransactionLabelOption

readBinding :: Binding model control -> model -> control
readBinding (Binding reader formatter _ _ _ _ _ _ _ _) = formatter . reader

editBinding
  :: EditTrigger
  -> Binding model control
  -> control
  -> EditDecision model control
editBinding trigger (Binding _ _ decoder _ validators writer policy undo _ description) draft =
  case decoder draft of
    Left issue -> DraftInvalid draft [issue]
    Right modelValue ->
      case validationIssues validators modelValue of
        []
          | shouldCommit policy trigger ->
              EditCommitted
                draft
                Transaction
                  { transactionAction = writer modelValue
                  , transactionUndo = undo
                  , transactionDescription = description
                  }
          | otherwise -> DraftStaged draft
        issues -> DraftInvalid draft issues

validationIssues
  :: [value -> Either BindingIssue ()]
  -> value
  -> [BindingIssue]
validationIssues validators modelValue =
  [ issue
  | validator <- validators
  , Left issue <- [validator modelValue]
  ]

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

captureDraftBaseline
  :: Binding model control
  -> model
  -> DraftBaseline model control
captureDraftBaseline
  (Binding reader formatter decoder equivalent _ _ _ _ policy _)
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
    | localIsPristine = DraftRefreshed authoritativeControl
    | otherwise =
        case policy of
          RefreshIfPristine -> DraftPreserved localDraft
          PreserveLocalDraft -> DraftPreserved localDraft
          DetectConcurrentChange ->
            DraftConflictDetected
              BindingConflict
                { conflictOriginal = formatter original
                , conflictLocalDraft = localDraft
                , conflictAuthoritative = authoritativeControl
                }
  where
    authoritative = reader model
    authoritativeControl = formatter authoritative
    localIsPristine =
      case decoder localDraft of
        Right localValue -> equivalent localValue original
        Left _ -> False

newtype ValidationId = ValidationId Text
  deriving stock (Eq, Show)

newtype Milliseconds = Milliseconds Int
  deriving stock (Eq, Show)

data PendingCommitPolicy
  = BlockCommit
  | OptimisticCommit
  | AdvisoryOnly
  deriving stock (Eq, Show)

data AsyncValidationResult
  = AsyncValid
  | AsyncInvalid !BindingIssue
  deriving stock (Eq, Show)

-- Async validation is intentionally not part of Binding. Its IO is visible
-- in the constructor signature and is interpreted with element ownership,
-- revision checks, cancellation, and stale-result suppression by the runtime.
data AsyncValidation control where
  AsyncValidation
    :: ValidationId
    -> (control -> Either BindingIssue request)
    -> (request -> IO response)
    -> (response -> AsyncValidationResult)
    -> Milliseconds
    -> PendingCommitPolicy
    -> AsyncValidation control

data AsyncValidationOption
  = DebounceOption !Milliseconds
  | PendingCommitOption !PendingCommitPolicy

data AsyncValidationConfig = AsyncValidationConfig
  { asyncDebounce :: !Milliseconds
  , asyncPendingCommit :: !PendingCommitPolicy
  }

asyncValidation
  :: ValidationId
  -> (control -> Either BindingIssue request)
  -> (request -> IO response)
  -> (response -> AsyncValidationResult)
  -> [AsyncValidationOption]
  -> AsyncValidation control
asyncValidation identifier prepare run interpret options =
  AsyncValidation
    identifier
    prepare
    run
    interpret
    finalConfig.asyncDebounce
    finalConfig.asyncPendingCommit
  where
    finalConfig = foldl' applyAsyncValidationOption initialConfig options
    initialConfig = AsyncValidationConfig (Milliseconds 0) BlockCommit

applyAsyncValidationOption
  :: AsyncValidationConfig
  -> AsyncValidationOption
  -> AsyncValidationConfig
applyAsyncValidationOption config option =
  case option of
    DebounceOption duration -> config {asyncDebounce = duration}
    PendingCommitOption policy -> config {asyncPendingCommit = policy}

debounce :: Milliseconds -> AsyncValidationOption
debounce = DebounceOption

commitWhilePending :: PendingCommitPolicy -> AsyncValidationOption
commitWhilePending = PendingCommitOption

validationIdentifier :: AsyncValidation control -> ValidationId
validationIdentifier (AsyncValidation identifier _ _ _ _ _) = identifier

-- Presentation and control-specific options will live here. Value ownership
-- is intentionally not duplicated in this list; it belongs to Binding.
data TextFieldOption model
  = PlaceholderOption !Text
  | AsyncValidatorOption !(AsyncValidation Text)

placeholder :: Text -> TextFieldOption model
placeholder = PlaceholderOption

validateAsync :: AsyncValidation Text -> TextFieldOption model
validateAsync = AsyncValidatorOption

textField :: Binding model Text -> [TextFieldOption model] -> View model
textField _ _ = View 1

textArea :: Binding model Text -> [TextFieldOption model] -> View model
textArea _ _ = View 1

checkbox :: Text -> Binding model Bool -> View model
checkbox _ _ = View 1

focusScope :: FocusKey -> View model -> View model
focusScope _ = id

onFocus :: Action model -> View model -> View model
onFocus _ = id

handleCommand :: CommandId -> Action model -> View model -> View model
handleCommand _ _ = id

viewSize :: View model -> Int
viewSize (View size) = size

-- A keyed child exists only while the key is present. A production runtime
-- would lift every child action through the keyed collection property and
-- diagnose a callback that arrives after removal.
scopeAt
  :: Ord key
  => Property parent (Map key child)
  -> key
  -> Component child
  -> parent
  -> View parent
scopeAt collection key (Component renderChild) parent =
  case Map.lookup key (get collection parent) of
    Nothing -> View 0
    Just child -> eraseModel (renderChild child)

eraseModel :: View child -> View parent
eraseModel (View size) = View size

data Menu model = Menu !Text [CommandId]

commandMenu :: Text -> [CommandId] -> Menu model
commandMenu = Menu

commandItem :: CommandId -> CommandId
commandItem = id

data CommandSpec model = CommandSpec
  !CommandId
  !Text
  (Maybe Shortcut)
  !Bool
  (Maybe (Action model))

data CommandOption model
  = ShortcutOption Shortcut
  | CommandEnabledOption Bool
  | PerformOption (Action model)

command :: CommandId -> Text -> [CommandOption model] -> CommandSpec model
command identifier title options =
  foldl' applyOption emptyCommand options
  where
    emptyCommand = CommandSpec identifier title Nothing True Nothing

    applyOption (CommandSpec currentId currentTitle currentShortcut currentEnabled currentAction) option =
      case option of
        ShortcutOption newShortcut ->
          CommandSpec currentId currentTitle (Just newShortcut) currentEnabled currentAction
        CommandEnabledOption enabled ->
          CommandSpec currentId currentTitle currentShortcut enabled currentAction
        PerformOption action ->
          CommandSpec currentId currentTitle currentShortcut currentEnabled (Just action)

shortcut :: Shortcut -> CommandOption model
shortcut = ShortcutOption

commandEnabled :: CommandSpec model -> Bool
commandEnabled (CommandSpec _ _ _ enabled _) = enabled

commandIdentifier :: CommandSpec model -> CommandId
commandIdentifier (CommandSpec identifier _ _ _ _) = identifier

perform :: Action model -> CommandOption model
perform = PerformOption

enabledWhen :: Bool -> CommandOption model
enabledWhen = CommandEnabledOption

invoke :: CommandId -> Action model
invoke (CommandId identifier) = invokeNamed identifier

data Effect model input output = Effect
  !EffectId
  (input -> IO output)
  (output -> Action model)

effect
  :: EffectId
  -> (input -> IO output)
  -> (output -> Action model)
  -> Effect model input output
effect = Effect

start :: Effect model input output -> input -> Action model
start (Effect (EffectId identifier) _ _) _ = startNamed identifier

data Event model payload = Event
  !EventId
  (payload -> model -> model)

event :: EventId -> (payload -> model -> model) -> Event model payload
event = Event

emit :: Event model payload -> payload -> Action model
emit (Event (EventId identifier) _) _ = emitNamed identifier

newtype Subscription model = Subscription Text

subscription :: Text -> Subscription model
subscription = Subscription

opaque :: Text -> Action model
opaque = opaqueNamed
