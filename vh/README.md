# Visual Haskell

This example is the first document-oriented HaskeLUI vertical slice. Run it on macOS from the repository root:

```console
stack exec vh
```

Visual Haskell stores portable workspace metadata in `<project>/.vihs`. It
remembers tab order and selection, expanded project folders, explorer
selection, and pane state. The most recently opened workspace is restored at
the next launch. Workspace paths are project-relative and malformed state is
preserved rather than overwritten.

## Workspace behavior

- Open one or several UTF-8 files through the native AppKit Open panel or Command-O.
- Choose a project root with **File > Open Folder…**. The sidebar renders a
  native folder hierarchy with open/closed folder icons and file icons.
- Load directory children lazily when a folder is expanded, instead of
  recursively scanning build outputs and hidden dependency trees up front.
- Toggle folders by activating their row or the native disclosure control.
- Open a file from the hierarchy in a new document tab; selecting a file that
  is already open activates its existing tab.
- Keep files as keyed document tabs inside one native workspace window.
- Compose a native split view with a project sidebar, central tab group,
  document inspector, and shared status area.
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

The V1 file interpreter reads and writes UTF-8, strips an input UTF-8 BOM, and
performs file I/O synchronously. Directory enumeration is one level per
`ReadDirectory` effect, with folders ordered before files. It does not yet
provide filesystem watching, ignore-file rules, refresh, Save As, atomic
replacement, external-change detection, encoding selection, app-level Quit
negotiation, restoration, or background I/O. Those are production
document-runtime concerns, not AppKit-specific editor behavior.

## V2 syntax highlighting

Haskell source files (`.hs` and `.lhs`) are highlighted by a synchronous, pure lexer. Syntax concepts stay in the example rather than HaskeLUI Core:

```haskell
highlightHaskell :: Text -> [TextSpan SyntaxClass]

syntaxStyle :: SyntaxClass -> TextStyle
```

The example theme resolves those semantic spans into generic, revision-bound `TextLayer` values. HaskeLUI Core knows only portable `TextStyle`, generic `TextSpan a`, authored `TextRun`/`AttributedText`, and ordered presentation layers. The same primitives can represent rich text, search results, diagnostics, spellchecking, or another application's annotations.

The AppKit adapter resolves overlapping layers property-by-property, converts public Unicode scalar ranges to native UTF-16 ranges, and applies temporary layout attributes. Presentation does not modify characters, authored attributes, selection, or the native undo stack. Layers carrying an obsolete revision are discarded.

This first highlighter reparses the complete document after each edit and intentionally supports only a useful lexical subset of Haskell. Large-file background highlighting, incremental changed-range processing, parser-grade language coverage, theme selection, and a language-provider registry are later optimizations and extensions behind the same generic layer contract.
