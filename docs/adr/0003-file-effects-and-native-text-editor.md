# ADR 0003: Explicit file effects and the native text-editor slice

Status: Accepted
Date: 2026-08-05

## Context

A credible multi-window editor needs more than a multiline widget. It must keep document transitions pure while requesting native file selection and impure file reads/writes; route Save to the active window; correlate completion with the written revision; negotiate dirty close; and preserve native text behavior.

Calling `IO` from a button callback would hide ordering, failure, testing, and future cancellation. Putting paths or `NSOpenPanel` values into AppKit-specific application code would also violate the backend-independent surface.

## Decision

The current vertical runtime adds explicit first-order file effects to `Transaction`:

- `RequestOpenTextFiles`
- `RequestOpenProjectFolder`
- `ReadDirectory path`
- `ReadTextFile path`
- `ReadOptionalTextFile path`
- `WriteTextFile effectKey path contents`
- `WriteTextFileAtomically effectKey path contents`

Their normalized results return as `UIEvent` values. File chooser realization belongs to the shell backend; byte reading, UTF-8 decoding, encoding, and writing belong to the runtime effect interpreter. Views and event handlers remain pure descriptions.

Project-folder enumeration follows the same boundary. A backend presents its
native single-folder chooser and returns `ProjectFolderChosen`; the portable
runtime reads exactly one directory level and returns `DirectoryRead` with
file/directory entries. The application owns the project root, stable tree
identities, expansion, loaded state, filtering policy, and file-to-document
routing. One-level reads are intentional: a project opens without recursively
walking `.git`, build products, dependency caches, or symlink-heavy trees.

`EffectKey` correlates a write result with a document, and the completion event carries the exact written text. A document becomes clean only for that snapshot; edits made while a write is in flight remain dirty.

The semantic `TextEditor` control maps to an AppKit `NSTextView` hosted by `NSScrollView`. AppKit owns caret, selection, scrolling, find UI, local undo, accessibility, and native text input. The Haskell model remains authoritative for document contents and dirty state. `WindowActivated` supplies the minimal focus context needed by global commands.

The current file interpreter is deliberately synchronous and UTF-8-only. This proves the effect boundary but is not the final task executor. Production background I/O must deliver completion back on the UI runtime, carry owner/revision identity, support cancellation where meaningful, and never call backend UI objects from worker threads.

## Syntax-highlighting direction

Highlighting is editor presentation, not attributed document content. A highlighter consumes an immutable text snapshot and returns semantic spans, then a theme resolves them into generic HaskeLUI text-style layers. Syntax types stay outside Core; see ADR 0004.

AppKit applies derived styles as temporary layout attributes without changing characters, authored attributes, selection, marked IME ranges, or undo history. Stale revisions are discarded. Full-document pure highlighting is acceptable for the V2 proof; incremental and asynchronous highlighting are later optimizations behind the same contract.

## Consequences

- Applications can test file workflows without AppKit.
- The native Open panel and multiline editor stay behind the backend boundary.
- Project navigators can use a native folder chooser and lazy hierarchy without
  importing AppKit or committing Core to an IDE-specific workspace model.
- Save completion cannot incorrectly erase newer dirty state.
- The explicit effect list is a concrete vertical-slice subset of the eventual typed effect/executor API, not a commitment to a permanently closed algebra.
- Production document services still need Save As, atomic replacement,
  encoding policy, ignore files, filesystem watching/refresh, external-change
handling, app termination negotiation, restoration, and background
execution.

Workspace restoration is now implemented for Visual Haskell metadata. The
versioned `.vihs` format and its failure rules are specified in
`docs/design/visual-haskell-workspaces.md`; unsaved-buffer crash recovery and
background execution remain separate work.
