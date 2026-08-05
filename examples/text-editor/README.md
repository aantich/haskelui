# UIH multi-window text editor

This example is the first document-oriented UIH vertical slice. Run it on macOS from the repository root:

```console
stack exec uih-text-editor
```

## V1 behavior

- Open one or several UTF-8 files through the native AppKit Open panel or Command-O.
- Realize each file as an independent keyed native window with a scrolling `NSTextView`.
- Route text changes into the pure Haskell document model.
- Track the active window so Command-S and the Save button target the correct document.
- Mark documents dirty by comparing current and last-written text.
- Correlate write completion with the exact document and exact written snapshot, so a completed older write cannot mark newer edits clean.
- Defer a dirty close; saving that document then completes the close.
- Report read/write failures in the UI without hiding file `IO` inside view callbacks.

The V1 file interpreter reads and writes UTF-8, strips an input UTF-8 BOM, and performs file I/O synchronously. It does not yet provide Save As, atomic replacement, external-change detection, encoding selection, app-level Quit negotiation, restoration, or background I/O. Those are production document-runtime concerns, not AppKit-specific editor behavior.

## V2 syntax highlighting

Haskell source files (`.hs` and `.lhs`) are highlighted by a synchronous, pure lexer. Syntax concepts stay in the example rather than UIH Core:

```haskell
highlightHaskell :: Text -> [TextSpan SyntaxClass]

syntaxStyle :: SyntaxClass -> TextStyle
```

The example theme resolves those semantic spans into generic, revision-bound `TextLayer` values. UIH Core knows only portable `TextStyle`, generic `TextSpan a`, authored `TextRun`/`AttributedText`, and ordered presentation layers. The same primitives can represent rich text, search results, diagnostics, spellchecking, or another application's annotations.

The AppKit adapter resolves overlapping layers property-by-property, converts public Unicode scalar ranges to native UTF-16 ranges, and applies temporary layout attributes. Presentation does not modify characters, authored attributes, selection, or the native undo stack. Layers carrying an obsolete revision are discarded.

This first highlighter reparses the complete document after each edit and intentionally supports only a useful lexical subset of Haskell. Large-file background highlighting, incremental changed-range processing, parser-grade language coverage, theme selection, and a language-provider registry are later optimizations and extensions behind the same generic layer contract.
