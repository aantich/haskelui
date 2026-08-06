# Document windows and workspace windows

Status: Final surface design for the first workspace implementation  
Scope: Public Haskell types and semantics for document windows, workspace windows, panes, document/tool tabs, and a shared status area  
Implementation status: Initial Core/AppKit/editor vertical slice implemented; ergonomic opaque surface combinators remain the next API-migration layer

## 1. Outcome

HaskeLUI supports two distinct, complementary native desktop surfaces:

- A `documentWindow` presents one primary document in one operating-system window. On platforms that support system window tabbing, several document windows may be grouped by the system.
- A `workspaceWindow` presents application-managed tools and documents inside one operating-system window, with nested split panes, internal tab groups, an optional shared toolbar, and an optional shared status area.

They share the scene runtime, commands, actions, properties, view tree, controls, effects, focus, and reconciliation. They do not pretend that system window tabs and in-window document tabs are the same facility.

The public API describes semantics. It never exposes `NSWindow`, `NSSplitViewController`, `NSTabViewController`, WinUI `TabView`, or another backend type.

## 2. Design constraints

The surface must support all of the following without changing its ownership model:

- One document per window, as in a traditional document application
- Many document tabs in one workspace window
- Optional left and right tool panes
- Nested split editor groups
- Several workspace windows
- Moving a tab between groups or windows
- Several views of one document
- Tool tabs that are not documents
- A status area derived from the active application context
- Native AppKit and Windows realization
- A later custom-rendered backend using the same application code

The first implementation does not need tab drag-and-drop, tear-out, automatic layout restoration, or multiple editor groups. The types must nevertheless avoid making those features breaking changes.

## 3. Module surface

The proposed modules are:

```text
HaskeLUI.Scene.Window       common and document/workspace window declarations
HaskeLUI.Workspace          workspace root, pane tree, pane state, and status area
HaskeLUI.Workspace.Tab      workspace tab groups, tabs, and transfer requests
HaskeLUI.StateSource        explicit retained/restored/controlled/model ownership
```

The ordinary umbrella `HaskeLUI` module may re-export the common constructors. Detailed event and policy types remain available from their focused modules.

All data constructors shown as opaque are hidden. Applications construct them through checked functions so that backend representation can evolve.

## 4. Typed identities

```haskell
newtype Key tag = Key Text

type WindowKey   = Key WindowTag
type DocumentKey = Key DocumentTag
type PaneKey     = Key PaneTag
type SplitKey    = Key SplitTag
type WorkspaceItemKey = Key WorkspaceItemTag
type TabGroupKey = Key TabGroupTag
type TabKey      = Key TabTag
```

These identities are deliberately separate:

- `DocumentKey` identifies domain content.
- `TabKey` identifies one presentation of content.
- `TabGroupKey` identifies one in-window tab container.
- `WorkspaceItemKey` identifies movable pane content independently of its host.
- `WindowKey` identifies one operating-system window.

Consequently, two tabs may have different `TabKey` values and the same `DocumentKey`. Closing one view does not necessarily close the document.

Keys are stable across declarative renders. Collections are ordered by their declarations, not by the lexical ordering of keys.

`WindowKey`, `DocumentKey`, `WorkspaceItemKey`, and `TabKey` are application-global. A workspace item or tab therefore keeps the same logical presentation identity while moving between panes or windows. `PaneKey`, `SplitKey`, and `TabGroupKey` are unique within their owning window and are paired with `WindowKey` when addressed from outside that window. Declaring the same application-global item or tab in two locations simultaneously is an invalid intermediate state and produces a diagnostic.

## 5. A small state-ownership protocol

Selections and pane geometry need controlled and uncontrolled forms, but they do not need the parsing, validation, draft, and undo protocol of `Binding`.

```haskell
data StateSource model value -- opaque

retainedState
  :: value
  -> StateSource model value

restoredState
  :: Restorable value
  => RestorationKey
  -> value
  -> StateSource model value

restoredStateWith
  :: Codec value
  -> RestorationKey
  -> value
  -> StateSource model value

controlledState
  :: value
  -> (value -> Action model)
  -> StateSource model value

propertyState
  :: Property model value
  -> StateSource model value
```

Ownership is exclusive:

- `retainedState` makes the keyed element the owner for its lifetime.
- `restoredState` is retained element state additionally loaded from and saved to the runtime restoration service.
- `controlledState` makes application code authoritative through the supplied value and callback.
- `propertyState` makes a model property authoritative and uses typed property assignment for changes.

`StateSource` is not a replacement for `Binding`. A text field still uses `Binding` because invalid drafts, parsing, validation, commit timing, conflicts, and undo matter. Tab selection and a committed splitter position use `StateSource` because they are already typed values with control-specific commit behavior.

`Restorable` supplies a stable codec. HaskeLUI provides instances for its standard state types; applications may derive or define it for their own types. `restoredStateWith` is the explicit-codec form. Restoration therefore never relies on `Show`/`Read`, runtime type reflection, or an unversioned backend encoding.

Each consuming control defines when it publishes changes. Tab selection publishes immediately. A pane keeps live drag geometry inside the runtime and publishes one committed state when the resize gesture ends. This avoids rebuilding the application model for every pointer movement.

## 6. Window surface types

The two modes are statically distinguished with hidden marker types:

```haskell
data DocumentSurface
data WorkspaceSurface

data WindowOption surface model -- opaque
```

Common options are polymorphic in the surface:

```haskell
windowTitle
  :: Text
  -> WindowOption surface model

windowInitialFrame
  :: WindowFrame
  -> WindowOption surface model

windowRestorationKey
  :: RestorationKey
  -> WindowOption surface model

windowToolbar
  :: Toolbar model
  -> WindowOption surface model

onWindowCloseRequest
  :: (WindowCloseRequest -> Action model)
  -> WindowOption surface model

data WindowCloseRequest = WindowCloseRequest
  { closingWindow     :: WindowKey
  , windowCloseOrigin :: WindowCloseOrigin
  }

data WindowCloseOrigin
  = WindowCloseButton
  | WindowCloseCommand
```

Close is always a request. The backend does not destroy the window when the close button is pressed. The callback may remove the scene immediately, start dirty-document negotiation, or leave it present. Reconciliation closes the native window only after the scene disappears.

### 6.1 Document windows

```haskell
documentWindow
  :: WindowKey
  -> DocumentKey
  -> [WindowOption DocumentSurface model]
  -> View model
  -> Scene model

representedFile
  :: FilePath
  -> WindowOption DocumentSurface model

documentEdited
  :: Bool
  -> WindowOption DocumentSurface model

systemTabbing
  :: SystemTabbingPolicy
  -> WindowOption DocumentSurface model

data SystemTabbingPolicy
  = PlatformTabbingDefault
  | AllowSystemTabbing
  | DisallowSystemTabbing
```

`representedFile` and `documentEdited` are semantic shell information. AppKit may expose a file proxy and edited indicator. A Windows backend may map them to corresponding title-bar and task behavior without copying AppKit visuals.

`AllowSystemTabbing` permits platform grouping; it does not promise that every platform provides it. Applications requiring portable in-window tabs use `workspaceWindow`.

Example:

```haskell
documentScene document =
  documentWindow document.windowKey document.id
    [ windowTitle (documentTitle document)
    , representedFile document.path
    , documentEdited document.dirty
    , systemTabbing PlatformTabbingDefault
    , onWindowCloseRequest $ \request ->
        emit documentEvents
          (RequestDocumentWindowClose request.closingWindow request.windowCloseOrigin)
    ]
    (focusScope documentCommandHandlers (documentEditor document))
```

The constructor establishes an enclosing document context for commands, focus, accessibility, effects, and future document services. It does not prescribe the application's `Document` record.

### 6.2 Workspace windows

```haskell
data WorkspaceView model -- opaque

workspaceWindow
  :: WindowKey
  -> [WindowOption WorkspaceSurface model]
  -> WorkspaceView model
  -> Scene model
```

A workspace window has one shared shell and one pane tree. Document and tool tabs are application-managed children of the pane tree; they are not operating-system windows.

## 7. Workspace root and status area

```haskell
workspace
  :: [WorkspaceOption model]
  -> PaneTree model
  -> WorkspaceView model

data WorkspaceOption model -- opaque

workspaceStatus
  :: StatusArea model
  -> WorkspaceOption model
```

The toolbar remains a `WindowOption` because toolbars also apply to document windows and may be integrated with native title-bar chrome. The status area belongs to the workspace content below the pane tree.

```haskell
data StatusArea model -- opaque
data StatusSection model -- opaque
data StatusAlignment = StatusLeading | StatusCenter | StatusTrailing

statusArea
  :: [StatusSection model]
  -> StatusArea model

statusSection
  :: StatusAlignment
  -> [View model]
  -> StatusSection model
```

Status content is ordinary semantic UI. It may contain text, command buttons, progress, diagnostics, or custom elements. The status container supplies the platform-appropriate separator, background, sizing, accessibility grouping, and narrow-window behavior.

The application derives status content from its semantic active workspace state. With multiple editor groups, `activeGroup` has a real application meaning because it controls shared inspector and status content; it may therefore live in the model. Focus routing itself remains runtime-owned and does not depend on this mirrored value.

Example:

```haskell
editorStatus model =
  statusArea
    [ statusSection StatusLeading
        [ text (activeLanguage model)
        , text (activeEncoding model)
        ]
    , statusSection StatusTrailing
        [ commandButton ToggleDiagnostics
        , text (activeSaveState model)
        ]
    ]
```

This is not AppKit `NSStatusBar`, which represents the system menu bar.

## 8. Pane tree

Pane structure is separate from ordinary row/column layout because splitters have identity, persistent interaction state, collapse behavior, command semantics, and specialized native mappings.

```haskell
data PaneTree model -- opaque
data SplitOption -- opaque

data PaneRole
  = SidebarPane
  | ContentPane
  | InspectorPane
  | AuxiliaryPane

data SplitOrientation
  = SideBySide -- children run left to right
  | Stacked    -- children run top to bottom
```

Pane hosts and pane content have separate identities. `PaneKey` owns the layout
location, role, size, and collapse state; `WorkspaceItemKey` owns movable content
and its retained descendant state.

```haskell
data WorkspaceItem model -- opaque
data WorkspaceItemOption model -- opaque

workspaceItem
  :: WorkspaceItemKey
  -> [WorkspaceItemOption model]
  -> View model
  -> WorkspaceItem model
```

Any `View model` may be wrapped as a workspace item: native controls, an editor,
a tree, a tab group, a type visualization, or a custom-rendered element. Pane
roles describe host behavior and never restrict content type.

The generic leaf constructor and convenience constructors are:

```haskell
pane
  :: PaneKey
  -> PaneRole
  -> [PaneOption model]
  -> WorkspaceItem model
  -> PaneTree model

sidebarPane, contentPane, inspectorPane, auxiliaryPane
  :: PaneKey
  -> [PaneOption model]
  -> WorkspaceItem model
  -> PaneTree model
```

`PaneRole` describes behavior rather than appearance. In particular, it lets AppKit use sidebar and inspector split items and lets Windows select suitable navigation or grid behavior. Applications may still put arbitrary `View model` content in every pane.

Reassigning two `WorkspaceItem` values between declared panes swaps their
contents while the pane roles and geometry stay with their locations. Stable
item identity lets reconciliation move or reparent the content rather than
destroying it. Moving complete pane nodes is a separate state transition used
when role, geometry, and collapse state should travel with the content.

Splits require at least two children in their public constructor:

```haskell
split
  :: SplitKey
  -> SplitOrientation
  -> [SplitOption]
  -> PaneTree model
  -> PaneTree model
  -> [PaneTree model]
  -> PaneTree model
```

The first two child arguments prevent empty and single-child split declarations without forcing users to construct `NonEmpty` values:

```haskell
split #mainSplit SideBySide [] navigator editors [inspector]
```

Nested calls express bottom panels and multiple editor groups:

```haskell
split #root SideBySide []
  navigator
  (split #center Stacked [] editorGroups diagnostics [])
  [inspector]
```

### 8.1 Pane sizing and state

```haskell
newtype Dip = Dip Double
  deriving newtype (Eq, Ord, Show, Num, Fractional)

data PaneVisibility
  = PaneVisible
  | PaneCollapsed

data PaneState = PaneState
  { paneVisibility :: PaneVisibility
  , paneExtent     :: Maybe Dip
  }

data PaneOption model -- opaque
data PaneSizingOption -- opaque

paneSizing
  :: [PaneSizingOption]
  -> PaneOption model

paneMinimum
  :: Dip
  -> PaneSizingOption

panePreferred
  :: Dip
  -> PaneSizingOption

paneMaximum
  :: Dip
  -> PaneSizingOption

paneStretch
  :: Double
  -> PaneSizingOption

paneState
  :: StateSource model PaneState
  -> PaneOption model

paneCollapsible
  :: Bool
  -> PaneOption model

paneResizable
  :: Bool
  -> PaneOption model

paneLabel
  :: Text
  -> PaneOption model
```

`paneExtent` is the user's current extent along the parent split axis. `panePreferred` is the fallback when no current extent has been established. The flexible content pane normally has `paneExtent = Nothing` and a positive `paneStretch` weight.

Sizing options are checked as one set: extents must be nonnegative, minimum must not exceed preferred or maximum, and stretch must be nonnegative. Invalid sets produce a construction diagnostic and a safe normalized value rather than contradictory backend constraints.

Pane collapse has different semantics from conditional omission:

- A collapsed declared pane retains its identity, state, last focused descendant, and restoration data while leaving layout, focus traversal, and the accessibility tree.
- An omitted pane is removed by reconciliation and its retained resources are disposed.

For an application-controlled sidebar toggle, bind the pane state to a property and modify that property from a command:

```haskell
navigatorPane model =
  sidebarPane #navigator
    [ paneSizing
        [ paneMinimum 180
        , panePreferred 260
        , paneMaximum 520
        , paneStretch 0
        ]
    , paneState (propertyState properties.workspace.navigatorPane)
    , paneCollapsible True
    ]
    (navigatorView model)

toggleNavigator =
  modify properties.workspace.navigatorPane togglePaneVisibility
```

Live splitter movement is retained runtime interaction. `propertyState` or `controlledState` receives the final committed `PaneState`, not every intermediate pointer coordinate.

## 9. Workspace tab groups

HaskeLUI keeps three concepts distinct:

- `tabView`: simple selectable pages such as preference categories
- System window tabbing: platform grouping of whole document windows
- `workspaceTabGroup`: application-managed documents or tools inside a workspace pane

```haskell
data WorkspaceTab model -- opaque
data TabGroupOption model -- opaque

workspaceTabGroup
  :: TabGroupKey
  -> StateSource model (Maybe TabKey)
  -> [WorkspaceTab model]
  -> [TabGroupOption model]
  -> View model
```

The selected key is explicit. The order of the `[WorkspaceTab model]` declaration is authoritative. A user selection updates the supplied `StateSource` immediately.

When `retainedState` or `restoredState` owns selection and the selected tab disappears, the control chooses the next tab, then the previous tab, then `Nothing`. It may do this because it owns that value. When `controlledState` or `propertyState` supplies a key that is not declared, HaskeLUI reports a diagnostic and displays no selected content; it never silently rewrites application-owned state. Reducers that close or move a selected tab must choose the successor in the same transaction. HaskeLUI can provide pure helper functions for that transition without hiding it in the control.

### 9.1 Document and tool tabs

```haskell
documentTab
  :: TabKey
  -> DocumentKey
  -> [WorkspaceTabOption model]
  -> View model
  -> WorkspaceTab model

toolTab
  :: TabKey
  -> [WorkspaceTabOption model]
  -> View model
  -> WorkspaceTab model

data WorkspaceTabOption model -- opaque

tabTitle
  :: Text
  -> WorkspaceTabOption model

tabIcon
  :: Icon
  -> WorkspaceTabOption model

tabModified
  :: Bool
  -> WorkspaceTabOption model

tabTooltip
  :: Text
  -> WorkspaceTabOption model

onTabCloseRequest
  :: (TabCloseRequest -> Action model)
  -> WorkspaceTabOption model
```

Supplying `onTabCloseRequest` makes the tab closeable. A close request never removes the tab directly. The application may remove only that tab view, negotiate an unsaved document, or close the underlying document after its final view disappears.

```haskell
data TabCloseRequest = TabCloseRequest
  { closingTab      :: TabKey
  , closingLocation :: TabLocation
  , closeOrigin     :: TabCloseOrigin
  }

data TabCloseOrigin
  = TabCloseButton
  | TabCloseCommand
  | TabCloseAuxiliaryClick
```

`documentTab` establishes a document context around its content just as `documentWindow` does. `toolTab` deliberately has no document identity.

Inactive declared tab content remains logically retained by `TabKey`. The initial implementation keeps its element subtree alive but hidden. A later backend may physically suspend expensive content only if it preserves the same focus, selection, scroll, edit, and accessibility restoration contract.

### 9.2 Activation and shared context

Selecting a tab and activating a group are different in a split workspace: clicking an already selected editor can make its group active without changing its selected tab.

```haskell
onTabGroupActivated
  :: Action model
  -> TabGroupOption model
```

This callback is optional. Command routing always uses actual runtime focus. Applications use it only when active-group identity has semantic consequences such as shared inspector or status content, restoration, or “open beside” behavior.

### 9.3 Reordering, moving, and detaching

Tab transfer is requested through one typed protocol:

```haskell
data TabLocation = TabLocation
  { tabWindow :: WindowKey
  , tabGroup  :: TabGroupKey
  }

data TabInsertion
  = InsertAtStart
  | InsertBefore TabKey
  | InsertAfter TabKey
  | InsertAtEnd

data DetachHint = DetachHint
  { suggestedFrame :: Maybe WindowFrame
  }

data TabTransferRequest
  = MoveTab
      { movingTab       :: TabKey
      , sourceLocation  :: TabLocation
      , targetLocation  :: TabLocation
      , targetInsertion :: TabInsertion
      }
  | DetachTab
      { movingTab      :: TabKey
      , sourceLocation :: TabLocation
      , detachHint     :: DetachHint
      }

data TabTransferPolicy
  = ReorderWithinGroup
  | MoveBetweenGroups
  | MoveBetweenWindows

tabTransfers
  :: TabTransferPolicy
  -> (TabTransferRequest -> Action model)
  -> TabGroupOption model
```

The option couples permission with the required callback, so the API cannot accidentally advertise movable tabs without defining what a move means for application state.

Insertion uses stable neighbor keys rather than integer indices. Indices become stale when another event closes or reorders tabs between gesture start and action interpretation. If a referenced neighbor no longer exists, the standard pure transfer helper returns `Left StaleTabAnchor`; it does not guess another destination. The application may ignore the stale gesture or explicitly retry with `InsertAtStart` or `InsertAtEnd`.

`DetachTab` does not itself create a window. Its action allocates or selects an application `WindowKey`, changes the workspace state, and causes `appScenes` to declare the destination `workspaceWindow`. Scene reconciliation then creates the operating-system window.

## 10. Complete workspace example

The model separates documents, document views, and windows:

```haskell
data EditorModel = EditorModel
  { documents :: Map DocumentKey Document
  , views     :: Map TabKey DocumentView
  , windows   :: Map WindowKey WorkspaceState
  }

data WorkspaceState = WorkspaceState
  { paneLayout  :: PaneLayoutState
  , tabGroups   :: Map TabGroupKey TabGroupState
  , activeGroup :: Maybe TabGroupKey
  }

data TabGroupState = TabGroupState
  { orderedTabs :: [TabKey]
  , selectedTab :: Maybe TabKey
  }
```

One possible surface use is:

```haskell
editorWorkspaceWindow model windowKey state =
  workspaceWindow windowKey
    [ windowTitle "HaskeLUI Editor"
    , windowToolbar (editorToolbar model windowKey)
    , windowRestorationKey (workspaceRestorationKey windowKey)
    , onWindowCloseRequest $ \request ->
        emit workspaceEvents (RequestWorkspaceClose request.closingWindow)
    ] $
    workspace
      [ workspaceStatus (editorStatusFor model state.activeGroup)
      ]
      ( split #mainSplit SideBySide []
          (sidebarPane #navigator
            [ paneSizing navigatorSizing
            , paneState (propertyState (navigatorPaneProperty windowKey))
            , paneCollapsible True
            ]
            (workspaceItem #navigatorItem [] (fileNavigator model)))
          (contentPane #primaryEditors []
            (workspaceItem #editorItem []
              (editorTabGroup model windowKey #primary state)))
          [ inspectorPane #inspector
              [ paneSizing inspectorSizing
              , paneState (propertyState (inspectorPaneProperty windowKey))
              , paneCollapsible True
              ]
              (workspaceItem #inspectorItem []
                (inspectorForActiveDocument model state))
          ]
      )
```

The tab group can then be rendered as:

```haskell
editorTabGroup model windowKey groupKey state =
  workspaceTabGroup groupKey
    (propertyState (selectedTabProperty windowKey groupKey))
    (map (renderEditorTab model) (tabsInGroup state groupKey))
    [ onTabGroupActivated
        (activeGroupProperty windowKey .= Just groupKey)
    , tabTransfers MoveBetweenWindows
        (emit workspaceEvents)
    ]

renderEditorTab model tabKey =
  let viewState = model.views Map.! tabKey
      document  = model.documents Map.! viewState.document
  in documentTab tabKey document.id
      [ tabTitle (documentDisplayName document)
      , tabModified document.dirty
      , onTabCloseRequest $ \request ->
          emit workspaceEvents (RequestTabClose request)
      ]
      (documentEditor document viewState)
```

The example is intentionally explicit about authoritative order, selection, activation, and close requests while leaving pointer tracking, focus restoration, splitter dragging, and native peers in the retained runtime.

## 11. Backend realization contract

The semantic structure is portable; exact composition is platform-specific.

| HaskeLUI semantic concept | AppKit realization | Windows realization |
|---|---|---|
| `documentWindow` | `NSWindow` with document metadata; optional system window tabbing | native app window and document metadata where available |
| `workspaceWindow` | `NSWindow` hosting a controller hierarchy | WinUI/Windows App SDK window hosting a view hierarchy |
| sidebar pane | sidebar `NSSplitViewItem` where possible | `NavigationView`, `SplitView`, or `Grid` composition |
| content/inspector panes | normal/inspector split items | `Grid`/`SplitView` composition |
| workspace tab group | native `NSTabViewController` when sufficient, otherwise a composite of native AppKit views and controllers | WinUI `TabView` when sufficient, otherwise a native composite |
| status area | ordinary bottom `NSView` hierarchy | ordinary bottom WinUI layout row |

A composite made from native controls is still a native realization. HaskeLUI does not require one semantic node to correspond to exactly one platform object.

The adapter must preserve:

- Stable keyed identity
- Native focus and keyboard traversal
- Accessibility roles and visibility
- Tab selection and close semantics
- Pane min/preferred/max constraints
- Collapse behavior and state restoration
- Correct command scope when tabs change
- Hidden-tab and collapsed-pane state
- Deterministic disposal when tabs, panes, or windows disappear

Backends may differ in chrome, divider metrics, animations, compact behavior, and toolbar placement. HaskeLUI promises semantic equivalence, not pixel identity.

## 12. Critical review and resulting revisions

The initial sketch was tested against traditional document apps, the current text editor, an IDE with two editor groups, a tool-only workspace, multiple views over one document, and native AppKit/Windows lowering.

| Initial weakness | Revision | Why the revision is necessary |
|---|---|---|
| One universal `Window` plus options | Separate `documentWindow` and `workspaceWindow` surface modes | The distinction affects lifecycle, document context, system tabbing, and accepted content; it is semantic rather than cosmetic. |
| Every tab carried a document | Separate `documentTab` and `toolTab`; `TabKey` and `DocumentKey` remain distinct | Welcome, search, settings, terminal, and diagnostics tabs are not documents; one document may also have several views. |
| Pane identity also identified its content | Separate `PaneKey` host identity from movable `WorkspaceItemKey` content identity | Arbitrary editor, visualization, tool, or tab-group content can swap panes without losing retained state or transferring slot-specific geometry accidentally. |
| Pane sizes and collapse were ordinary model fields | Introduce `StateSource` with retained, restored, controlled, and property-owned forms | Geometry is usually runtime/restoration state, but applications sometimes need authoritative toggles and persistence. The API must express both without duplicate ownership. |
| Generic restored state had no serialization contract | Require `Restorable` or an explicit `Codec` | Restoration must be stable, testable, and versionable rather than relying on accidental `Show`/`Read` formats. |
| Reuse `Binding` for pane and tab state | Keep `Binding` for editing and use the smaller `StateSource` protocol | Selection and splitter state do not have invalid drafts, parsing, validation, or undo. Reusing `Binding` would make a simple contract misleading. |
| A split accepted an arbitrary list | Require two children positionally, followed by additional children | Empty and one-child split trees are invalid, while users avoid `NonEmpty` syntax. |
| `PaneSizing` exposed a record that could contain contradictory bounds | Use a checked sizing-option builder | One validation point normalizes constraints before AppKit and Windows adapters receive them. |
| A generic split had no pane roles | Add `SidebarPane`, `ContentPane`, `InspectorPane`, and `AuxiliaryPane` | Native backends otherwise lose enough meaning to select specialized collapse, resize, and accessibility behavior. |
| Closing a tab removed it internally | Make close a typed request; model reconciliation performs removal | Dirty negotiation, several views per document, undo/service policy, and async saving belong to application/document logic. |
| Tab moves used list indices | Use key-relative `TabInsertion` and reject a missing anchor as stale | Stable anchors survive most concurrent list changes, and a vanished anchor cannot apply the gesture to an unintended ordering. |
| Reorder, cross-group move, and tear-out were unrelated callbacks | Use one `TabTransferRequest` and pair the handler with a `TabTransferPolicy` | One state transition model covers all destinations, and unsupported behavior cannot be accidentally advertised. |
| Selected tab implied active editor group | Add the optional `onTabGroupActivated` callback | In split editors, focus can activate a group without changing its selected tab. Shared inspector/status content needs this distinction. |
| System window tabs and editor tabs shared one abstraction | Keep `systemTabbing` and `workspaceTabGroup` entirely separate | System tabs group whole windows; workspace tabs live inside one shared shell and can move among internal panes. |
| Inactive tab disposal was unspecified | Guarantee logical retention by stable `TabKey` | Editors must not lose caret, selection, scroll, IME, or undo-related retained state merely because another tab becomes visible. |
| The status area was called a native status bar | Define it as semantic workspace content | AppKit `NSStatusBar` is the system menu bar; a desktop editor footer is an ordinary native view hierarchy. |

## 13. Final invariants

1. A domain document, movable workspace item, presentation tab, tab group, pane host, and operating-system window always have distinct typed identities.
2. `documentWindow` and `workspaceWindow` are different public surface constructors built on the same runtime.
3. System window tabbing and in-window workspace tabbing never share state or lifecycle APIs.
4. The application owns tab collection order and document lifecycle; the selected tab may be retained, restored, controlled, or property-owned explicitly.
5. Tab close, move, and detach are requests. Only application state transitions and scene/view reconciliation create or remove resources.
6. Pane geometry is runtime-local during live interaction and commits through its declared `StateSource` at the end of the gesture.
7. Collapsing preserves a pane; omitting it destroys the pane.
8. Focus is runtime-owned. Application `activeGroup` state is optional and exists only when shared application content depends on it.
9. Inactive tab content remains logically retained; backend optimization cannot change observable state restoration.
10. Native mapping is semantic and compositional. No one-to-one widget correspondence or pixel identity is promised.
11. Any `View model` may be hosted in any pane through `WorkspaceItem`; pane roles constrain host behavior, not content type.

## 14. Implementation boundary

The first vertical slice should implement only:

- One `workspaceWindow`
- One side-by-side root split
- Collapsible left sidebar, content pane, and collapsible right inspector
- One `workspaceTabGroup`
- Open, select, edit, save, and close several document tabs
- One shared status area
- Bound pane state and bound tab selection
- AppKit native composition
- Headless reconciliation and lifecycle tests

The types already cover, but the first slice defers:

- Nested editor groups: the pane tree supports them, but focus/active-group testing should follow the one-group slice.
- Tab drag and tear-out: `TabTransferRequest` fixes the state contract before native drag sessions are added.
- System document-window tabbing: it remains independent and can be validated after the workspace path.
- Automatic restoration storage: `restoredState` defines ownership, but the first slice can use `propertyState` while the restoration service is designed.
- Physical suspension of inactive tabs: the first implementation retains hidden native content; suspension requires a separate resource-policy and restoration proof.

None of these deferred items changes the surface ownership model described above.

## 15. Implemented vertical slice

The first implementation now proves the semantic/backend boundary with:

- Core identities and concrete semantic specifications for documents, tabs, tab groups, pane hosts, movable workspace items, pane trees, status controls, and workspace windows
- Pure workspace validation and selected-tab successor logic
- Headless rendering of flat and workspace windows
- An AppKit `NSSplitView` composition with native sidebar/content/inspector hosts
- Independently keyed item host views that can be reparented between panes
- Explicit AppKit enforcement of the first-slice one-level split boundary; nested `PaneTree` values remain valid Core data but are rejected by this adapter until recursive native lowering is implemented
- A native tab strip, selected content hosts, selection and close-request callbacks, and a shared native status area
- Retained `NSTextView` state across ordinary reconciliation; unchanged pane trees are not detached during updates
- A one-window text editor with multiple document tabs, left open-document information, right document information, shared status, syntax highlighting, Save, and dirty-close negotiation
- Pure, headless, and deterministic native tests, including tab selection/close event delivery and zero-resource shutdown

The current production `HaskeLUI.Core` is still a compiled vertical-slice IR rather than the final opaque `View model` package described in this document. It carries concrete `[Control]` leaves and explicit selected/pane state. The later public-surface migration will lower `WorkspaceItem model`, `StateSource`, and typed combinators into this semantic IR without changing the AppKit ownership and event contracts proven here.
