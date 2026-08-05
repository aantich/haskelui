# ADR 0003: Explicit file effects and the native text-editor slice

Status: Accepted
Date: 2026-08-05

## Context

A credible multi-window editor needs more than a multiline widget. It must keep document transitions pure while requesting native file selection and impure file reads/writes; route Save to the active window; correlate completion with the written revision; negotiate dirty close; and preserve native text behavior.

Calling `IO` from a button callback would hide ordering, failure, testing, and future cancellation. Putting paths or `NSOpenPanel` values into AppKit-specific application code would also violate the backend-independent surface.

## Decision

The current vertical runtime adds explicit first-order file effects to `Transaction`:

- `RequestOpenTextFiles`
- `ReadTextFile path`
- `WriteTextFile effectKey path contents`

Their normalized results return as `UIEvent` values. File chooser realization belongs to the shell backend; byte reading, UTF-8 decoding, encoding, and writing belong to the runtime effect interpreter. Views and event handlers remain pure descriptions.

`EffectKey` correlates a write result with a document, and the completion event carries the exact written text. A document becomes clean only for that snapshot; edits made while a write is in flight remain dirty.

The semantic `TextEditor` control maps to an AppKit `NSTextView` hosted by `NSScrollView`. AppKit owns caret, selection, scrolling, find UI, local undo, accessibility, and native text input. The Haskell model remains authoritative for document contents and dirty state. `WindowActivated` supplies the minimal focus context needed by global commands.

The current file interpreter is deliberately synchronous and UTF-8-only. This proves the effect boundary but is not the final task executor. Production background I/O must deliver completion back on the UI runtime, carry owner/revision identity, support cancellation where meaningful, and never call backend UI objects from worker threads.

## Syntax-highlighting direction

Highlighting is editor presentation, not attributed document content. A highlighter consumes an immutable text snapshot and returns revisioned semantic spans. Themes map semantic token classes to styles; backends convert the snapshot's abstract ranges to native units.

AppKit applies attributes through `NSTextStorage` without changing characters, selection, marked IME ranges, or undo history. Stale revisions are discarded. Full-document pure highlighting is acceptable for the V2 proof; incremental and asynchronous highlighting are later optimizations behind the same contract.

## Consequences

- Applications can test file workflows without AppKit.
- The native Open panel and multiline editor stay behind the backend boundary.
- Save completion cannot incorrectly erase newer dirty state.
- The explicit effect list is a concrete vertical-slice subset of the eventual typed effect/executor API, not a commitment to a permanently closed algebra.
- Production document services still need Save As, atomic replacement, encoding policy, external-change handling, app termination negotiation, restoration, and background execution.
