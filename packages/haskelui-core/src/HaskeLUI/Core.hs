{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

module HaskeLUI.Core
  ( module HaskeLUI.Diagnostics
  , module HaskeLUI.Drawing
  , module HaskeLUI.Graphics.Types
  , module HaskeLUI.Layout
  , Action
  , App (..)
  , AppView (..)
  , AttributedText
  , ActionControlSpec (..)
  , Axis (..)
  , BreadcrumbSpec (..)
  , CatalogControlKind (..)
  , ChoiceControlSpec (..)
  , ChoiceItem (..)
  , ChoiceKey (..)
  , ColorControlSpec (..)
  , CollectionControlSpec (..)
  , CollectionItem (..)
  , CollectionItemKey (..)
  , CollectionRowSizing (..)
  , CollectionSelectionMode (..)
  , CommandId (..)
  , CommandSpec (..)
  , ContainerKind (..)
  , ContainerSpec (..)
  , LayoutContainerPresentation (..)
  , LayoutContainerSpec (..)
  , Control (..)
  , ControlLabel (..)
  , DrawingSurfaceSpec (..)
  , DateComponents (..)
  , DateControlSpec (..)
  , DocumentKey (..)
  , Effect (..)
  , EffectKey (..)
  , ElementKey (..)
  , EventCoalescingKey (..)
  , EventDelivery (..)
  , ExceptionSummary (..)
  , ExternalEvent
  , ExternalSink (..)
  , FileSystemEntry (..)
  , FileSystemEntryKind (..)
  , ImageControlSpec (..)
  , ImageSource (..)
  , MenuControlSpec (..)
  , MenuEntry (..)
  , MessageControlSpec (..)
  , NumericControlSpec (..)
  , PaneKey (..)
  , PaneRole (..)
  , PaneSizing (..)
  , PaneState (..)
  , PaneTree (..)
  , PaneVisibility (..)
  , PresentationActionId (..)
  , PresentationActionRole (..)
  , PresentationActionSpec (..)
  , PresentationKind (..)
  , PresentationResult (..)
  , PresentationSpec (..)
  , ProgressControlSpec (..)
  , PropertyId (..)
  , RuntimeCommand (..)
  , RuntimeGeneration (..)
  , TaskKey (..)
  , TaskScope (..)
  , TaskStartPolicy (..)
  , TaskOptions (..)
  , TaskFailure (..)
  , TaskOutcome (..)
  , TaskCancellationRequested (..)
  , CancellationToken (..)
  , ServiceKey (..)
  , ServiceEndpoint (..)
  , ServiceContext (..)
  , Service (..)
  , ServiceOptions (..)
  , ServiceHealth (..)
  , ServiceStatus (..)
  , ServiceExit (..)
  , ServiceSendResult (..)
  , RestartPolicy (..)
  , BackoffPolicy (..)
  , OverflowPolicy (..)
  , SubscriptionKey (..)
  , SubscriptionFingerprint (..)
  , Subscription (..)
  , SubscriptionStop
  , LifetimeKey (..)
  , RichTextSpec (..)
  , SplitButtonSpec (..)
  , TextEditorSpec (..)
  , TextLayer (..)
  , TextLayerKey (..)
  , TextNavigationKey (..)
  , TextNavigationRequest (..)
  , TextRange (..)
  , TextRevision (..)
  , TextRun (..)
  , TextSpan (..)
  , TextInputSpec (..)
  , TimeComponents (..)
  , TimeControlSpec (..)
  , ToggleControlSpec (..)
  , ToggleValue (..)
  , ToolbarSpec (..)
  , TabPageSpec (..)
  , TabViewSpec (..)
  , TabGroupKey (..)
  , TabKey (..)
  , Transaction (..)
  , UIEvent (..)
  , UndoGroup (..)
  , UndoPolicy (..)
  , WindowKey (..)
  , WindowSpec (..)
  , WorkspaceItemContent (..)
  , WorkspaceItemKey (..)
  , WorkspaceItemSpec (..)
  , WorkspacePaneSpec (..)
  , WorkspaceSpec (..)
  , WorkspaceTabGroupSpec (..)
  , WorkspaceTabSpec (..)
  , SplitKey (..)
  , SplitOrientation (..)
  , action
  , actionDescription
  , actionPropertyIds
  , actionWithProperties
  , appendRuntimeCommands
  , applyAction
  , applyTransaction
  , attributedTextFromRuns
  , attributedTextFromSpans
  , attributedTextSpans
  , attributedTextToRuns
  , attributedTextValue
  , batchActions
  , controlChildren
  , controlCatalogKind
  , controlFrame
  , controlKey
  , controlIntrinsicMetrics
  , setControlFrame
  , resolveControlLayouts
  , resolveControlLayoutsWithAllocations
  , resolveAppViewLayouts
  , resolveAppViewLayoutsWith
  , resolveAppViewLayoutsWithAllocations
  , flattenControls
  , noTransaction
  , cancelScope
  , cancelTask
  , closeLifetime
  , defaultBackoffPolicy
  , defaultServiceOptions
  , defaultTaskOptions
  , emitExternalEvent
  , externalEvent
  , externalEventDelivery
  , externalEventDescription
  , handleExternalEvent
  , latestExternalEvent
  , openLifetime
  , requestEffect
  , requestRuntimeCommand
  , restartService
  , resolveTextLayers
  , nextTabAfterRemoval
  , validateWorkspaceSpec
  , validateControlCatalog
  , windowLeafControls
  , windowWorkspace
  , workspaceTabKeys
  , transaction
  , transactionFromAction
  , transactionFromActionWithEffects
  , transactionFromActionWithCommands
  , transactionWithCommands
  , transactionWithEffects
  , service
  , serviceDescription
  , serviceEndpointKey
  , serviceKey
  , serviceWithStatus
  , sendService
  , sendServiceWithResult
  , simpleApp
  , startTask
  , startTaskWith
  , subscription
  , subscriptionFingerprint
  , subscriptionKey
  , throwIfCancelled
  ) where

import Control.Applicative ((<|>))
import Control.Exception (Exception, throwIO)
import Data.List (group, sort)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (listToMaybe, mapMaybe)
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Typeable (Typeable)
import Data.Word (Word64)
import HaskeLUI.Drawing
import HaskeLUI.Diagnostics
import HaskeLUI.Graphics.Types
import HaskeLUI.Layout

newtype WindowKey = WindowKey {unWindowKey :: Word64}
  deriving stock (Eq, Ord, Show)

newtype DocumentKey = DocumentKey {unDocumentKey :: Word64}
  deriving stock (Eq, Ord, Show)

newtype ElementKey = ElementKey {unElementKey :: Word64}
  deriving stock (Eq, Ord, Show)

newtype PaneKey = PaneKey {unPaneKey :: Word64}
  deriving stock (Eq, Ord, Show)

newtype SplitKey = SplitKey {unSplitKey :: Word64}
  deriving stock (Eq, Ord, Show)

newtype WorkspaceItemKey = WorkspaceItemKey {unWorkspaceItemKey :: Word64}
  deriving stock (Eq, Ord, Show)

newtype TabGroupKey = TabGroupKey {unTabGroupKey :: Word64}
  deriving stock (Eq, Ord, Show)

newtype TabKey = TabKey {unTabKey :: Word64}
  deriving stock (Eq, Ord, Show)

newtype CommandId = CommandId {unCommandId :: Word64}
  deriving stock (Eq, Ord, Show)

newtype EffectKey = EffectKey {unEffectKey :: Word64}
  deriving stock (Eq, Ord, Show)

-- | Stable identities used by the asynchronous runtime. Textual keys are
-- intentionally easy to namespace and useful in diagnostics.
newtype TaskKey = TaskKey {unTaskKey :: Text}
  deriving stock (Eq, Ord, Show)

newtype ServiceKey = ServiceKey {unServiceKey :: Text}
  deriving stock (Eq, Ord, Show)

newtype SubscriptionKey = SubscriptionKey {unSubscriptionKey :: Text}
  deriving stock (Eq, Ord, Show)

newtype LifetimeKey = LifetimeKey {unLifetimeKey :: Text}
  deriving stock (Eq, Ord, Show)

newtype EventCoalescingKey = EventCoalescingKey {unEventCoalescingKey :: Text}
  deriving stock (Eq, Ord, Show)

newtype SubscriptionFingerprint = SubscriptionFingerprint {unSubscriptionFingerprint :: Text}
  deriving stock (Eq, Ord, Show)

newtype RuntimeGeneration = RuntimeGeneration {unRuntimeGeneration :: Word64}
  deriving stock (Eq, Ord, Show)

-- | Stable identity for an authoritative application-model property. Actions
-- retain these values for diagnostics and eventual undo/change tracking.
newtype PropertyId = PropertyId {unPropertyId :: Text}
  deriving stock (Eq, Ord, Show)

newtype TextRevision = TextRevision {unTextRevision :: Word64}
  deriving stock (Eq, Ord, Show)

newtype TextLayerKey = TextLayerKey {unTextLayerKey :: Word64}
  deriving stock (Eq, Ord, Show)

newtype TextNavigationKey = TextNavigationKey {unTextNavigationKey :: Word64}
  deriving stock (Eq, Ord, Show)

newtype ChoiceKey = ChoiceKey {unChoiceKey :: Word64}
  deriving stock (Eq, Ord, Show)

newtype CollectionItemKey = CollectionItemKey {unCollectionItemKey :: Word64}
  deriving stock (Eq, Ord, Show)

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

-- | A revision-bound, one-shot request to reveal a text range. The stable key
-- lets retained backends apply the request only once even when unrelated model
-- updates reconcile the editor again. Applications advance the key when the
-- same logical destination should be revealed a second time.
data TextNavigationRequest = TextNavigationRequest
  { textNavigationKey :: !TextNavigationKey
  , textNavigationRevision :: !TextRevision
  , textNavigationRange :: !TextRange
  , textNavigationSelect :: !Bool
  , textNavigationFocus :: !Bool
  }
  deriving stock (Eq, Show)

data TextEditorSpec = TextEditorSpec
  { textEditorKey :: !ElementKey
  , textEditorFrame :: !Rect
  , textEditorText :: !Text
  , textEditorRevision :: !TextRevision
  , textEditorBaseStyle :: !TextStyle
  , textEditorLayers :: ![TextLayer]
  , textEditorNavigation :: !(Maybe TextNavigationRequest)
  , textEditorFocused :: !Bool
  }
  deriving stock (Eq, Show)

data Axis
  = Horizontal
  | Vertical
  deriving stock (Eq, Ord, Show)

data ControlLabel = ControlLabel
  { controlLabelText :: !Text
  , controlLabelIcon :: !(Maybe ImageSource)
  }
  deriving stock (Eq, Show)

data ImageSource
  = SystemSymbol !Text
  | NamedImage !Text
  | FileImage !FilePath
  deriving stock (Eq, Show)

data ToggleValue
  = ToggleOff
  | ToggleOn
  | ToggleMixed
  deriving stock (Eq, Ord, Show)

data CollectionSelectionMode
  = NoCollectionSelection
  | SingleCollectionSelection
  | MultipleCollectionSelection
  deriving stock (Eq, Ord, Show)

data ChoiceItem = ChoiceItem
  { choiceItemKey :: !ChoiceKey
  , choiceItemLabel :: !ControlLabel
  , choiceItemEnabled :: !Bool
  }
  deriving stock (Eq, Show)

data CollectionItem = CollectionItem
  { collectionItemKey :: !CollectionItemKey
  , collectionItemLabel :: !Text
  , collectionItemDetail :: !Text
  , collectionItemIcon :: !(Maybe ImageSource)
  , collectionItemDepth :: !Int
  , collectionItemExpandable :: !Bool
  , collectionItemExpanded :: !Bool
  }
  deriving stock (Eq, Show)

-- | The portable information returned by a one-level directory read. The
-- runtime deliberately does not recurse: applications decide which folders
-- to expand and when to request their children.
data FileSystemEntryKind
  = FileSystemFile
  | FileSystemDirectory
  deriving stock (Eq, Ord, Show)

data FileSystemEntry = FileSystemEntry
  { fileSystemEntryPath :: !FilePath
  , fileSystemEntryName :: !Text
  , fileSystemEntryKind :: !FileSystemEntryKind
  }
  deriving stock (Eq, Show)

data ActionControlSpec = ActionControlSpec
  { actionControlKey :: !ElementKey
  , actionControlFrame :: !Rect
  , actionControlLabel :: !ControlLabel
  , actionControlCommand :: !CommandId
  , actionControlEnabled :: !Bool
  }
  deriving stock (Eq, Show)

data ToggleControlSpec = ToggleControlSpec
  { toggleControlKey :: !ElementKey
  , toggleControlFrame :: !Rect
  , toggleControlLabel :: !ControlLabel
  , toggleControlValue :: !ToggleValue
  , toggleControlEnabled :: !Bool
  }
  deriving stock (Eq, Show)

data ChoiceControlSpec = ChoiceControlSpec
  { choiceControlKey :: !ElementKey
  , choiceControlFrame :: !Rect
  , choiceControlItems :: ![ChoiceItem]
  , choiceControlSelected :: !(Maybe ChoiceKey)
  , choiceControlEnabled :: !Bool
  }
  deriving stock (Eq, Show)

data SplitButtonSpec = SplitButtonSpec
  { splitButtonKey :: !ElementKey
  , splitButtonFrame :: !Rect
  , splitButtonLabel :: !ControlLabel
  , splitButtonCommand :: !CommandId
  , splitButtonItems :: ![MenuEntry]
  , splitButtonToggleValue :: !(Maybe Bool)
  , splitButtonEnabled :: !Bool
  }
  deriving stock (Eq, Show)

data TextInputSpec = TextInputSpec
  { textInputKey :: !ElementKey
  , textInputFrame :: !Rect
  , textInputText :: !Text
  , textInputPlaceholder :: !Text
  , textInputSuggestions :: ![ChoiceItem]
  , textInputEnabled :: !Bool
  , textInputFocused :: !Bool
  }
  deriving stock (Eq, Show)

data NumericControlSpec = NumericControlSpec
  { numericControlKey :: !ElementKey
  , numericControlFrame :: !Rect
  , numericControlValue :: !Double
  , numericControlMinimum :: !Double
  , numericControlMaximum :: !Double
  , numericControlStep :: !Double
  , numericControlEnabled :: !Bool
  }
  deriving stock (Eq, Show)

data DateComponents = DateComponents
  { dateYear :: !Int
  , dateMonth :: !Int
  , dateDay :: !Int
  }
  deriving stock (Eq, Ord, Show)

data TimeComponents = TimeComponents
  { timeHour :: !Int
  , timeMinute :: !Int
  , timeSecond :: !Int
  }
  deriving stock (Eq, Ord, Show)

data DateControlSpec = DateControlSpec
  { dateControlKey :: !ElementKey
  , dateControlFrame :: !Rect
  , dateControlValue :: !DateComponents
  , dateControlEnabled :: !Bool
  }
  deriving stock (Eq, Show)

data TimeControlSpec = TimeControlSpec
  { timeControlKey :: !ElementKey
  , timeControlFrame :: !Rect
  , timeControlValue :: !TimeComponents
  , timeControlEnabled :: !Bool
  }
  deriving stock (Eq, Show)

data ColorControlSpec = ColorControlSpec
  { colorControlKey :: !ElementKey
  , colorControlFrame :: !Rect
  , colorControlValue :: !Color
  , colorControlEnabled :: !Bool
  }
  deriving stock (Eq, Show)

data ProgressControlSpec = ProgressControlSpec
  { progressControlKey :: !ElementKey
  , progressControlFrame :: !Rect
  , progressControlValue :: !Double
  , progressControlMinimum :: !Double
  , progressControlMaximum :: !Double
  }
  deriving stock (Eq, Show)

data RichTextSpec = RichTextSpec
  { richTextKey :: !ElementKey
  , richTextFrame :: !Rect
  , richTextValue :: !AttributedText
  }
  deriving stock (Eq, Show)

data ImageControlSpec = ImageControlSpec
  { imageControlKey :: !ElementKey
  , imageControlFrame :: !Rect
  , imageControlSource :: !ImageSource
  , imageControlDescription :: !Text
  }
  deriving stock (Eq, Show)

-- | An immutable retained drawing surface. The revision is the cheap backend
-- reconciliation key; callers must advance it whenever the drawing changes.
data DrawingSurfaceSpec = DrawingSurfaceSpec
  { drawingSurfaceKey :: !ElementKey
  , drawingSurfaceFrame :: !Rect
  , drawingSurfaceRevision :: !DrawingRevision
  , drawingSurfaceDrawing :: !Drawing
  , drawingSurfaceIntrinsicMetrics :: !IntrinsicMetrics
  , drawingSurfaceAccessibleLabel :: !Text
  , drawingSurfaceInputMode :: !DrawingInputMode
  , drawingSurfaceHitTest :: !DrawingHitTest
  , drawingSurfaceCursor :: !DrawingCursor
  }
  deriving stock (Eq, Show)

data CollectionControlSpec = CollectionControlSpec
  { collectionControlKey :: !ElementKey
  , collectionControlFrame :: !Rect
  , collectionControlItems :: ![CollectionItem]
  , collectionControlSelectionMode :: !CollectionSelectionMode
  , collectionControlSelection :: ![CollectionItemKey]
  , collectionControlRowSizing :: !CollectionRowSizing
  , collectionControlEnabled :: !Bool
  }
  deriving stock (Eq, Show)

-- | Portable row-density policy for row-based collections.
--
-- 'PlatformDefaultRows' is deliberately the default policy: a native backend
-- follows the platform and user preference instead of baking a point height
-- into HaskeLUI. The semantic density choices also remain platform-owned; only
-- 'FixedRows' expresses an exact logical height.
data CollectionRowSizing
  = PlatformDefaultRows
  | CompactRows
  | StandardRows
  | SpaciousRows
  | FixedRows !Double
  | ContentSizedRows
  deriving stock (Eq, Show)

data BreadcrumbSpec = BreadcrumbSpec
  { breadcrumbKey :: !ElementKey
  , breadcrumbFrame :: !Rect
  , breadcrumbItems :: ![ChoiceItem]
  , breadcrumbSelected :: !(Maybe ChoiceKey)
  }
  deriving stock (Eq, Show)

data MenuEntry
  = MenuCommand
      { menuEntryLabel :: !Text
      , menuEntryCommand :: !CommandId
      , menuEntryEnabled :: !Bool
      }
  | MenuSeparator
  deriving stock (Eq, Show)

data MenuControlSpec = MenuControlSpec
  { menuControlKey :: !ElementKey
  , menuControlFrame :: !Rect
  , menuControlTitle :: !Text
  , menuControlEntries :: ![MenuEntry]
  }
  deriving stock (Eq, Show)

data ToolbarSpec = ToolbarSpec
  { toolbarKey :: !ElementKey
  , toolbarFrame :: !Rect
  , toolbarCommands :: ![CommandId]
  }
  deriving stock (Eq, Show)

data MessageControlSpec = MessageControlSpec
  { messageControlKey :: !ElementKey
  , messageControlFrame :: !Rect
  , messageControlTitle :: !Text
  , messageControlMessage :: !Text
  }
  deriving stock (Eq, Show)

data PresentationKind
  = DialogPresentation
  | AlertPresentation
  | PopoverPresentation !ElementKey
  deriving stock (Eq, Show)

newtype PresentationActionId = PresentationActionId {unPresentationActionId :: Word64}
  deriving stock (Eq, Ord, Show)

-- | Semantic button roles let each backend use its platform conventions for
-- ordering, keyboard equivalents, emphasis, and destructive styling.
data PresentationActionRole
  = DefaultPresentationAction
  | CancelPresentationAction
  | DestructivePresentationAction
  | AuxiliaryPresentationAction
  deriving stock (Eq, Ord, Show)

data PresentationActionSpec = PresentationActionSpec
  { presentationActionId :: !PresentationActionId
  , presentationActionTitle :: !Text
  , presentationActionRole :: !PresentationActionRole
  , presentationActionEnabled :: !Bool
  }
  deriving stock (Eq, Show)

data PresentationResult
  = PresentationActionSelected !PresentationActionId
  | PresentationAccepted
  | PresentationCancelled
  | PresentationDismissed
  deriving stock (Eq, Ord, Show)

data PresentationSpec = PresentationSpec
  { presentationKey :: !ElementKey
  , presentationFrame :: !Rect
  , presentationKind :: !PresentationKind
  , presentationTitle :: !Text
  , presentationMessage :: !Text
  , presentationActions :: ![PresentationActionSpec]
  , presentationVisible :: !Bool
  }
  deriving stock (Eq, Show)

data ContainerKind
  = StackContainer !Axis !Double
  | GridContainer !Int !Double
  | OverlayContainer
  | CanvasContainer
  | GroupContainer !Text
  | ScrollContainer
  | DisclosureContainer !Text !Bool
  deriving stock (Eq, Show)

data ContainerSpec = ContainerSpec
  { containerKey :: !ElementKey
  , containerFrame :: !Rect
  , containerKind :: !ContainerKind
  , containerChildren :: ![Control]
  }
  deriving stock (Eq, Show)

-- | Native presentation for a portable layout root.  Geometry beneath this
-- root is always solved by 'HaskeLUI.Layout'; the presentation only chooses the
-- native host semantics (plain, scrolling, grouping, or disclosure).
data LayoutContainerPresentation
  = PlainLayoutContainer
  | ScrollLayoutContainer !Axis
  | GroupLayoutContainer !Text
  | DisclosureLayoutContainer !Text !Bool
  deriving stock (Eq, Show)

-- | A portable layout tree references direct child controls by their stable
-- 'ElementKey'.  This keeps layout metadata independent from control data and
-- lets reconciliation retain each native peer while only its frame changes.
data LayoutContainerSpec = LayoutContainerSpec
  { layoutContainerKey :: !ElementKey
  , layoutContainerFrame :: !Rect
  , layoutContainerPresentation :: !LayoutContainerPresentation
  , layoutContainerEnvironment :: !LayoutEnvironment
  , layoutContainerLayout :: !(Layout ElementKey)
  , layoutContainerChildren :: ![Control]
  }
  deriving stock (Eq, Show)

data TabPageSpec = TabPageSpec
  { tabPageKey :: !ChoiceKey
  , tabPageTitle :: !Text
  , tabPageControls :: ![Control]
  }
  deriving stock (Eq, Show)

data TabViewSpec = TabViewSpec
  { tabViewKey :: !ElementKey
  , tabViewFrame :: !Rect
  , tabViewSelected :: !(Maybe ChoiceKey)
  , tabViewPages :: ![TabPageSpec]
  }
  deriving stock (Eq, Show)

-- | The backend-neutral catalog tags are useful for diagnostics and backend
-- conformance tables. Public construction still uses the distinct 'Control'
-- constructors below.
data CatalogControlKind
  = RichTextKind
  | ImageKind
  | IconKind
  | SeparatorKind
  | RepeatButtonKind
  | ToggleButtonKind
  | CheckBoxKind
  | RadioGroupKind
  | SwitchKind
  | SegmentedChoiceKind
  | LinkKind
  | MenuButtonKind
  | SplitButtonKind
  | ToggleSplitButtonKind
  | TextAreaKind
  | RichTextEditorKind
  | SecureFieldKind
  | SearchFieldKind
  | SuggestFieldKind
  | ChoicePickerKind
  | EditableComboBoxKind
  | NumberFieldKind
  | StepperKind
  | SliderKind
  | DatePickerKind
  | TimePickerKind
  | CalendarViewKind
  | ColorPickerKind
  | RatingKind
  | ListViewKind
  | CollectionViewKind
  | TreeViewKind
  | TableViewKind
  | ItemRepeaterKind
  | TabViewKind
  | BreadcrumbKind
  | NavigationSidebarKind
  | MenuBarKind
  | ContextMenuKind
  | ToolbarKind
  | DialogKind
  | AlertKind
  | PopoverKind
  | TooltipKind
  | ProgressBarKind
  | ActivityIndicatorKind
  | MeterKind
  | BadgeKind
  | InlineNoticeKind
  | ContainerKind
  deriving stock (Eq, Ord, Enum, Bounded, Show)

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
  | RichText !RichTextSpec
  | Image !ImageControlSpec
  | Icon !ImageControlSpec
  | DrawingSurface !DrawingSurfaceSpec
  | Separator !ElementKey !Rect
  | RepeatButton !ActionControlSpec
  | ToggleButton !ToggleControlSpec
  | CheckBox !ToggleControlSpec
  | RadioGroup !ChoiceControlSpec
  | Switch !ToggleControlSpec
  | SegmentedChoice !ChoiceControlSpec
  | Link !ActionControlSpec
  | MenuButton !ChoiceControlSpec
  | SplitButton !SplitButtonSpec
  | ToggleSplitButton !SplitButtonSpec
  | TextArea !TextInputSpec
  | RichTextEditor !TextEditorSpec
  | SecureField !TextInputSpec
  | SearchField !TextInputSpec
  | SuggestField !TextInputSpec
  | ChoicePicker !ChoiceControlSpec
  | EditableComboBox !TextInputSpec
  | NumberField !NumericControlSpec
  | Stepper !NumericControlSpec
  | Slider !NumericControlSpec
  | DatePicker !DateControlSpec
  | TimePicker !TimeControlSpec
  | CalendarView !DateControlSpec
  | ColorPicker !ColorControlSpec
  | Rating !NumericControlSpec
  | ListView !CollectionControlSpec
  | CollectionView !CollectionControlSpec
  | TreeView !CollectionControlSpec
  | TableView !CollectionControlSpec
  | ItemRepeater !CollectionControlSpec
  | TabView !TabViewSpec
  | Breadcrumb !BreadcrumbSpec
  | NavigationSidebar !CollectionControlSpec
  | MenuBar !MenuControlSpec
  | ContextMenu !MenuControlSpec
  | Toolbar !ToolbarSpec
  | Dialog !PresentationSpec
  | Alert !PresentationSpec
  | Popover !PresentationSpec
  | Tooltip !MessageControlSpec
  | ProgressBar !ProgressControlSpec
  | ActivityIndicator !ElementKey !Rect !Bool
  | Meter !ProgressControlSpec
  | Badge !MessageControlSpec
  | InlineNotice !MessageControlSpec
  | Container !ContainerSpec
  | LayoutContainer !LayoutContainerSpec
  deriving stock (Eq, Show)

controlKey :: Control -> ElementKey
controlKey = \case
  Label key _ _ -> key
  Button key _ _ _ _ -> key
  TextField key _ _ _ _ -> key
  TextEditor spec -> spec.textEditorKey
  RichText spec -> spec.richTextKey
  Image spec -> spec.imageControlKey
  Icon spec -> spec.imageControlKey
  DrawingSurface spec -> spec.drawingSurfaceKey
  Separator key _ -> key
  RepeatButton spec -> spec.actionControlKey
  ToggleButton spec -> spec.toggleControlKey
  CheckBox spec -> spec.toggleControlKey
  RadioGroup spec -> spec.choiceControlKey
  Switch spec -> spec.toggleControlKey
  SegmentedChoice spec -> spec.choiceControlKey
  Link spec -> spec.actionControlKey
  MenuButton spec -> spec.choiceControlKey
  SplitButton spec -> spec.splitButtonKey
  ToggleSplitButton spec -> spec.splitButtonKey
  TextArea spec -> spec.textInputKey
  RichTextEditor spec -> spec.textEditorKey
  SecureField spec -> spec.textInputKey
  SearchField spec -> spec.textInputKey
  SuggestField spec -> spec.textInputKey
  ChoicePicker spec -> spec.choiceControlKey
  EditableComboBox spec -> spec.textInputKey
  NumberField spec -> spec.numericControlKey
  Stepper spec -> spec.numericControlKey
  Slider spec -> spec.numericControlKey
  DatePicker spec -> spec.dateControlKey
  TimePicker spec -> spec.timeControlKey
  CalendarView spec -> spec.dateControlKey
  ColorPicker spec -> spec.colorControlKey
  Rating spec -> spec.numericControlKey
  ListView spec -> spec.collectionControlKey
  CollectionView spec -> spec.collectionControlKey
  TreeView spec -> spec.collectionControlKey
  TableView spec -> spec.collectionControlKey
  ItemRepeater spec -> spec.collectionControlKey
  TabView spec -> spec.tabViewKey
  Breadcrumb spec -> spec.breadcrumbKey
  NavigationSidebar spec -> spec.collectionControlKey
  MenuBar spec -> spec.menuControlKey
  ContextMenu spec -> spec.menuControlKey
  Toolbar spec -> spec.toolbarKey
  Dialog spec -> spec.presentationKey
  Alert spec -> spec.presentationKey
  Popover spec -> spec.presentationKey
  Tooltip spec -> spec.messageControlKey
  ProgressBar spec -> spec.progressControlKey
  ActivityIndicator key _ _ -> key
  Meter spec -> spec.progressControlKey
  Badge spec -> spec.messageControlKey
  InlineNotice spec -> spec.messageControlKey
  Container spec -> spec.containerKey
  LayoutContainer spec -> spec.layoutContainerKey

controlFrame :: Control -> Rect
controlFrame = \case
  Label _ frame _ -> frame
  Button _ frame _ _ _ -> frame
  TextField _ frame _ _ _ -> frame
  TextEditor spec -> spec.textEditorFrame
  RichText spec -> spec.richTextFrame
  Image spec -> spec.imageControlFrame
  Icon spec -> spec.imageControlFrame
  DrawingSurface spec -> spec.drawingSurfaceFrame
  Separator _ frame -> frame
  RepeatButton spec -> spec.actionControlFrame
  ToggleButton spec -> spec.toggleControlFrame
  CheckBox spec -> spec.toggleControlFrame
  RadioGroup spec -> spec.choiceControlFrame
  Switch spec -> spec.toggleControlFrame
  SegmentedChoice spec -> spec.choiceControlFrame
  Link spec -> spec.actionControlFrame
  MenuButton spec -> spec.choiceControlFrame
  SplitButton spec -> spec.splitButtonFrame
  ToggleSplitButton spec -> spec.splitButtonFrame
  TextArea spec -> spec.textInputFrame
  RichTextEditor spec -> spec.textEditorFrame
  SecureField spec -> spec.textInputFrame
  SearchField spec -> spec.textInputFrame
  SuggestField spec -> spec.textInputFrame
  ChoicePicker spec -> spec.choiceControlFrame
  EditableComboBox spec -> spec.textInputFrame
  NumberField spec -> spec.numericControlFrame
  Stepper spec -> spec.numericControlFrame
  Slider spec -> spec.numericControlFrame
  DatePicker spec -> spec.dateControlFrame
  TimePicker spec -> spec.timeControlFrame
  CalendarView spec -> spec.dateControlFrame
  ColorPicker spec -> spec.colorControlFrame
  Rating spec -> spec.numericControlFrame
  ListView spec -> spec.collectionControlFrame
  CollectionView spec -> spec.collectionControlFrame
  TreeView spec -> spec.collectionControlFrame
  TableView spec -> spec.collectionControlFrame
  ItemRepeater spec -> spec.collectionControlFrame
  TabView spec -> spec.tabViewFrame
  Breadcrumb spec -> spec.breadcrumbFrame
  NavigationSidebar spec -> spec.collectionControlFrame
  MenuBar spec -> spec.menuControlFrame
  ContextMenu spec -> spec.menuControlFrame
  Toolbar spec -> spec.toolbarFrame
  Dialog spec -> spec.presentationFrame
  Alert spec -> spec.presentationFrame
  Popover spec -> spec.presentationFrame
  Tooltip spec -> spec.messageControlFrame
  ProgressBar spec -> spec.progressControlFrame
  ActivityIndicator _ frame _ -> frame
  Meter spec -> spec.progressControlFrame
  Badge spec -> spec.messageControlFrame
  InlineNotice spec -> spec.messageControlFrame
  Container spec -> spec.containerFrame
  LayoutContainer spec -> spec.layoutContainerFrame

-- | Replace only the geometric frame of a control.  All semantic state and
-- stable identity are preserved, which is essential for retained focus and
-- native editor state during layout-only reconciliation.
setControlFrame :: Rect -> Control -> Control
setControlFrame frame = \case
  Label key _ value -> Label key frame value
  Button key _ title command enabled -> Button key frame title command enabled
  TextField key _ value placeholder focused -> TextField key frame value placeholder focused
  TextEditor spec -> TextEditor spec {textEditorFrame = frame}
  RichText spec -> RichText spec {richTextFrame = frame}
  Image spec -> Image spec {imageControlFrame = frame}
  Icon spec -> Icon spec {imageControlFrame = frame}
  DrawingSurface spec -> DrawingSurface spec {drawingSurfaceFrame = frame}
  Separator key _ -> Separator key frame
  RepeatButton spec -> RepeatButton spec {actionControlFrame = frame}
  ToggleButton spec -> ToggleButton spec {toggleControlFrame = frame}
  CheckBox spec -> CheckBox spec {toggleControlFrame = frame}
  RadioGroup spec -> RadioGroup spec {choiceControlFrame = frame}
  Switch spec -> Switch spec {toggleControlFrame = frame}
  SegmentedChoice spec -> SegmentedChoice spec {choiceControlFrame = frame}
  Link spec -> Link spec {actionControlFrame = frame}
  MenuButton spec -> MenuButton spec {choiceControlFrame = frame}
  SplitButton spec -> SplitButton spec {splitButtonFrame = frame}
  ToggleSplitButton spec -> ToggleSplitButton spec {splitButtonFrame = frame}
  TextArea spec -> TextArea spec {textInputFrame = frame}
  RichTextEditor spec -> RichTextEditor spec {textEditorFrame = frame}
  SecureField spec -> SecureField spec {textInputFrame = frame}
  SearchField spec -> SearchField spec {textInputFrame = frame}
  SuggestField spec -> SuggestField spec {textInputFrame = frame}
  ChoicePicker spec -> ChoicePicker spec {choiceControlFrame = frame}
  EditableComboBox spec -> EditableComboBox spec {textInputFrame = frame}
  NumberField spec -> NumberField spec {numericControlFrame = frame}
  Stepper spec -> Stepper spec {numericControlFrame = frame}
  Slider spec -> Slider spec {numericControlFrame = frame}
  DatePicker spec -> DatePicker spec {dateControlFrame = frame}
  TimePicker spec -> TimePicker spec {timeControlFrame = frame}
  CalendarView spec -> CalendarView spec {dateControlFrame = frame}
  ColorPicker spec -> ColorPicker spec {colorControlFrame = frame}
  Rating spec -> Rating spec {numericControlFrame = frame}
  ListView spec -> ListView spec {collectionControlFrame = frame}
  CollectionView spec -> CollectionView spec {collectionControlFrame = frame}
  TreeView spec -> TreeView spec {collectionControlFrame = frame}
  TableView spec -> TableView spec {collectionControlFrame = frame}
  ItemRepeater spec -> ItemRepeater spec {collectionControlFrame = frame}
  TabView spec -> TabView spec {tabViewFrame = frame}
  Breadcrumb spec -> Breadcrumb spec {breadcrumbFrame = frame}
  NavigationSidebar spec -> NavigationSidebar spec {collectionControlFrame = frame}
  MenuBar spec -> MenuBar spec {menuControlFrame = frame}
  ContextMenu spec -> ContextMenu spec {menuControlFrame = frame}
  Toolbar spec -> Toolbar spec {toolbarFrame = frame}
  Dialog spec -> Dialog spec {presentationFrame = frame}
  Alert spec -> Alert spec {presentationFrame = frame}
  Popover spec -> Popover spec {presentationFrame = frame}
  Tooltip spec -> Tooltip spec {messageControlFrame = frame}
  ProgressBar spec -> ProgressBar spec {progressControlFrame = frame}
  ActivityIndicator key _ active -> ActivityIndicator key frame active
  Meter spec -> Meter spec {progressControlFrame = frame}
  Badge spec -> Badge spec {messageControlFrame = frame}
  InlineNotice spec -> InlineNotice spec {messageControlFrame = frame}
  Container spec -> Container spec {containerFrame = frame}
  LayoutContainer spec -> LayoutContainer spec {layoutContainerFrame = frame}

-- | Frame-based fallback metrics keep old controls usable before a backend has
-- populated its native measurement cache.  Backends should override these
-- values with fitting sizes whenever possible.
controlIntrinsicMetrics :: Control -> IntrinsicMetrics
controlIntrinsicMetrics (DrawingSurface spec) = spec.drawingSurfaceIntrinsicMetrics
controlIntrinsicMetrics control =
  let frame = controlFrame control
      ideal = Size (Dp (max 0 frame.rectWidth)) (Dp (max 0 frame.rectHeight))
      baseline = Just (ideal.sizeHeight * 0.75)
   in IntrinsicMetrics (Size 0 0) ideal ideal baseline baseline

-- | Solve every portable layout root in a control forest.  Frames produced by
-- the layout engine use a top-left local coordinate system; the AppKit host for
-- a 'LayoutContainer' is correspondingly flipped.
resolveControlLayouts
  :: Map ElementKey IntrinsicMetrics
  -> [Control]
  -> ([Control], [LayoutDiagnostic ElementKey])
resolveControlLayouts supplied =
  resolveControlLayoutsWithAllocations supplied Map.empty

-- | Solve portable layout roots using the space actually allocated by the
-- host backend.  An allocation replaces only the width and height of the
-- declared container frame; its origin remains an application-level placement
-- concern.  Backends should call this whenever a retained native layout host
-- changes size, rather than exposing resize bookkeeping to application models.
resolveControlLayoutsWithAllocations
  :: Map ElementKey IntrinsicMetrics
  -> Map ElementKey Size
  -> [Control]
  -> ([Control], [LayoutDiagnostic ElementKey])
resolveControlLayoutsWithAllocations supplied allocations controls =
  let resolved = fmap resolveOne controls
   in (fmap fst resolved, foldMap snd resolved)
  where
    resolveOne :: Control -> (Control, [LayoutDiagnostic ElementKey])
    resolveOne = \case
      LayoutContainer spec ->
        let declaredFrame = spec.layoutContainerFrame
            frame =
              case Map.lookup spec.layoutContainerKey allocations of
                Nothing -> declaredFrame
                Just allocated ->
                  declaredFrame
                    { rectWidth = max 0 (unDp allocated.sizeWidth)
                    , rectHeight = max 0 (unDp allocated.sizeHeight)
                    }
            headerHeight =
              case spec.layoutContainerPresentation of
                GroupLayoutContainer _ -> 30
                DisclosureLayoutContainer _ _ -> 30
                _ -> 0
            contentHeight = max 0 (frame.rectHeight - headerHeight)
            childDefaults =
              Map.fromList
                [ (controlKey child, controlIntrinsicMetrics child)
                | child <- spec.layoutContainerChildren
                ]
            measurements = supplied `Map.union` childDefaults
            plan =
              solveLayout
                spec.layoutContainerEnvironment
                (metricsMeasurer measurements)
                (LayoutRect 0 0 (Dp (max 0 frame.rectWidth)) (Dp contentHeight))
                spec.layoutContainerLayout
            declaredLayoutKeys = Set.fromList (layoutLeafKeys spec.layoutContainerLayout)
            resolveChild child =
              let key = controlKey child
                  visibility = Map.findWithDefault Visible key plan.layoutVisibility
                  framed =
                    case Map.lookup key plan.layoutFrames of
                      Nothing
                        | key `Set.member` declaredLayoutKeys -> setControlFrame (Rect 0 0 0 0) child
                        | otherwise -> child
                      Just layoutFrame ->
                        setControlFrame
                          ( if visibility == Collapsed
                              then Rect (unDp layoutFrame.layoutX) (unDp layoutFrame.layoutY) 0 0
                              else Rect
                                (unDp layoutFrame.layoutX)
                                (unDp layoutFrame.layoutY)
                                (unDp layoutFrame.layoutWidth)
                                (unDp layoutFrame.layoutHeight)
                          )
                          child
               in resolveOne framed
            children = fmap resolveChild spec.layoutContainerChildren
            updated =
              LayoutContainer
                spec
                  { layoutContainerFrame = frame
                  , layoutContainerChildren = fmap fst children
                  }
         in (updated, plan.layoutDiagnostics <> foldMap snd children)
      Container spec ->
        let children = fmap resolveOne spec.containerChildren
         in (Container spec {containerChildren = fmap fst children}, foldMap snd children)
      TabView spec ->
        let resolvePage page =
              let children = fmap resolveOne page.tabPageControls
               in (page {tabPageControls = fmap fst children}, foldMap snd children)
            pages = fmap resolvePage spec.tabViewPages
         in (TabView spec {tabViewPages = fmap fst pages}, foldMap snd pages)
      control -> (control, [])

controlChildren :: Control -> [Control]
controlChildren (Container spec) = spec.containerChildren
controlChildren (LayoutContainer spec) = spec.layoutContainerChildren
controlChildren (TabView spec) = foldMap tabPageControls spec.tabViewPages
controlChildren _ = []

flattenControls :: [Control] -> [Control]
flattenControls = foldMap flattenOne
  where
    flattenOne control = control : flattenControls (controlChildren control)

controlCatalogKind :: Control -> Maybe CatalogControlKind
controlCatalogKind = \case
  Label {} -> Nothing
  Button {} -> Nothing
  TextField {} -> Nothing
  TextEditor {} -> Nothing
  RichText {} -> Just RichTextKind
  Image {} -> Just ImageKind
  Icon {} -> Just IconKind
  DrawingSurface {} -> Nothing
  Separator {} -> Just SeparatorKind
  RepeatButton {} -> Just RepeatButtonKind
  ToggleButton {} -> Just ToggleButtonKind
  CheckBox {} -> Just CheckBoxKind
  RadioGroup {} -> Just RadioGroupKind
  Switch {} -> Just SwitchKind
  SegmentedChoice {} -> Just SegmentedChoiceKind
  Link {} -> Just LinkKind
  MenuButton {} -> Just MenuButtonKind
  SplitButton {} -> Just SplitButtonKind
  ToggleSplitButton {} -> Just ToggleSplitButtonKind
  TextArea {} -> Just TextAreaKind
  RichTextEditor {} -> Just RichTextEditorKind
  SecureField {} -> Just SecureFieldKind
  SearchField {} -> Just SearchFieldKind
  SuggestField {} -> Just SuggestFieldKind
  ChoicePicker {} -> Just ChoicePickerKind
  EditableComboBox {} -> Just EditableComboBoxKind
  NumberField {} -> Just NumberFieldKind
  Stepper {} -> Just StepperKind
  Slider {} -> Just SliderKind
  DatePicker {} -> Just DatePickerKind
  TimePicker {} -> Just TimePickerKind
  CalendarView {} -> Just CalendarViewKind
  ColorPicker {} -> Just ColorPickerKind
  Rating {} -> Just RatingKind
  ListView {} -> Just ListViewKind
  CollectionView {} -> Just CollectionViewKind
  TreeView {} -> Just TreeViewKind
  TableView {} -> Just TableViewKind
  ItemRepeater {} -> Just ItemRepeaterKind
  TabView {} -> Just TabViewKind
  Breadcrumb {} -> Just BreadcrumbKind
  NavigationSidebar {} -> Just NavigationSidebarKind
  MenuBar {} -> Just MenuBarKind
  ContextMenu {} -> Just ContextMenuKind
  Toolbar {} -> Just ToolbarKind
  Dialog {} -> Just DialogKind
  Alert {} -> Just AlertKind
  Popover {} -> Just PopoverKind
  Tooltip {} -> Just TooltipKind
  ProgressBar {} -> Just ProgressBarKind
  ActivityIndicator {} -> Just ActivityIndicatorKind
  Meter {} -> Just MeterKind
  Badge {} -> Just BadgeKind
  InlineNotice {} -> Just InlineNoticeKind
  Container {} -> Just ContainerKind
  LayoutContainer {} -> Just ContainerKind

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

data PaneRole
  = SidebarPane
  | ContentPane
  | InspectorPane
  | AuxiliaryPane
  deriving stock (Eq, Ord, Show)

data SplitOrientation
  = SideBySide
  | Stacked
  deriving stock (Eq, Ord, Show)

data PaneVisibility
  = PaneVisible
  | PaneCollapsed
  deriving stock (Eq, Ord, Show)

data PaneSizing = PaneSizing
  { paneMinimumExtent :: !(Maybe Double)
  , panePreferredExtent :: !(Maybe Double)
  , paneMaximumExtent :: !(Maybe Double)
  , paneStretchWeight :: !Double
  }
  deriving stock (Eq, Show)

data PaneState = PaneState
  { paneVisibility :: !PaneVisibility
  , paneExtent :: !(Maybe Double)
  }
  deriving stock (Eq, Show)

data WorkspaceTabSpec = WorkspaceTabSpec
  { workspaceTabKey :: !TabKey
  , workspaceTabDocument :: !(Maybe DocumentKey)
  , workspaceTabTitle :: !Text
  , workspaceTabModified :: !Bool
  , workspaceTabCloseable :: !Bool
  , workspaceTabControls :: ![Control]
  }
  deriving stock (Eq, Show)

data WorkspaceTabGroupSpec = WorkspaceTabGroupSpec
  { workspaceTabGroupKey :: !TabGroupKey
  , workspaceSelectedTab :: !(Maybe TabKey)
  , workspaceTabs :: ![WorkspaceTabSpec]
  }
  deriving stock (Eq, Show)

data WorkspaceItemContent
  = WorkspaceItemControls ![Control]
  | WorkspaceItemTabGroup !WorkspaceTabGroupSpec
  deriving stock (Eq, Show)

data WorkspaceItemSpec = WorkspaceItemSpec
  { workspaceItemKey :: !WorkspaceItemKey
  , workspaceItemContent :: !WorkspaceItemContent
  }
  deriving stock (Eq, Show)

data WorkspacePaneSpec = WorkspacePaneSpec
  { workspacePaneKey :: !PaneKey
  , workspacePaneRole :: !PaneRole
  , workspacePaneSizing :: !PaneSizing
  , workspacePaneState :: !PaneState
  , workspacePaneItem :: !WorkspaceItemSpec
  }
  deriving stock (Eq, Show)

data PaneTree
  = WorkspacePane !WorkspacePaneSpec
  | WorkspaceSplit !SplitKey !SplitOrientation !PaneTree !PaneTree ![PaneTree]
  deriving stock (Eq, Show)

data WorkspaceSpec = WorkspaceSpec
  { workspaceRoot :: !PaneTree
  , workspaceStatusControls :: ![Control]
  }
  deriving stock (Eq, Show)

data WindowSpec
  = WindowSpec
      { windowKey :: !WindowKey
      , windowTitle :: !Text
      , windowFrame :: !Rect
      , windowControls :: ![Control]
      }
  | WorkspaceWindowSpec
      { windowKey :: !WindowKey
      , windowTitle :: !Text
      , windowFrame :: !Rect
      , windowWorkspaceSpec :: !WorkspaceSpec
      }
  deriving stock (Eq, Show)

windowWorkspace :: WindowSpec -> Maybe WorkspaceSpec
windowWorkspace WindowSpec {} = Nothing
windowWorkspace WorkspaceWindowSpec {windowWorkspaceSpec = spec} = Just spec

windowLeafControls :: WindowSpec -> [Control]
windowLeafControls WindowSpec {windowControls = controls} = flattenControls controls
windowLeafControls WorkspaceWindowSpec {windowWorkspaceSpec = spec} =
  flattenControls (workspaceControls spec)

workspaceControls :: WorkspaceSpec -> [Control]
workspaceControls spec = paneTreeControls spec.workspaceRoot <> spec.workspaceStatusControls

paneTreeControls :: PaneTree -> [Control]
paneTreeControls (WorkspacePane pane) = workspaceItemControls pane.workspacePaneItem
paneTreeControls (WorkspaceSplit _ _ first second rest) =
  foldMap paneTreeControls (first : second : rest)

workspaceItemControls :: WorkspaceItemSpec -> [Control]
workspaceItemControls item =
  case item.workspaceItemContent of
    WorkspaceItemControls controls -> controls
    WorkspaceItemTabGroup tabGroup -> foldMap workspaceTabControls tabGroup.workspaceTabs

workspaceTabKeys :: WorkspaceSpec -> [TabKey]
workspaceTabKeys = foldMap (fmap workspaceTabKey . workspaceTabs) . workspaceTabGroups

workspaceTabGroups :: WorkspaceSpec -> [WorkspaceTabGroupSpec]
workspaceTabGroups = paneTreeTabGroups . workspaceRoot

paneTreeTabGroups :: PaneTree -> [WorkspaceTabGroupSpec]
paneTreeTabGroups (WorkspacePane pane) =
  case pane.workspacePaneItem.workspaceItemContent of
    WorkspaceItemControls _ -> []
    WorkspaceItemTabGroup tabGroup -> [tabGroup]
paneTreeTabGroups (WorkspaceSplit _ _ first second rest) =
  foldMap paneTreeTabGroups (first : second : rest)

nextTabAfterRemoval :: TabKey -> [TabKey] -> Maybe TabKey
nextTabAfterRemoval removed keys =
  case break (== removed) keys of
    (_, []) -> listToMaybe keys
    (before, _ : after) -> listToMaybe after <|> listToMaybe (reverse before)

validateWorkspaceSpec :: WorkspaceSpec -> [Text]
validateWorkspaceSpec spec =
  duplicateDiagnostics "workspace item" itemIdentities
    <> duplicateDiagnostics "tab" tabIdentities
    <> concatMap validateGroup groups
    <> validatePaneTree spec.workspaceRoot
    <> validateControlCatalog (workspaceControls spec)
  where
    panes = paneTreePanes spec.workspaceRoot
    groups = workspaceTabGroups spec
    itemIdentities = fmap (show . unWorkspaceItemKey . workspaceItemKey . workspacePaneItem) panes
    tabIdentities = fmap (show . unTabKey) (workspaceTabKeys spec)
    validateGroup :: WorkspaceTabGroupSpec -> [Text]
    validateGroup tabGroup =
      case tabGroup.workspaceSelectedTab of
        Nothing -> []
        Just selected
          | selected `elem` fmap workspaceTabKey tabGroup.workspaceTabs -> []
          | otherwise -> ["Workspace tab group selects an undeclared tab: " <> Text.pack (show selected)]

paneTreePanes :: PaneTree -> [WorkspacePaneSpec]
paneTreePanes (WorkspacePane pane) = [pane]
paneTreePanes (WorkspaceSplit _ _ first second rest) =
  foldMap paneTreePanes (first : second : rest)

validatePaneTree :: PaneTree -> [Text]
validatePaneTree (WorkspacePane pane) = validatePane pane
validatePaneTree (WorkspaceSplit _ _ first second rest) =
  foldMap validatePaneTree (first : second : rest)

validatePane :: WorkspacePaneSpec -> [Text]
validatePane pane =
  [ "Pane extents and stretch weights must be nonnegative: " <> Text.pack (show pane.workspacePaneKey)
  | any (< 0) extents || pane.workspacePaneSizing.paneStretchWeight < 0
  ]
    <> [ "Pane minimum extent exceeds its maximum extent: " <> Text.pack (show pane.workspacePaneKey)
       | Just minimumValue <- [pane.workspacePaneSizing.paneMinimumExtent]
       , Just maximumValue <- [pane.workspacePaneSizing.paneMaximumExtent]
       , minimumValue > maximumValue
       ]
  where
    extents =
      mapMaybe
        id
        [ pane.workspacePaneSizing.paneMinimumExtent
        , pane.workspacePaneSizing.panePreferredExtent
        , pane.workspacePaneSizing.paneMaximumExtent
        , pane.workspacePaneState.paneExtent
        ]

duplicateDiagnostics :: Text -> [String] -> [Text]
duplicateDiagnostics label values =
  [ "Duplicate " <> label <> " identity: " <> Text.pack value
  | duplicates <- group (sort values)
  , value : _ : _ <- [duplicates]
  ]

validateControlCatalog :: [Control] -> [Text]
validateControlCatalog roots =
  duplicateDiagnostics
    "control"
    (fmap (show . unElementKey . controlKey) controls)
    <> foldMap validateControl controls
  where
    controls = flattenControls roots

validateControl :: Control -> [Text]
validateControl control =
  validateFrame (controlKey control) (controlFrame control)
    <> case control of
      RadioGroup spec -> validateChoice spec
      SegmentedChoice spec -> validateChoice spec
      MenuButton spec -> validateChoice spec
      ChoicePicker spec -> validateChoice spec
      NumberField spec -> validateNumeric spec
      Stepper spec -> validateNumeric spec
      Slider spec -> validateNumeric spec
      Rating spec -> validateNumeric spec
      DatePicker spec -> validateDate spec.dateControlKey spec.dateControlValue
      CalendarView spec -> validateDate spec.dateControlKey spec.dateControlValue
      TimePicker spec -> validateTime spec.timeControlKey spec.timeControlValue
      ListView spec -> validateCollection spec
      CollectionView spec -> validateCollection spec <> validateNonRowCollection "CollectionView" spec
      TreeView spec -> validateCollection spec
      TableView spec -> validateCollection spec
      ItemRepeater spec -> validateCollection spec <> validateNonRowCollection "ItemRepeater" spec
      NavigationSidebar spec -> validateCollection spec
      TabView spec -> validateTabs spec
      Breadcrumb spec ->
        validateChoice
          ChoiceControlSpec
            { choiceControlKey = spec.breadcrumbKey
            , choiceControlFrame = spec.breadcrumbFrame
            , choiceControlItems = spec.breadcrumbItems
            , choiceControlSelected = spec.breadcrumbSelected
            , choiceControlEnabled = True
            }
      ProgressBar spec -> validateProgress spec
      Meter spec -> validateProgress spec
      Dialog spec -> validatePresentation spec
      Alert spec -> validatePresentation spec
      Popover spec -> validatePresentation spec
      DrawingSurface spec ->
        [ "Invalid drawing surface "
            <> Text.pack (show spec.drawingSurfaceKey)
            <> ": "
            <> drawingValidationMessage drawingError
        | drawingError <- validateDrawing spec.drawingSurfaceDrawing
        ]
          <> [ "Invalid drawing surface interaction "
                <> Text.pack (show spec.drawingSurfaceKey)
                <> ": "
                <> drawingValidationMessage drawingError
             | drawingError <- validateDrawingHitTest spec.drawingSurfaceHitTest
             ]
      Container spec -> validateContainer spec
      LayoutContainer spec -> validateLayoutContainer spec
      _ -> []

validatePresentation :: PresentationSpec -> [Text]
validatePresentation spec =
  duplicateDiagnostics
    "presentation action"
    (fmap (show . unPresentationActionId . presentationActionId) spec.presentationActions)
    <> [ "Presentation has more than one default action: "
          <> Text.pack (show spec.presentationKey)
       | actionCount DefaultPresentationAction > 1
       ]
    <> [ "Presentation has more than one cancel action: "
          <> Text.pack (show spec.presentationKey)
       | actionCount CancelPresentationAction > 1
       ]
    <> [ "Presentation action titles must not be empty: "
          <> Text.pack (show spec.presentationKey)
       | any (Text.null . Text.strip . presentationActionTitle) spec.presentationActions
       ]
  where
    actionCount role =
      length
        [ ()
        | presentationAction <- spec.presentationActions
        , presentationAction.presentationActionRole == role
        ]

validateFrame :: ElementKey -> Rect -> [Text]
validateFrame key frame =
  [ "Control frames must have nonnegative width and height: " <> Text.pack (show key)
  | frame.rectWidth < 0 || frame.rectHeight < 0
  ]

validateChoice :: ChoiceControlSpec -> [Text]
validateChoice spec =
  duplicateDiagnostics
    "choice item"
    (fmap (show . unChoiceKey . choiceItemKey) spec.choiceControlItems)
    <> [ "Choice control selects an undeclared item: " <> Text.pack (show spec.choiceControlKey)
       | Just selected <- [spec.choiceControlSelected]
       , selected `notElem` fmap choiceItemKey spec.choiceControlItems
       ]

validateNumeric :: NumericControlSpec -> [Text]
validateNumeric spec =
  [ "Numeric control has invalid bounds, value, or step: "
      <> Text.pack (show spec.numericControlKey)
  | spec.numericControlMinimum > spec.numericControlMaximum
      || spec.numericControlValue < spec.numericControlMinimum
      || spec.numericControlValue > spec.numericControlMaximum
      || spec.numericControlStep <= 0
  ]

validateDate :: ElementKey -> DateComponents -> [Text]
validateDate key value =
  [ "Date control has invalid Gregorian components: " <> Text.pack (show key)
  | value.dateMonth < 1
      || value.dateMonth > 12
      || value.dateDay < 1
      || value.dateDay > 31
  ]

validateTime :: ElementKey -> TimeComponents -> [Text]
validateTime key value =
  [ "Time control has invalid components: " <> Text.pack (show key)
  | value.timeHour < 0
      || value.timeHour > 23
      || value.timeMinute < 0
      || value.timeMinute > 59
      || value.timeSecond < 0
      || value.timeSecond > 59
  ]

validateCollection :: CollectionControlSpec -> [Text]
validateCollection spec =
  duplicateDiagnostics
    "collection item"
    (fmap (show . unCollectionItemKey . collectionItemKey) spec.collectionControlItems)
    <> [ "Collection item depth must be nonnegative: "
          <> Text.pack (show item.collectionItemKey)
       | item <- spec.collectionControlItems
       , item.collectionItemDepth < 0
       ]
    <> [ "Collection selection contains an undeclared item: "
          <> Text.pack (show selected)
       | selected <- spec.collectionControlSelection
       , selected `notElem` fmap collectionItemKey spec.collectionControlItems
       ]
    <> [ "A no-selection collection cannot declare selected items: "
          <> Text.pack (show spec.collectionControlKey)
       | spec.collectionControlSelectionMode == NoCollectionSelection
       , not (null spec.collectionControlSelection)
       ]
    <> [ "A single-selection collection cannot select multiple items: "
          <> Text.pack (show spec.collectionControlKey)
       | spec.collectionControlSelectionMode == SingleCollectionSelection
       , length spec.collectionControlSelection > 1
       ]
    <> [ "A fixed collection row height must be finite and greater than zero: "
          <> Text.pack (show spec.collectionControlKey)
       | FixedRows height <- [spec.collectionControlRowSizing]
       , isNaN height || isInfinite height || height <= 0
       ]

validateNonRowCollection :: Text -> CollectionControlSpec -> [Text]
validateNonRowCollection controlName spec =
  [ controlName <> " does not use row sizing: " <> Text.pack (show spec.collectionControlKey)
  | spec.collectionControlRowSizing /= PlatformDefaultRows
  ]

validateTabs :: TabViewSpec -> [Text]
validateTabs spec =
  duplicateDiagnostics
    "tab page"
    (fmap (show . unChoiceKey . tabPageKey) spec.tabViewPages)
    <> [ "Tab view selects an undeclared page: " <> Text.pack (show spec.tabViewKey)
       | Just selected <- [spec.tabViewSelected]
       , selected `notElem` fmap tabPageKey spec.tabViewPages
       ]

validateProgress :: ProgressControlSpec -> [Text]
validateProgress spec =
  [ "Progress control has invalid bounds or value: "
      <> Text.pack (show spec.progressControlKey)
  | spec.progressControlMinimum > spec.progressControlMaximum
      || spec.progressControlValue < spec.progressControlMinimum
      || spec.progressControlValue > spec.progressControlMaximum
  ]

validateContainer :: ContainerSpec -> [Text]
validateContainer spec =
  case spec.containerKind of
    GridContainer columns spacing ->
      [ "Grid containers require a positive column count and nonnegative spacing: "
          <> Text.pack (show spec.containerKey)
      | columns <= 0 || spacing < 0
      ]
    StackContainer _ spacing ->
      [ "Stack spacing must be nonnegative: " <> Text.pack (show spec.containerKey)
      | spacing < 0
      ]
    _ -> []

validateLayoutContainer :: LayoutContainerSpec -> [Text]
validateLayoutContainer spec =
  fmap diagnosticMessage (validateLayout spec.layoutContainerLayout)
    <> [ "Layout references a control that is not a direct child: " <> Text.pack (show key)
       | key <- Set.toList (layoutKeys `Set.difference` childKeys)
       ]
    <> [ "Layout child is not referenced by its layout tree: " <> Text.pack (show key)
       | key <- Set.toList (childKeys `Set.difference` layoutKeys)
       ]
  where
    layoutKeys :: Set ElementKey
    layoutKeys = Set.fromList (layoutLeafKeys spec.layoutContainerLayout)
    childKeys :: Set ElementKey
    childKeys = Set.fromList (fmap controlKey spec.layoutContainerChildren)

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

resolveAppViewLayouts :: AppView -> (AppView, [LayoutDiagnostic ElementKey])
resolveAppViewLayouts = resolveAppViewLayoutsWith Map.empty

resolveAppViewLayoutsWith
  :: Map ElementKey IntrinsicMetrics
  -> AppView
  -> (AppView, [LayoutDiagnostic ElementKey])
resolveAppViewLayoutsWith measurements =
  resolveAppViewLayoutsWithAllocations measurements Map.empty

-- | Resolve all portable layouts in an application snapshot against native
-- host allocations.  This is the backend-facing counterpart of
-- 'resolveControlLayoutsWithAllocations'.
resolveAppViewLayoutsWithAllocations
  :: Map ElementKey IntrinsicMetrics
  -> Map ElementKey Size
  -> AppView
  -> (AppView, [LayoutDiagnostic ElementKey])
resolveAppViewLayoutsWithAllocations measurements allocations desiredView =
  let windows = fmap resolveWindow desiredView.appWindows
   in (desiredView {appWindows = fmap fst windows}, foldMap snd windows)
  where
    resolveWindow :: WindowSpec -> (WindowSpec, [LayoutDiagnostic ElementKey])
    resolveWindow window@WindowSpec {windowControls = controls} =
      let (resolved, diagnostics) =
            resolveControlLayoutsWithAllocations measurements allocations controls
       in (window {windowControls = resolved}, diagnostics)
    resolveWindow window@WorkspaceWindowSpec {windowWorkspaceSpec = workspace} =
      let (root, rootDiagnostics) = resolvePaneTree workspace.workspaceRoot
          (status, statusDiagnostics) =
            resolveControlLayoutsWithAllocations measurements allocations workspace.workspaceStatusControls
       in ( window
              { windowWorkspaceSpec =
                  workspace
                    { workspaceRoot = root
                    , workspaceStatusControls = status
                    }
              }
          , rootDiagnostics <> statusDiagnostics
          )

    resolvePaneTree :: PaneTree -> (PaneTree, [LayoutDiagnostic ElementKey])
    resolvePaneTree (WorkspacePane pane) =
      let (item, diagnostics) = resolveItem pane.workspacePaneItem
       in (WorkspacePane pane {workspacePaneItem = item}, diagnostics)
    resolvePaneTree (WorkspaceSplit key orientation first second rest) =
      let children = fmap resolvePaneTree (first : second : rest)
       in case fmap fst children of
            resolvedFirst : resolvedSecond : resolvedRest ->
              ( WorkspaceSplit key orientation resolvedFirst resolvedSecond resolvedRest
              , foldMap snd children
              )
            _ -> (WorkspaceSplit key orientation first second rest, [])

    resolveItem :: WorkspaceItemSpec -> (WorkspaceItemSpec, [LayoutDiagnostic ElementKey])
    resolveItem item =
      case item.workspaceItemContent of
        WorkspaceItemControls controls ->
          let (resolved, diagnostics) =
                resolveControlLayoutsWithAllocations measurements allocations controls
           in (item {workspaceItemContent = WorkspaceItemControls resolved}, diagnostics)
        WorkspaceItemTabGroup groupSpec ->
          let resolveTab tab =
                let (resolved, diagnostics) =
                      resolveControlLayoutsWithAllocations measurements allocations tab.workspaceTabControls
                 in (tab {workspaceTabControls = resolved}, diagnostics)
              tabs = fmap resolveTab groupSpec.workspaceTabs
           in ( item
                  { workspaceItemContent =
                      WorkspaceItemTabGroup groupSpec {workspaceTabs = fmap fst tabs}
                  }
              , foldMap snd tabs
              )

data UIEvent
  = CommandInvoked !CommandId
  | TextChanged !ElementKey !Text
  | ControlInvoked !ElementKey
  | ToggleChanged !ElementKey !ToggleValue
  | ChoiceChanged !ElementKey !(Maybe ChoiceKey)
  | NumberChanged !ElementKey !Double
  | DateChanged !ElementKey !DateComponents
  | TimeChanged !ElementKey !TimeComponents
  | ColorChanged !ElementKey !Color
  | CollectionSelectionChanged !ElementKey ![CollectionItemKey]
  | CollectionExpansionChanged !ElementKey !CollectionItemKey !Bool
  | DisclosureChanged !ElementKey !Bool
  | PresentationClosed !ElementKey !PresentationResult
  | TabSelected !TabKey
  | TabCloseRequested !TabKey
  | PaneStateChanged !PaneKey !PaneState
  | WindowCloseRequested !WindowKey
  | WindowActivated !WindowKey
  | SystemColorSchemeChanged !ColorScheme
  | DrawingInputReceived !ElementKey !DrawingInput
  | TextFileChosen !FilePath
  | ProjectFolderChosen !FilePath
  | DirectoryRead !FilePath !(Either Text [FileSystemEntry])
  | TextFileRead !FilePath !(Either Text Text)
  | OptionalTextFileRead !FilePath !(Either Text (Maybe Text))
  | TextFileWritten !EffectKey !FilePath !Text !(Either Text ())
  deriving stock (Eq, Show)

data Effect
  = RequestOpenTextFiles
  | RequestOpenProjectFolder
  | ReadDirectory !FilePath
  | ReadTextFile !FilePath
  | ReadOptionalTextFile !FilePath
  | WriteTextFile !EffectKey !FilePath !Text
  | WriteTextFileAtomically !EffectKey !FilePath !Text
  deriving stock (Eq, Show)

-- | A callback-oriented event produced outside the native control event
-- vocabulary. The callback is applied to the current model when the runtime
-- accepts the event, never to a model captured when work started.
data ExternalEvent model = ExternalEvent
  !Text
  !EventDelivery
  (model -> Transaction model)

data EventDelivery
  = DeliverEvery
  | KeepLatest !EventCoalescingKey
  deriving stock (Eq, Show)

externalEvent :: Text -> (model -> Transaction model) -> ExternalEvent model
externalEvent description = ExternalEvent description DeliverEvery

latestExternalEvent
  :: EventCoalescingKey
  -> Text
  -> (model -> Transaction model)
  -> ExternalEvent model
latestExternalEvent key description =
  ExternalEvent description (KeepLatest key)

externalEventDescription :: ExternalEvent model -> Text
externalEventDescription (ExternalEvent description _ _) = description

externalEventDelivery :: ExternalEvent model -> EventDelivery
externalEventDelivery (ExternalEvent _ delivery _) = delivery

handleExternalEvent :: ExternalEvent model -> model -> Transaction model
handleExternalEvent (ExternalEvent _ _ handle) = handle

-- | Runtime-owned sink handed to services and subscriptions. Producers can
-- choose lossless delivery or explicit latest-value coalescing, but cannot
-- read or mutate the application model.
data ExternalSink model = ExternalSink
  { emitEvery :: ExternalEvent model -> IO ()
  , emitLatest :: EventCoalescingKey -> ExternalEvent model -> IO ()
  }

emitExternalEvent :: ExternalSink model -> ExternalEvent model -> IO ()
emitExternalEvent sink event =
  case externalEventDelivery event of
    DeliverEvery -> sink.emitEvery event
    KeepLatest key -> sink.emitLatest key event

data TaskScope
  = ApplicationScope
  | WindowScope !WindowKey
  | ElementScope !ElementKey
  | LifetimeScope !LifetimeKey
  deriving stock (Eq, Ord, Show)

data TaskStartPolicy
  = ReplaceRunning
  | KeepRunning
  | RequireIdle
  deriving stock (Eq, Show)

-- | Per-task execution options. Timeouts are expressed in milliseconds so
-- call sites name a human-scale unit and do not depend on a particular clock
-- library.
data TaskOptions = TaskOptions
  { taskScope :: !TaskScope
  , taskStartPolicy :: !TaskStartPolicy
  , taskTimeoutMilliseconds :: !(Maybe Word64)
  }
  deriving stock (Eq, Show)

defaultTaskOptions :: TaskScope -> TaskStartPolicy -> TaskOptions
defaultTaskOptions scope startPolicy =
  TaskOptions
    { taskScope = scope
    , taskStartPolicy = startPolicy
    , taskTimeoutMilliseconds = Nothing
    }

newtype ExceptionSummary = ExceptionSummary {unExceptionSummary :: Text}
  deriving stock (Eq, Show)

data TaskFailure
  = TaskException !ExceptionSummary
  | TaskTimedOut
  | TaskExecutorStopped
  deriving stock (Eq, Show)

data TaskOutcome result
  = TaskSucceeded !result
  | TaskCancelled
  | TaskFailed !TaskFailure
  deriving stock (Eq, Show)

-- | Cooperative cancellation observation. Runtime invalidation and
-- generation checks, rather than cancellation, provide correctness.
data CancellationToken = CancellationToken
  { cancellationRequested :: IO Bool
  , waitForCancellation :: IO ()
  }

data TaskCancellationRequested = TaskCancellationRequested
  deriving stock (Show)

instance Exception TaskCancellationRequested

throwIfCancelled :: CancellationToken -> IO ()
throwIfCancelled token = do
  requested <- cancellationRequested token
  if requested then throwIO TaskCancellationRequested else pure ()

data BackoffPolicy = BackoffPolicy
  { backoffInitialMilliseconds :: !Word64
  , backoffMaximumMilliseconds :: !Word64
  , backoffMultiplier :: !Double
  , backoffJitterRatio :: !Double
  , backoffMaximumRestarts :: !Int
  }
  deriving stock (Eq, Show)

defaultBackoffPolicy :: BackoffPolicy
defaultBackoffPolicy =
  BackoffPolicy
    { backoffInitialMilliseconds = 100
    , backoffMaximumMilliseconds = 5000
    , backoffMultiplier = 2
    , backoffJitterRatio = 0.2
    , backoffMaximumRestarts = 5
    }

data RestartPolicy
  = DoNotRestart
  | RestartOnFailure !BackoffPolicy
  deriving stock (Eq, Show)

-- | Bounded service input behavior. Replacing by a key coalesces pending
-- commands without ever blocking the UI thread.
data OverflowPolicy command
  = RejectNewCommand
  | DropOldestCommand
  | ReplacePendingCommand !(command -> Text)

data ServiceOptions command = ServiceOptions
  { serviceRestartPolicy :: !RestartPolicy
  , serviceCommandCapacity :: !Int
  , serviceOverflowPolicy :: !(OverflowPolicy command)
  }

defaultServiceOptions :: ServiceOptions command
defaultServiceOptions =
  ServiceOptions
    { serviceRestartPolicy = RestartOnFailure defaultBackoffPolicy
    , serviceCommandCapacity = 64
    , serviceOverflowPolicy = RejectNewCommand
    }

data ServiceHealth
  = ServiceHealthy
  | ServiceDegraded !Text
  deriving stock (Eq, Show)

data ServiceExit
  = ServiceStoppedNormally
  | ServiceCancelled
  | ServiceFailed !ExceptionSummary
  deriving stock (Eq, Show)

data ServiceStatus
  = ServiceStarting
  | ServiceRunning
  | ServiceHealthChanged !ServiceHealth
  | ServiceRestartScheduled !Int !Word64
  | ServiceExited !ServiceExit
  | ServiceCircuitOpen !Int !ServiceExit
  deriving stock (Eq, Show)

data ServiceSendResult
  = ServiceCommandQueued
  | ServiceCommandCoalesced
  | ServiceCommandDroppedOldest
  | ServiceCommandRejected
  | ServiceEndpointMismatch
  | ServiceUnavailable
  deriving stock (Eq, Show)

data ServiceEndpoint command = ServiceEndpoint !ServiceKey

serviceEndpointKey :: ServiceEndpoint command -> ServiceKey
serviceEndpointKey (ServiceEndpoint key) = key

data ServiceContext model command = ServiceContext
  { receiveCommand :: IO (Maybe command)
  , serviceEvents :: ExternalSink model
  , serviceCancellation :: CancellationToken
  , reportServiceHealth :: ServiceHealth -> IO ()
  }

-- | Existential service specifications keep command types private while the
-- endpoint preserves them at every application call site.
data Service model where
  Service
    :: Typeable command
    => ServiceKey
    -> Text
    -> ServiceOptions command
    -> Maybe (ServiceStatus -> ExternalEvent model)
    -> (ServiceContext model command -> IO ())
    -> Service model

service
  :: Typeable command
  => ServiceKey
  -> Text
  -> ServiceOptions command
  -> (ServiceContext model command -> IO ())
  -> (Service model, ServiceEndpoint command)
service key description options run =
  (Service key description options Nothing run, ServiceEndpoint key)

serviceWithStatus
  :: Typeable command
  => ServiceKey
  -> Text
  -> ServiceOptions command
  -> (ServiceStatus -> ExternalEvent model)
  -> (ServiceContext model command -> IO ())
  -> (Service model, ServiceEndpoint command)
serviceWithStatus key description options onStatus run =
  (Service key description options (Just onStatus) run, ServiceEndpoint key)

serviceKey :: Service model -> ServiceKey
serviceKey (Service key _ _ _ _) = key

serviceDescription :: Service model -> Text
serviceDescription (Service _ description _ _ _) = description

type SubscriptionStop = IO ()

data Subscription model = Subscription
  !SubscriptionKey
  !SubscriptionFingerprint
  (ExternalSink model -> IO SubscriptionStop)

subscription
  :: SubscriptionKey
  -> SubscriptionFingerprint
  -> (ExternalSink model -> IO SubscriptionStop)
  -> Subscription model
subscription = Subscription

subscriptionKey :: Subscription model -> SubscriptionKey
subscriptionKey (Subscription key _ _) = key

subscriptionFingerprint :: Subscription model -> SubscriptionFingerprint
subscriptionFingerprint (Subscription _ fingerprint _) = fingerprint

-- | Opaque work declarations retained in pure transactions. Constructors are
-- exported for the executor package; application code should prefer the smart
-- constructors below.
data RuntimeCommand model where
  StartTaskCommand
    :: TaskKey
    -> TaskOptions
    -> Text
    -> (CancellationToken -> IO result)
    -> (TaskOutcome result -> ExternalEvent model)
    -> RuntimeCommand model
  CancelTaskCommand :: TaskKey -> RuntimeCommand model
  CancelScopeCommand :: TaskScope -> RuntimeCommand model
  SendServiceCommand
    :: Typeable command
    => ServiceEndpoint command
    -> command
    -> Maybe (ServiceSendResult -> ExternalEvent model)
    -> RuntimeCommand model
  RestartServiceCommand :: ServiceKey -> RuntimeCommand model
  OpenLifetimeCommand :: LifetimeKey -> RuntimeCommand model
  CloseLifetimeCommand :: LifetimeKey -> RuntimeCommand model

startTask
  :: TaskKey
  -> TaskScope
  -> TaskStartPolicy
  -> Text
  -> (CancellationToken -> IO result)
  -> (TaskOutcome result -> ExternalEvent model)
  -> RuntimeCommand model
startTask key scope startPolicy description =
  startTaskWith key (defaultTaskOptions scope startPolicy) description

startTaskWith
  :: TaskKey
  -> TaskOptions
  -> Text
  -> (CancellationToken -> IO result)
  -> (TaskOutcome result -> ExternalEvent model)
  -> RuntimeCommand model
startTaskWith = StartTaskCommand

cancelTask :: TaskKey -> RuntimeCommand model
cancelTask = CancelTaskCommand

cancelScope :: TaskScope -> RuntimeCommand model
cancelScope = CancelScopeCommand

sendService
  :: Typeable command
  => ServiceEndpoint command
  -> command
  -> RuntimeCommand model
sendService endpoint command = SendServiceCommand endpoint command Nothing

sendServiceWithResult
  :: Typeable command
  => ServiceEndpoint command
  -> command
  -> (ServiceSendResult -> ExternalEvent model)
  -> RuntimeCommand model
sendServiceWithResult endpoint command onResult =
  SendServiceCommand endpoint command (Just onResult)

restartService :: ServiceKey -> RuntimeCommand model
restartService = RestartServiceCommand

openLifetime :: LifetimeKey -> RuntimeCommand model
openLifetime = OpenLifetimeCommand

closeLifetime :: LifetimeKey -> RuntimeCommand model
closeLifetime = CloseLifetimeCommand

data App model = App
  { appInitialModel :: !model
  , appInitialEffects :: ![Effect]
  , appInitialCommands :: ![RuntimeCommand model]
  , appServices :: ![Service model]
  , appSubscriptions :: model -> [Subscription model]
  , appView :: model -> AppView
  , appHandleEvent :: UIEvent -> model -> Transaction model
  }

-- | Construct an application with no startup work, services, or dynamic
-- subscriptions. Add those declarations with ordinary record updates as the
-- application grows.
simpleApp
  :: model
  -> (model -> AppView)
  -> (UIEvent -> model -> Transaction model)
  -> App model
simpleApp initialModel view handleEvent =
  App
    { appInitialModel = initialModel
    , appInitialEffects = []
    , appInitialCommands = []
    , appServices = []
    , appSubscriptions = const []
    , appView = view
    , appHandleEvent = handleEvent
    }

data Action model = Action
  !Text
  !(Set PropertyId)
  (model -> model)

action :: Text -> (model -> model) -> Action model
action description = Action description Set.empty

actionWithProperties
  :: Text
  -> [PropertyId]
  -> (model -> model)
  -> Action model
actionWithProperties description touched =
  Action description (Set.fromList touched)

actionDescription :: Action model -> Text
actionDescription (Action description _ _) = description

actionPropertyIds :: Action model -> [PropertyId]
actionPropertyIds (Action _ touched _) = Set.toAscList touched

applyAction :: Action model -> model -> model
applyAction (Action _ _ change) = change

batchActions :: Text -> [Action model] -> Action model
batchActions description actions =
  Action
    description
    (Set.unions [touched | Action _ touched _ <- actions])
    (\model -> foldl (flip applyAction) model actions)

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
  , transactionCommands :: ![RuntimeCommand model]
  }

transaction
  :: Text
  -> UndoPolicy
  -> (model -> model)
  -> Transaction model
transaction description undo change =
  transactionWithEffects description undo [] change

transactionFromAction
  :: Text
  -> UndoPolicy
  -> Action model
  -> Transaction model
transactionFromAction description undo appliedAction =
  transactionFromActionWithEffects description undo [] appliedAction

transactionFromActionWithEffects
  :: Text
  -> UndoPolicy
  -> [Effect]
  -> Action model
  -> Transaction model
transactionFromActionWithEffects description undo effects appliedAction =
  Transaction
    { transactionAction = appliedAction
    , transactionUndo = undo
    , transactionDescription = Just description
    , transactionEffects = effects
    , transactionCommands = []
    }

transactionFromActionWithCommands
  :: Text
  -> UndoPolicy
  -> [RuntimeCommand model]
  -> Action model
  -> Transaction model
transactionFromActionWithCommands description undo commands appliedAction =
  Transaction
    { transactionAction = appliedAction
    , transactionUndo = undo
    , transactionDescription = Just description
    , transactionEffects = []
    , transactionCommands = commands
    }

transactionWithEffects
  :: Text
  -> UndoPolicy
  -> [Effect]
  -> (model -> model)
  -> Transaction model
transactionWithEffects description undo effects change =
  transactionFromActionWithEffects
    description
    undo
    effects
    (action description change)

transactionWithCommands
  :: Text
  -> UndoPolicy
  -> [RuntimeCommand model]
  -> (model -> model)
  -> Transaction model
transactionWithCommands description undo commands change =
  transactionFromActionWithCommands
    description
    undo
    commands
    (action description change)

appendRuntimeCommands
  :: [RuntimeCommand model]
  -> Transaction model
  -> Transaction model
appendRuntimeCommands commands transactionValue =
  transactionValue
    { transactionCommands = transactionValue.transactionCommands <> commands
    }

requestEffect :: Text -> Effect -> Transaction model
requestEffect description requested =
  transactionWithEffects description NoUndo [requested] id

requestRuntimeCommand :: Text -> RuntimeCommand model -> Transaction model
requestRuntimeCommand description requested =
  transactionWithCommands description NoUndo [requested] id

noTransaction :: Transaction model
noTransaction =
  Transaction
    { transactionAction = action "No operation" id
    , transactionUndo = NoUndo
    , transactionDescription = Nothing
    , transactionEffects = []
    , transactionCommands = []
    }

applyTransaction :: Transaction model -> model -> model
applyTransaction transactionValue = applyAction transactionValue.transactionAction
