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

## V2 syntax highlighting contract

Syntax highlighting will extend editor presentation without changing document ownership:

```haskell
data HighlightSpan = HighlightSpan
  { highlightRange :: TextRange
  , highlightClass :: SyntaxClass
  }

data TextPresentation = TextPresentation
  { presentationRevision :: TextRevision
  , presentationSpans :: [HighlightSpan]
  }
```

The highlighter consumes an immutable text snapshot and returns semantic classes such as keyword, string, comment, type, and number. Themes map those classes to platform text styles. Ranges are validated against the originating snapshot; native UTF-16, parser-byte, and custom-renderer offsets remain internal conversion details.

The AppKit adapter will apply foreground/font attributes to `NSTextStorage` in one editing batch while preserving characters, selection, marked IME text, and the native undo stack. A result whose text revision is no longer current is discarded. V2 may begin with a pure full-document highlighter; larger files can later move the same revisioned request to the asynchronous effect executor and then to incremental changed-range highlighting.
