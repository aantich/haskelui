# ADR 0004: Generic attributed text and presentation layers

Status: Accepted
Date: 2026-08-05

## Context

Syntax highlighting needs styled ranges, but keywords, comments, and language grammars are application or plugin concepts. Putting them in UIH Core would specialize a general text renderer around code editors and would not directly support authored rich text, diagnostics, search matches, spellchecking, or other annotations.

Authored formatting and derived highlighting use the same visual properties while having different ownership. Authored bold, fonts, and colors must eventually participate in persistence, clipboard, dirty state, editing, and undo. Syntax and search presentation must never become document content or create undo actions.

Backends also use incompatible text indices. Haskell-facing lexers naturally operate over Unicode scalar values, while AppKit text ranges use UTF-16 code units and some parsers report UTF-8 byte offsets.

## Decision

UIH Core defines generic portable primitives:

- Partial `TextStyle` values for color, font family/size/weight/slant, underline, strikethrough, letter spacing, and baseline offset.
- Generic `TextSpan a` values over scalar-indexed `TextRange`.
- `TextRun` as an ergonomic continuous-string construction form.
- Opaque, normalized `AttributedText` as one authoritative text snapshot plus styled spans.
- Ordered, keyed, revision-bound `TextLayer` values for non-authoritative presentation.

Later style layers override earlier layers one property at a time. The Core resolver rejects invalid ranges, discards stale revisions, partitions overlaps into non-overlapping styled runs, and preserves unaffected properties from earlier layers.

Syntax providers define semantic token classes outside Core. A provider highlights an immutable snapshot, a theme resolves semantic values to `TextStyle`, and the application supplies the resulting layer to `TextEditorSpec`.

The initial AppKit adapter translates scalar boundaries to UTF-16 and applies resolved runs using `NSLayoutManager` temporary attributes. This preserves character content, native selection, typing state, and undo. Authored rich-text editing is not enabled merely by this presentation path; it will use the shared styles and spans with explicit document editing operations and native attributed-content reconciliation.

## Consequences

- Core remains useful for code editors, rich text, search, diagnostics, and arbitrary styled annotations.
- Syntax packages can evolve language grammars without expanding the backend API.
- Backends receive portable resolved styles rather than language semantics.
- Layer order and stale-result behavior are deterministic and pure-testable.
- Unicode conversion is isolated inside each backend adapter.
- The current whole-document resolver and lexer prioritize a clear vertical slice. Production large-file editing still requires incremental span updates, background execution with revision cancellation, and a more efficient interval structure.
