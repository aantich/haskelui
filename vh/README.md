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
- Explicit **Open Folder…** selection trusts that workspace for compiler
  tooling. `.vihs` records the restoration preference and a separate per-user
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
analysis-protocol  explicit V1 JSON messages and bounded length framing
analysis-client    child-process supervision, generations, restart, and replay
workers/fake       deterministic real-process integration worker
workers/ghc-9.10   hie-bios project discovery and direct GHC 9.10.3 analysis
```

The production editor registers the process client through
`VisualHaskell.Analysis.Service`, a typed HaskeLUI service adapter. Opening a
workspace configures the component cradle, and every open Haskell buffer is
sent as a revision/hash-bound full snapshot. The status bar reports worker,
workspace, component, and diagnostic state. Visual Haskell accepts a semantic
result only if worker generation, workspace generation, component session,
document identity, revision, and content hash still match the current pure
model.

The GHC worker is a sibling executable and the `vh` build target includes it
automatically. It uses `hie-bios` 0.18 for explicit or implicit project flags,
requires a trusted workspace, and keeps every direct `ghc` import inside its
GHC-9.10 compatibility namespace. The UI process never links GHC. This
repository includes an explicit multi-component `hie.yaml`, which avoids
ambiguous `stack repl` selection in the self-hosting workspace.

Reviewed trust now survives launches. `.vihs` records the requested editor
state, while the user-owned canonical-workspace registry is the independent
security authority. Removing either record restores the workspace as
untrusted.

Focused verification covers the real Stack component, two dependent unsaved
modules, revision-bound compiler diagnostics, stable declaration/type DTOs,
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
