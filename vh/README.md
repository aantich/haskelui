# Visual Haskell

Visual Haskell is the featured document-oriented HaskeLUI application. Run it
on macOS from the repository root:

```console
stack exec vh
```

For detailed JSONL diagnostics, run `stack exec vh -- --debug`. The terminal
prints the generated log path. `--debug=PATH` or `--debug-log PATH` selects an
explicit destination.

Visual Haskell stores portable workspace metadata in `<project>/.vihs`. It
remembers tab order and selection, expanded project folders, explorer
selection, and pane state. The most recently opened workspace is restored at
the next launch. Workspace paths are project-relative and malformed state is
preserved rather than overwritten.

## Workspace behavior

- Open one or several UTF-8 files through the native AppKit Open panel or Command-O.
- Choose a project root with **File > Open Folder…**. The sidebar renders a
  native folder hierarchy with open/closed folder icons and file icons.
- **Open Folder…** does not execute project tooling. Choose **Trust…** in the
  sidebar or **File > Trust Workspace for Haskell Analysis** to authorize it.
  `.vihs` records the restoration preference and a separate per-user
  registry authorizes the normalized path. Automatically restored workspaces
  regain trust only when both records agree; a repository cannot self-trust.
- Load directory children lazily when a folder is expanded, instead of
  recursively scanning build outputs and hidden dependency trees up front.
- Toggle folders by activating their row or the native disclosure control.
- Open a file from the hierarchy in a new document tab; selecting a file that
  is already open activates its existing tab.
- Keep files as keyed document tabs inside one native workspace window.
- Compose a native split view with a project sidebar, central tab group,
  document inspector, and shared status area.
- Commit native divider drags into the Haskell pane model, preserve them across
  tab switches, and persist the resulting extents in `.vihs`.
- Follow the live operating-system light/dark appearance in the editor base
  palette and select the matching bundled TextMate theme without changing
  document state, selection, or undo history.
- Show accepted current-revision GHC diagnostics as independently colored
  underlines without replacing syntax foregrounds.
- List compiler problems in a native inspector tab. Selecting one activates
  its existing document tab, selects the exact range, scrolls it into view,
  and focuses the editor.
- Keep pane hosts and movable workspace items as distinct identities so content can later move between pane locations without losing retained state.
- Route text changes into the pure Haskell document model.
- Route native tab selection and close requests into the pure Haskell workspace model.
- Track the selected document tab so Command-S targets the correct document.
- Mark documents dirty by comparing current and last-written text.
- Correlate write completion with the exact document and exact written snapshot, so a completed older write cannot mark newer edits clean.
- Defer a dirty tab close; saving that document then completes the tab close.
- Keep the empty workspace open after its last tab closes, while closing the clean workspace removes its OS window.
- Report read/write failures in the UI without hiding file `IO` inside view callbacks.

## Property and binding example

The editor uses the production `HaskeLUI.Property` and `HaskeLUI.Binding` APIs rather
than treating them as an isolated demo:

- Total workspace fields use checked dotted paths such as
  `editorProperties.selectedTab .= Just tabKey`.
- Multi-field workspace changes use `batchActions` and preserve all touched
  `PropertyId` values.
- Documents live behind dynamic `Map DocumentKey Document` entries, so the
  example does not pretend they are total lenses from `EditorModel`.
  `documentContentsBinding` uses the callback-controlled binding escape hatch
  and explicitly lifts total child-document actions through the established
  key.
- A text edit atomically updates contents, revision, status, and deferred-close
  state with one coalescing undo policy.
- Save uses `transactionFromActionWithEffects`, retaining property metadata
  while launching the explicit file-write effect.

This is also a concrete example of the future keyed-child adapter boundary:
the lifting code is small and safe, but remains explicit until Core defines a
general missing-key/stale-action policy.

The V1 compatibility file interpreter reads and writes UTF-8, strips an input
UTF-8 BOM, and performs file I/O synchronously. Directory enumeration is one
level per `ReadDirectory` effect, with folders ordered before files. HaskeLUI's
generic task/service/subscription runtime is now available; migrating these
operations to scoped tasks and adding a filesystem-watch subscription is the
next document-layer step. Ignore-file rules, refresh policy, Save As, atomic
document replacement, external-change conflict handling, encoding selection,
and app-level Quit negotiation remain production document concerns rather than
AppKit-specific behavior.

## TextMate syntax highlighting

The production editor highlights Haskell, JSON, JavaScript, Python, and Markdown through
the VH-owned `visual-haskell-textmate` package. The engine loads declarative
TextMate grammars and themes, uses vendored native Oniguruma 6.9.10, caches
state per line, and sends immutable snapshots through HaskeLUI's typed service
runtime. Revision and content-hash checks prevent stale results from replacing
newer presentation.

HaskeLUI Core remains language-neutral. The old pure Haskell lexer still
provides an immediate/failure fallback through the same generic API:

```haskell
highlightHaskell :: Text -> [TextSpan SyntaxClass]

syntaxStyle :: ColorScheme -> SyntaxClass -> TextStyle
```

Both paths resolve into generic, revision-bound `TextLayer` values. HaskeLUI
Core knows only portable `TextStyle`, generic `TextSpan a`, authored
`TextRun`/`AttributedText`, and ordered presentation layers. The same
primitives can represent rich text, search results, diagnostics, spellchecking,
or another application's annotations.

The AppKit adapter resolves overlapping layers property-by-property, converts public Unicode scalar ranges to native UTF-16 ranges, and applies temporary layout attributes. Presentation does not modify characters, authored attributes, selection, or the native undo stack. Layers carrying an obsolete revision are discarded.

Visual Haskell creates these user directories on launch:

```text
~/.vh/extensions  # unpacked declarative VS Code extensions
~/.vh/grammars    # standalone TextMate grammars
~/.vh/themes      # standalone TextMate themes
```

Copying, modifying, renaming, or removing a resource triggers a registry reload.
Visual Haskell reads only language, grammar, and theme contributions and never
executes extension JavaScript or binaries. Set `VH_HOME` to use another root.
The editor bundles VH-owned initial providers and records their provenance in
`vh/packages/textmate/resources/PROVENANCE.md`.

The current engine covers the TM1 rule core plus JSON/XML plist files, `while`,
back-reference substitution, basic theme selectors, and incremental line
caching. Cross-grammar includes, injection execution, embedded languages,
semantic tokens, and the large differential compatibility corpus are still
future compatibility work.

## Compiler-analysis foundation

Visual Haskell now has a compiler-independent analysis spine under
`vh/packages` and `vh/workers`:

```text
semantic-model     stable identities, snapshots, diagnostics, declarations,
                   structured types, and Unicode coordinate conversion
analysis-protocol  explicit V2 JSON messages and bounded length framing
analysis-client    child-process supervision, generations, restart, and replay
projects           GHC-free project coordinator, toolchain selection and inventory
workers/fake       deterministic real-process integration worker
workers/ghc-9.10   shared adapter source compiled with GHC 9.6.7 or 9.10.3
```

The production editor registers the process client through
`VisualHaskell.Analysis.Service`, a typed HaskeLUI service adapter. Opening a
workspace configures the component cradle, and every open Haskell buffer is
sent as a revision/hash-bound full snapshot. The status bar reports worker,
workspace, component, and diagnostic state. Visual Haskell accepts a semantic
result only if worker generation, workspace generation, component session,
document identity, revision, content hash, and all open dependency-buffer inputs still match the current pure
model.

### Existing toolchains, not an IDE-owned Haskell installation

The native **Project** inspector discovers installed GHCs using GHCup's offline
CLI and the existing PATH. Select **Project-selected compiler**, an installed
compiler, or an absolute executable path. Cabal's `with-compiler` and Stack's
resolver/compiler checks remain authoritative. An incompatible override reports
an error; the IDE does not rewrite project files or run `ghcup set`.

**Open GHCup TUI…** opens the existing `ghcup tui` in the system's external
terminal. Install/remove toolchains there, return to the IDE, and use **Refresh
installed toolchains** (returning from the TUI also requests a refresh). The IDE
does not scrape the TUI, embed a terminal emulator, install GHC automatically,
maintain a second compiler catalogue, or change the global compiler selection.
The native AppKit application currently targets macOS; the coordinator's Unix
terminal fallback is not a Windows backend.

The compiler-independent `visual-haskell-project-coordinator` asks the selected
build tool for the actual compiler. It validates the worker's exact version,
target platform, GHC API package identity **and ABI hash** before executing
analysis. The supported/tested adapter versions are currently **9.6.7 and
9.10.3**; other installed compilers remain discoverable and editable but need an
additional tested API adapter. The legacy `ghc910` package/executable/module
names are retained for compatibility; there is only one maintained source tree.

For explicit `hie.yaml` projects, a short-lived probe mode in the bundled
adapter asks hie-bios for the cradle's runtime compiler before choosing the
analysis adapter. The probe's own GHC version does not have to match the
project, and the coordinator still does not link the GHC API. A compatible
bundled adapter is therefore required for cradle discovery, even when the
project's matching adapter has not yet been built.

If the compiler is installed but its adapter is missing, choose **Build matching
analysis worker**. This runs the existing `cabal-install` with the explicit
installed compiler and its ordinary shared package store. Library downloads
may be needed on the first build; no compiler is downloaded. IDE-owned adapter
executables/build artifacts are cached once per compiler ABI under
`$XDG_CACHE_HOME/visual-haskell/workers` (the platform default cache when unset),
not duplicated per project. Source changes invalidate cached adapters. Build
publication is locked and atomic. Stack metadata readers are likewise shared
per compiler/Cabal package/source identity; Cabal's own API validates configured
metadata. Stack/Cabal continue to own dependency resolution, Hackage indexes,
snapshots, package versions, and stores. Different projects may use different
versions of a library without any IDE-side Hackage version manager.

Compiler switching/reload/restart preserves authoritative unsaved documents;
compiler objects never cross the JSON protocol boundary. Prepared project
contexts are separately cached by workspace and compiler fingerprint. Trust,
cancellation, stale-result checks and process-group cleanup apply to worker
building and preparation as well as analysis. Compiler overrides are restored
from `.vihs` v4 but never grant workspace trust.
Refresh and adapter rebuild also begin a new semantic generation immediately:
old diagnostics, editor assistance and composition results disappear even if
discovery/build fails. Rebuild waits for the new generation's compiler identity.

Tool overrides for GUI environments are `VH_GHCUP`, `VH_GHC`, `VH_CABAL`,
`VH_STACK`, `VH_PROJECT_COORDINATOR`, and `VH_ANALYSIS_WORKER`. An explicit
worker still must pass ABI validation. Child processes receive private PATH
aliases to the exact resolved Cabal/Stack tools; renamed/versioned overrides
also work when a GUI launch has only `/usr/bin:/bin` on PATH. The aliases never
modify the user's shell environment, and cradle Stack commands cannot install
a compiler automatically. Worker sources are found in the checkout
or `VH_WORKER_SOURCE_ROOT`. For installed distributions, run:

```console
bash tools/package-worker-sources.sh /absolute/release/bin/visual-haskell-worker-sources.tar.gz
```

Ship that generated archive beside the coordinator (or set
`VH_WORKER_SOURCE_BUNDLE`). It contains canonical adapter/shared package sources,
not compilers or dependency stores; the coordinator validates and extracts it
once into the shared cache. Release packaging must include the coordinator,
the application's native resources, and at least one compatible bundled adapter
for cradle probing (normally the application's build-GHC adapter). Include
either additional prebuilt adapters or this archive for other project GHCs.
Ordinary development builds use the checkout directly. For a
manual Cabal adapter build, set `VH_PROJECT_COMPILER` to the same absolute GHC
path passed to `--with-compiler`; the compile-time ABI check rejects mismatches.

Useful diagnostics, outside `stack exec`'s build lock:

```console
visual-haskell-project-coordinator --toolchains
visual-haskell-project-coordinator --inspect-compiler /absolute/path/to/ghc
visual-haskell-project-coordinator --build-worker /absolute/path/to/ghc
bash tests/visual-haskell/validate-project-loading.sh toolchains
```

The last command requires both supported compilers already installed and tests
real Cabal/Stack projects, missing-adapter builds, Template Haskell, unsaved
errors/recovery, typed composition, compiler switching, and restart replay.

## Stack and Cabal projects

1. Open a folder and explicitly trust it. Project configuration, Custom Setup,
   preprocessors, Template Haskell and plugins can run code; trust is not a sandbox.
2. Choose **Stack · stack.yaml** or **Cabal · cabal.project** in the sidebar.
   When both tools or named alternative configurations exist, the IDE asks you
   to choose. Standalone `.cabal` packages and Stack's Hpack `package.yaml` are
   supported; no generated `hie.yaml` is required.
3. Open a Haskell file. Its owning component is selected automatically if
   unambiguous. For shared sources, select a library, internal library,
   executable, test or benchmark in the component selector.
4. Use **Project** in the inspector for bounded preparation logs and errors.
   **Cancel** stops preparation/analysis and its child processes without closing
   buffers. **Reload** retries discovery/preparation. **File > Revoke Workspace
   Analysis Trust** stops tooling and removes the saved authorization.

Each selected component retains its actual compiler flags, CPP definitions,
source directories, generated inputs, package environment and local-library
home units. Unsaved edits in an open local dependency participate in downstream
analysis; they are never written to disk for GHC. Configuration changes and
closed-source changes trigger a fresh context; open buffers remain authoritative.
Profile, component and per-file context choices are restored from `.vihs` v3.
Profile choices remain available even if a restored configuration fails to load.
Cabal discovery does not force optional test/benchmark dependencies to resolve;
their declared components remain selectable and are prepared on demand. If an
explicitly enabled optional component breaks planning, required components use
an isolated plan with tests/benchmarks disabled and the Project log explains it.

Cabal uses `Cabal-syntax` inventory plus hie-bios 0.21 unit environments. Stack
uses its own preparation hooks and a small helper compiled against the
project's configured Cabal library to read per-unit metadata. Neither requires
HLS/ghcide or rewrites project configuration. Analysis outputs live in IDE-owned
caches, separate from Stack's build artifacts. A single live compiler session
and at most two prepared contexts bound memory; changing component can incur a
cold analysis.
Project tools discard inherited `GHC_PACKAGE_PATH`/`GHC_ENVIRONMENT` overrides,
so launching the IDE with `stack exec vh` does not contaminate Cabal projects.
Cancellation interrupts worker startup, replay and blocked input writes as well
as ordinary analysis, and waits for the compiler process group to be stopped.

The shared adapter supports **GHC 9.6.7 and 9.10.3**, with Stack metadata tested
against Cabal **3.10.x and 3.12.x**, on macOS. Other project compilers report an actionable
error and leave editing available; additional worker versions are not silently
substituted. Build tools and dependencies must be available in the environment.
This is project loading/semantic editing, not a build/run/debug UI. Index coverage
is the active component and its visible dependencies, not every project component.

Run the real toolchain acceptance matrix outside an enclosing `stack exec`:

```console
tests/visual-haskell/validate-project-loading.sh          # Stack and Cabal
tests/visual-haskell/validate-project-loading.sh self-host
tests/visual-haskell/validate-project-loading.sh regressions
```

The matrix covers local-package unsaved edits, distinct/shared component
contexts, crash replay, cancellation, atomic configuration replacement, Hpack,
internal libraries, benchmarks, paths with spaces, conditional source roots,
named configurations, Custom Setup-generated sources and local dependencies,
unavailable optional dependencies, failed-profile recovery, Stack-launched
Cabal loading, slow Template Haskell cancellation and standalone Cabal.

## Semantic universe inspectors

### Component and library palette

In **Functions**, choose **Component + libraries** to index the actual cradle's
declared module graph, including unopened/unimported local modules, and the
package modules visible to that component's compiler. Search by name, qualified
module, package/version, or signature; choose functions, types/classes, or all
symbols. Results are paged (50 per page). Coverage and unavailable/ambiguous
module warnings are shown explicitly. Nothing executes until workspace trust
has been granted, and current-file browsing does not trigger the full index.

Select a function and choose **Add function**, then move/connect its canvas
card. Search changes never remove existing cards. GHC checks mixed local/library
chains using temporary qualified imports, verifies their exact compiler symbol
identities (including the defining unit), and restores the interactive context.
Hidden implementation modules are not mistaken for the importable re-export
module. Private exports cannot be selected from another module. The canvas is
an exploratory composition view; it does not insert imports or rewrite source.
Incomplete indexes preserve unavailable pinned cards, their positions, and wires
as stale instead of treating missing results as deleted declarations. Those cards
cannot show successful composition feedback or navigate stale source. Usable
library-only chains remain checkable even if an unrelated local module fails.

Each symbol carries its own structured type table, constructor/class semantics,
import module, unit, package/version and optional real source location. Local
card navigation checks the defining source hash before opening an unopened file,
including re-exports, and reuses already-open buffers through their original
editor paths (even when the compiler uses canonicalized paths). Library
interfaces are read-only and do not receive synthetic source coordinates.
The separate Types diagram continues to show accepted open-document snapshots;
the global palette is not advertised as full-project diagram coverage.

The existing compiler session owns the index. Open-buffer hashes and local
module content hashes invalidate its in-memory cache. Immutable library
projections are cached atomically under the OS cache directory at
`visual-haskell/symbol-index/v2`, keyed by compiler location/version, unit ABI,
and export module; they are reused across projects without copying Hackage
indexes, package sources, or compiler installations. Corrupt/missing cache
entries are rebuilt. Local/unsaved source is never persisted in that cache.
Responses remain bound to request, all-open-buffer input hash, active document,
compiler session and worker/workspace generation.
Index revisions also cover closed source and Template Haskell dependent files;
accepted revisions invalidate old composition results even when the active text
and function identities are unchanged. Changing an unmonitored non-source TH
input requires **Refresh** in the palette; a new index never reuses old feedback.

Indexing loads all declared targets and may execute trusted Template Haskell,
just like project typechecking. The first global query can be noticeably slower
than a warm search. Failed local graphs report partial coverage; broken unrelated
open buffers outside the declared graph are excluded. Switch components to browse
their different dependency visibility. Haddock text, downloaded package source,
cross-component aggregation and palette-to-canvas drag-and-drop remain future UI
extensions (canvas cards themselves are draggable).

The **Outline** tab lists current compiler declarations and their signatures in
source order. Selecting a declaration reveals its exact source range. In a
trusted, successfully analyzed Haskell document:

- Pause over an identifier for its GHC-inferred type and defining module.
- Command-click an identifier, or press F12 at the caret, to go to its source
  definition, including unsaved definitions in another open module.
- Press F5 (or Control-Space when not reserved by macOS) for scope-aware completion.
  Use Up/Down and Return/Tab, click a suggestion, or Escape to dismiss.
  Completion uses the native
  editor's normal insertion/undo path and never previews edits into the buffer.

Queries use GHC's enriched typed syntax tree and reader environment inside the
existing worker. No HLS, LSP server, or additional compiler process is involved.
Every response is tied to a request, document revision/hash, component session,
and worker/workspace generation. Moving away, editing, or changing the caret
invalidates transient assistance. Completion can use the last successful scope
while the current buffer is incomplete; new imports and bindings become
available after the next successful analysis. Navigation to installed package
source is available only when GHC supplies a readable source location; there
is not yet a package source index or Haddock documentation browser.

The inspector includes independent **Types** and **Functions** tabs. Each tab
owns a **Debug mode** switch: the switch changes only that pane and never
changes compiler or document state. The Types tab also selects **Current File**
or **Project** scope.

Types Debug mode renders the exact `TypeUniverse` value constructed from
accepted analysis snapshots. Its monospaced, selectable, scrollable text shows:

- Scope and focused-document identity
- Overall coverage, explicitly distinguishing no data, one exact document,
  accepted snapshot coverage, and a future fully indexed project
- Every contributing document's generation, session, revision, content hash,
  completeness, and freshness
- Stable type-entity and declaration identities
- Current-file, workspace, package, built-in, or unknown origin
- Source editability, declared-type identity, parameters/kinds, signature,
  semantic type, and source ranges
- Algebraic/newtype constructors, including existential variables, GADT
  constraints and result types, positional arguments, record fields, and
  source ranges
- Type-alias right-hand sides, superclass constraints, and class methods
- All declaration-to-type usages, including function signatures
- The normalized structured-type table and typed reference, alias,
  constraint, superclass, and recursive-SCC relationship edges

Rich mode consumes this same immutable contract; Debug mode is not a parallel
representation that can drift from it. The interactive drawing surface shows
typed cards and relationships for the selected scope:

- ADTs expose constructors and nested record fields; newtypes, aliases,
  classes, families, and unresolved declarations retain distinct visual forms.
- Current-file, workspace, package, built-in, unknown, and external-reference
  origins use both labeled badges and color accents, so provenance never relies
  on color alone.
- Reference, alias, constraint, superclass, and recursive edges have distinct
  line/label styles. Mutually recursive SCCs receive a visible family hull.
- Click cards, rows, edges, or recursive families to select them. Drag a card
  to pin its position, drag empty canvas to pan, and scroll to pan. Command- or
  Control-scroll zooms around the pointer.
- Collapse a card with its disclosure control. Double-click a declaration,
  constructor, field, or method to activate its source tab and exact range.
- Scene projection, layout, routing, rendering, hit testing, and interaction
  live in the pure `visual-haskell-type-diagram` package. AppKit only compiles
  the resulting generic HaskeLUI drawing and input values.
- The inspector divider has no artificial maximum width. Before the first
  current snapshot arrives, rich mode shows a native activity indicator and
  the live GHC status instead of a misleading empty canvas.
- Exact local alias RHS matches are represented by their declared alias card,
  so fields written via aliases such as `TraceSink` do not fan out into
  implementation details such as `Char` and `IO`. Constructor result types do
  not generate false recursive loops.
- Function-valued fields remain one structured relationship. Their argument
  and result endpoints appear as compact cards connected by a bold arrow;
  long curried chains collapse through an ellipsis whose hover detail shows the
  full type.
- Cards size to their contents within configurable bounds. Truncated headers,
  provenance, and row types expose their complete text in a drawing-surface
  hover popover. External cards show the defining GHC module when known rather
  than the generic “external reference” label.

`TypeUniverse` models ADTs, newtypes, aliases, classes, constructors, record
fields, methods, origins, and recursive/reference relations. The GHC 9.10
worker projects those
shapes directly from GHC's typed `TyCon`, `DataCon`, and `Class` values; the
universe never guesses structure from pretty-printed text. Compiler symbol
identity uses unit, module, namespace, and occurrence rather than session-local
GHC `Unique` values or context-dependent pretty-printer qualification.

The Types diagram's Project scope remains deliberately honest: it combines accepted open-
document snapshots, which the coverage field reports as
`accepted-snapshots`; it does not yet consume the component/library palette's
index. Referenced package and built-in constructors remain present in its
structured type table. Materializing indexed package declarations as full
diagram entities remains a separate integration step. Type-family
declarations are identified, but family equations are deferred until the
semantic contract can represent open families, closed ordered equations, and
imported instances without conflating them.

The **Functions** tab consumes a dedicated, compiler-independent `FunctionNode`
model derived from current typed value declarations and indexed exports, not the type-universe
preview. Select a function and choose **Add function**, then drag or click its
output circle onto another card's input. Cards can be moved, scroll pans, and
Command-/Control-scroll zooms. Double-click a source-backed card to reveal its declaration.
Widen the inspector using its divider to give the canvas more room.

Connections form a linear composition (up to 32 cards). Each wire represents
one Haskell application, retaining any curried arguments in the output type.
GHC checks the complete chain, including polymorphism, typeclass constraints,
and type synonyms, and returns its inferred type or a type mismatch. Wires are
green for a valid composition, red for a rejected one, and gray while unchecked.
Types are never compared by string equality. Debug mode shows the exact
function identities, signatures, and ports. **Clear** starts a fresh canvas.

This first canvas is an exploratory, current-file workspace: it does not
execute functions, rewrite source, or persist its layout. Branching graphs,
imported-function palettes, named multi-argument ports, graph editing/undo,
transformer-stack views, and Arrow-notation authoring remain separate steps.

To inspect it, open and trust a Haskell workspace, wait for a current GHC
result, select **Types**, and switch between the two scopes. Enable **Debug
mode** to compare the diagram with its complete textual semantic foundation.

The GHC worker is a sibling executable and the `vh` build target includes it
automatically. It uses `hie-bios` 0.21 for explicit or implicit project flags,
requires a trusted workspace, and keeps every direct `ghc` import inside its
GHC-9.10 compatibility namespace. The UI process never links GHC. This
repository includes an explicit multi-component `hie.yaml`, which avoids
ambiguous `stack repl` selection in the self-hosting workspace.

Project-loading Stage 0 has a separate research harness:

```console
tests/visual-haskell/validate-project-loading-stage0.sh
```

It copies two-package fixtures into temporary directories, exercises implicit
and explicit Stack/Cabal environments, and tests unit-preserving unsaved edits.
This is not yet general multi-component loading in the editor: product routing,
component selection, dependency freshness, and configuration watching remain the
next implementation stages. See the Stage 0 findings in
[`visual-haskell-analysis-spine.md`](../docs/design/visual-haskell-analysis-spine.md#10-project-loading-stage-0).

The worker discovers the active component and initializes one persistent
`runGhc` session on the first analysis. Later full document snapshots update
in-memory targets inside that same session with stable per-revision timestamps,
allowing GHC to reuse its module graph and parsed/typechecked cache. Every open
buffer remains a target so unsaved dependencies are authoritative, but each
request loads only the requested module and its dependency closure; unrelated
open reverse dependants are not compiled. The focused fixture currently
measures about 1.25 s for a cold load and 4–5 ms for warm broken/recovered
edits. These measurements are diagnostic baselines rather than public timing
guarantees.

The current adapters support GHC 9.6.7 and 9.10.3. `hie-bios`, rather than a VH
Cabal/Stack parser, remains the authority for the actual cradle, flags, package
databases, targets, `libdir`, and compiler selection. If the project selects a
different, unsupported GHC, VH reports the missing adapter and keeps the editor,
project tree, persistence, and TextMate highlighting available; it does not
attempt unsound best-effort analysis with another compiler's API. Exact workers
are selected by the coordinator; missing supported adapters can be built using
the existing compiler. Compiler installation remains in the external GHCup TUI.

Reviewed trust now survives launches. `.vihs` records the requested editor
state, while the user-owned canonical-workspace registry is the independent
security authority. Removing either record restores the workspace as
untrusted.

Focused verification covers the real Stack component, two dependent unsaved
modules, warm-session error/recovery, revision-bound compiler diagnostics,
stable declaration/type DTOs,
an actual forced GHC-worker crash followed by authoritative replay, and a full
Visual Haskell runtime result reaching the rendered status surface:

```console
stack test visual-haskell-semantic-model \
  visual-haskell-analysis-protocol \
  visual-haskell-analysis-client \
  visual-haskell-analysis-ghc910 \
  visual-haskell:vh-analysis-service-test --fast --jobs 1

tests/visual-haskell/validate-analysis-self-host.sh
```

The second command performs the self-hosted Stack-cradle check after the test
binary has been built. It runs outside an enclosing `stack test`, so the
cradle's own `stack repl` process cannot contend for the outer build lock.

See the [analysis-spine design](../docs/design/visual-haskell-analysis-spine.md)
and [long-term vision](../docs/design/visual-haskell-vision.md).
