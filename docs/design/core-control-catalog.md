# Portable Core control catalog

Status: Accepted; Core, headless, AppKit, and gallery vertical slice implemented  
Scope: Semantic controls that every conforming general-purpose UIH desktop backend must support  
Platform baseline: AppKit on macOS and WinUI 3 / Windows App SDK on Windows

## 1. Decision

UIH Core defines a semantic lowest-common-denominator catalog rather than the
literal intersection of AppKit and WinUI class names. A control belongs in the
portable catalog when both backends can preserve its value, interaction,
keyboard, focus, accessibility, and lifecycle semantics using either one native
component or a small composition of native components.

A one-to-one native object mapping is not required. For example, a portable
`TableView` maps directly to `NSTableView` on AppKit and to a virtualized WinUI
collection with column and header composition. Omitting tables merely because
WinUI does not ship a built-in `DataGrid` would make the common API unsuitable
for desktop software.

Core names describe intent. They never expose `NSView`, `NSControl`, XAML,
`DependencyObject`, native enum values, materials, pixels from a platform
theme, or operating-system availability checks.

## 2. Catalog boundary

The catalog has four layers:

1. **Content and layout** arrange and present arbitrary views.
2. **Controls** carry typed values and publish typed interaction events.
3. **Collections and navigation** preserve keyed item identity, selection, and
   retained child state.
4. **Presentation and shell surfaces** expose commands or transient content in
   platform-appropriate windows, menus, toolbars, dialogs, and popovers.

The concrete vertical-slice `UIH.Core.Control` IR may temporarily use records
and explicit frames. The final public API remains opaque `View model`
combinators backed by `Binding`, `StateSource`, `Command`, and typed callbacks.
Adding a concrete IR node therefore does not make its record constructor the
permanent source API.

## 3. Required portable catalog

### 3.1 Content and layout

| UIH semantic component | AppKit realization | WinUI realization |
|---|---|---|
| Plain text | label `NSTextField` | `TextBlock` |
| Rich text | attributed text field or `NSTextView` | `RichTextBlock` |
| Image | `NSImageView` | `Image` |
| Icon | symbol `NSImage` | `IconElement` |
| Separator | separator `NSBox` | separator/border composition |
| Row and column | `NSStackView` | `StackPanel` |
| Grid | `NSGridView` | `Grid` |
| Overlay | layered `NSView` hierarchy | `Grid` or `Canvas` z-order |
| Canvas/custom surface | custom `NSView` drawing | `Canvas` or custom control |
| Semantic group | `NSBox` | border plus accessibility group |
| Scroll view | `NSScrollView` | `ScrollView`/`ScrollViewer` |
| Split view/pane tree | `NSSplitView` hierarchy | split/grid hierarchy |
| Disclosure group | disclosure button plus retained content | `Expander` |

Layout containers accept arbitrary child views. They are not special-purpose
forms that accept only labels or predefined rows. Layout direction, spacing,
padding, alignment, sizing, and visibility are typed portable values; exact
native metrics remain backend policy.

### 3.2 Commands and Boolean choice

| UIH semantic component | AppKit realization | WinUI realization |
|---|---|---|
| Button | `NSButton` | `Button` |
| Repeat button | continuous `NSButton` | `RepeatButton` |
| Toggle button | stateful `NSButton` | `ToggleButton` |
| Checkbox | checkbox-style `NSButton` | `CheckBox` |
| Radio group | grouped radio `NSButton` values | `RadioButton`/`RadioButtons` |
| Switch | `NSSwitch` | `ToggleSwitch` |
| Segmented choice | `NSSegmentedControl` | `SelectorBar` or radio composition |
| Link | attributed link or borderless button | `HyperlinkButton` |
| Menu button | `NSPopUpButton` | `DropDownButton` |
| Split button | `NSComboButton` | `SplitButton` |
| Toggle split button | toggle/menu composition | `ToggleSplitButton` |

Checkboxes, switches, toggle buttons, and toggle split buttons remain distinct
types even when they carry the same Boolean value. Their intent, keyboard
behavior, and accessibility roles differ.

Buttons, menu entries, toolbar entries, context-menu entries, and keyboard
shortcuts reference the same `CommandId`. A visual control does not introduce a
second action identity for an existing command.

### 3.3 Text and value input

| UIH semantic component | AppKit realization | WinUI realization |
|---|---|---|
| Text field | `NSTextField` | `TextBox` |
| Plain text area | plain `NSTextView` | multiline `TextBox` |
| Rich text editor | rich `NSTextView` | `RichEditBox` |
| Secure field | `NSSecureTextField` | `PasswordBox` |
| Search field | `NSSearchField` | `AutoSuggestBox` |
| Suggest field | text suggestions or `NSComboBox` | `AutoSuggestBox` |
| Choice picker | `NSPopUpButton` | `ComboBox` |
| Editable combo box | `NSComboBox` | `AutoSuggestBox` |
| Number field | formatted field plus stepper | `NumberBox` |
| Stepper | `NSStepper` | spin/repeat-button composition |
| Slider | `NSSlider` | `Slider` |
| Date picker | `NSDatePicker` | `DatePicker`/`CalendarDatePicker` |
| Time picker | `NSDatePicker` | `TimePicker` |
| Calendar view | graphical `NSDatePicker` | `CalendarView` |
| Color picker | `NSColorWell`/`NSColorPanel` | `ColorPicker` |
| Rating | rating-style `NSLevelIndicator` | `RatingControl` |

Editable text and parsed values use `Binding` because drafts, invalid values,
commit policy, undo, and external synchronization matter. Already-typed
selection values may use `StateSource`. A backend never writes an invalid draft
into an authoritative model value.

Date and time values use UIH calendar/time component types rather than Unix
timestamps. The backend performs locale-specific presentation. Color values use
a portable color space declaration; the initial sRGB `Color` value is the
baseline.

### 3.4 Collections and navigation

| UIH semantic component | AppKit realization | WinUI realization |
|---|---|---|
| List view | single-column `NSTableView` | `ListView` |
| Collection/grid view | `NSCollectionView` | `ItemsView`/`GridView` |
| Tree view | `NSOutlineView` | `TreeView` |
| Table view | `NSTableView` | virtualized collection with header/columns |
| Item repeater | lightweight collection layout | `ItemsRepeater` |
| Ordinary tab view | `NSTabView` | `TabView`/`Pivot` |
| Workspace tab group | keyed native AppKit composition | `TabView` |
| Breadcrumb/path | `NSPathControl` | `BreadcrumbBar` |
| Navigation sidebar | outline/list in a sidebar pane | `NavigationView` or list/pane composition |

Every collection has stable item keys, explicit order, an explicit selection
mode, typed authoritative or retained selection, and independently retained
item content. Virtualization is backend-owned and must not change observable
identity, selection, focus restoration, accessibility, or disposal semantics.
Hierarchical items declare expandability separately from current children;
this is required for lazy trees to expose native disclosure affordances before
the first child-page result arrives.
Compact collection rows also carry an optional portable `ImageSource` separate
from their primary label and detail. Backends place it in the native row icon
position; hierarchy controls may vary the icon with authoritative expanded
state without embedding presentation markup in the label.

Row-based collections also declare a typed density policy:

```haskell
data CollectionRowSizing
  = PlatformDefaultRows
  | CompactRows
  | StandardRows
  | SpaciousRows
  | FixedRows Double
  | ContentSizedRows
```

`PlatformDefaultRows` is the default. It deliberately contains no UIH point
height. On AppKit it maps to `NSTableViewRowSizeStyleDefault`, so the effective
small, medium, or large density follows the preference selected by the user in
System Settings. `CompactRows`, `StandardRows`, and `SpaciousRows` are semantic
density requests and therefore map to platform styles rather than shared
numbers. `FixedRows` is the only exact logical-height request and invalid,
non-finite, or nonpositive heights fail Core validation. `ContentSizedRows`
uses native automatic row measurement. Grid/card collections and item
repeaters have a different item-layout contract and reject nondefault row
sizing rather than silently interpreting a row height as a card size.

Native cell content is vertically centered for fixed and system rows. AppKit
cell insets use system-spacing constraints; the backend does not embed a
private padding constant. Content-sized rows constrain their label using
system spacing and let Auto Layout calculate the result. Platform-default
intercell spacing is also preserved unless a future explicit portable policy
overrides it.

Selection, activation, expansion, editing, reordering, drag/drop, and contextual
command invocation are distinct events. In particular, keyboard focus does not
implicitly mutate authoritative selection unless the control's declared
selection policy says so.

`NavigationView` is not a low-level Core node. It is the standard composition of
a window/workspace, sidebar pane, keyed collection, commands, and content. UIH
may provide an ergonomic pattern constructor without adding a backend-shaped
primitive.

### 3.5 Presentation, feedback, and shell

| UIH semantic component | AppKit realization | WinUI realization |
|---|---|---|
| Menu/menu bar/context menu | `NSMenu` | `MenuFlyout`/`MenuBar`/context flyout |
| Toolbar | `NSToolbar` | `CommandBar` |
| Dialog | sheet or custom panel | `ContentDialog` |
| Standard alert | `NSAlert` | configured content dialog |
| Popover/flyout | `NSPopover` | `Flyout` |
| Tooltip | native view tooltip | `ToolTip` |
| Progress bar | determinate `NSProgressIndicator` | `ProgressBar` |
| Activity indicator | spinning `NSProgressIndicator` | `ProgressRing` |
| Meter/level | `NSLevelIndicator` | progress/rating composition |
| Badge | native label/item badge composition | `InfoBadge` |
| Inline notice | native view composition | `InfoBar` |
| Document/workspace window | `NSWindow` | `Window`/`AppWindow` |
| Title-bar semantics | window toolbar/accessories | `TitleBar`/`AppWindowTitleBar` |
| Shared status area | ordinary bottom AppKit hierarchy | ordinary bottom XAML hierarchy |

Dialog and popover visibility is desired state with stable presentation
identity. A button may request presentation through an action, but it does not
imperatively retain or own a native dialog object. Dismissal publishes a typed
request/result and reconciliation controls final lifetime.

Title-bar APIs are semantic window options. UIH does not offer a generic custom
title-bar view that encourages applications to imitate another operating
system's chrome.

## 4. Common control contract

Every interactive Core component provides or participates in:

- Stable keyed identity
- Explicit enabled, visible, and focus state
- A typed value owner (`Binding`, `StateSource`, command, or retained element state)
- Typed events with semantic origin where the distinction matters
- Accessible label, description, value, role, and relationships
- Keyboard traversal and native activation behavior
- Tooltip and validation presentation hooks
- Deterministic create/update/reparent/destroy reconciliation
- Backend capability diagnostics for unavailable optional behavior

Native controls may accept richer arbitrary child content than their peer on
another backend. The portable default for compact control labels is therefore a
typed text/icon `ControlLabel`. Arbitrary child `View` content is exposed only
where both backends can preserve the layout and accessibility contract.

## 5. Features that are not distinct Core primitives

These features remain expressible, but they do not add mandatory nodes to the
portable catalog:

- Token fields, rule/predicate editors, column browsers, scrubbers, carousels,
  pagers, person pictures, and teaching tips are standard extension packages or
  compositions.
- Media, web views, maps, and ink live in focused packages because they require
  additional platform frameworks, permissions, resource policies, or unstable
  APIs.
- Swipe actions, pull-to-refresh, semantic zoom, and annotated scrollbars are
  optional collection/input modifiers with non-pointer fallbacks.
- Glass, Mica, vibrancy, and other materials are backend appearance policy.
- Dock/taskbar items, jump lists, status items, notifications, print panels,
  and similar operating-system integrations are platform services.

An application can query optional backend capabilities. It must not branch on
raw OS versions in ordinary view code.

## 6. Implementation and conformance

The initial AppKit implementation may use explicit frames in the compiled IR,
but all catalog controls must have a real native or native-composite peer,
normalized callbacks, update reconciliation, accessibility identity, keyboard
participation, and deterministic destruction.

The headless backend retains the complete desired semantic tree and supports
pure validation without opening native windows.

A `uih-control-gallery` example is the catalog conformance fixture. One process
declares every required Core control, divides them into navigable categories,
binds interactive samples to one pure Haskell model, and exposes the resulting
values in a shared event log/status area. Its deterministic AppKit script must
exercise representative text, Boolean, numeric, selection, collection,
presentation, command, and close events, then assert zero remaining native
windows, controls, action targets, delegates, or queued callbacks.

The eventual Windows backend must render the same gallery from the same Haskell
application module. Backend-specific gallery forks are prohibited; expected
appearance may differ, but semantics and event traces must conform.

### 6.1 Implemented vertical slice (August 2026)

The repository now implements the complete catalog described by the current
concrete Core IR:

- `UIH.Core.Control` has distinct constructors and typed specification records
  for all catalog members. `CatalogControlKind` is exhaustive, `controlKey`,
  `controlFrame`, recursive child traversal, and pure catalog validation are
  total over the sum type.
- Boolean, choice, text, numeric, date, time, color, collection, disclosure,
  collection-expansion, presentation-result, and command interactions cross
  the backend boundary as normalized typed `UIEvent` values.
- The AppKit adapter gives all catalog members a retained native peer or small
  native composition. Generic C ABI configuration covers text/icon labels,
  keyed items, enabled/value state, commands, rich-text runs, presentation,
  arbitrary-child parenting, selection modes, and deterministic destruction.
- Native accessibility identifiers are derived from stable `ElementKey`
  values. AppKit roles are specialized for text, image, button, Boolean,
  selection, text input, value input, collection, navigation, menu, toolbar,
  progress, and container categories.
- Reconciliation preserves retained native identity. Updating a child does not
  rebuild its `TabView` page slot or semantic `Container`; this is required to
  preserve the first responder, text selection, scroll position, and popover
  anchor across ordinary model updates.
- AppKit collection families use different peers: `NSTableView` for lists and
  tables, `NSCollectionView` for card collections and repeaters,
  `NSOutlineView` for trees, and source-list styling for navigation sidebars.
  Their common keyed item protocol does not imply identical realization.
- Static `RichText` stores its span attributes in `NSTextStorage`; editable
  presentation layers remain temporary layout attributes. Weight, slant,
  point size, and color are therefore visible and queryable on the native peer.
- `examples/control-gallery` declares 174 controls in one window: all 50
  `CatalogControlKind` values, all four legacy control constructors, six
  ordinary-tab categories, every container form, and a native visual fixture
  for box, flow, wrap, grid, a multirow lined grid table, overlay, canvas,
  split, and adaptive layout. All controls share a pure Haskell model and
  visible event feedback.
- The gallery model/headless test verifies coverage, unique identities, pure
  validation, state transitions, and complete semantic-tree retention. Its
  AppKit test creates every control and exercises text, Boolean, keyed choice,
  numeric, collection, command, dialog, popover, ordinary-tab,
  nested-parenting, and close flows. It explicitly asserts that text-area and
  collection reconciliation retain the native first responder, rich-text
  attributes are realized, collection peers differ, and popover dismissal
  returns to model state before every native resource counter returns to zero.

This is complete support for the current concrete catalog contract, not a claim
that the eventual opaque `View model`, binding, accessibility-description,
virtualized data-source, drag/drop, or Windows adapter APIs are finished. Those
later layers must preserve these control identities and event semantics rather
than replacing the catalog.

## 7. Primary platform references

- AppKit controls and `NSControl` subclasses:
  <https://developer.apple.com/documentation/appkit/nscontrol>
- AppKit text fields:
  <https://developer.apple.com/documentation/appkit/nstextfield>
- AppKit collection, table, and outline views:
  <https://developer.apple.com/documentation/appkit/collection-view>
  <https://developer.apple.com/documentation/appkit/table-view>
  <https://developer.apple.com/documentation/appkit/outline-view>
- AppKit table row sizing and automatic heights:
  <https://developer.apple.com/documentation/appkit/nstableview/rowsizestyle-swift.enum>
  <https://developer.apple.com/documentation/appkit/nstableview/effectiverowsizestyle>
  <https://developer.apple.com/documentation/appkit/nstableview/usesautomaticrowheights>
- Apple lists and tables guidance:
  <https://developer.apple.com/design/human-interface-guidelines/lists-and-tables>
- AppKit containers and scrolling:
  <https://developer.apple.com/documentation/appkit/grid-view>
  <https://developer.apple.com/documentation/appkit/scroll-view>
- AppKit menus, toolbars, and popovers:
  <https://developer.apple.com/documentation/appkit/nsmenu>
  <https://developer.apple.com/documentation/appkit/toolbar>
  <https://developer.apple.com/documentation/appkit/nspopover>
- WinUI control catalog:
  <https://learn.microsoft.com/en-us/windows/apps/develop/ui/controls/>
- WinUI layout panels:
  <https://learn.microsoft.com/en-us/windows/apps/develop/ui/layout-panels>
- WinUI text controls:
  <https://learn.microsoft.com/en-us/windows/apps/develop/ui/controls/text-controls>
- WinUI buttons, menus, and command bars:
  <https://learn.microsoft.com/en-us/windows/apps/develop/ui/controls/buttons>
  <https://learn.microsoft.com/en-us/windows/apps/develop/ui/controls/menus-and-context-menus>
  <https://learn.microsoft.com/en-us/windows/apps/develop/ui/controls/command-bar>
