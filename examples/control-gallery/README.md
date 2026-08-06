# UIH Core control gallery

This is the executable conformance fixture for the portable Core catalog. One
pure Haskell application declares every `Control` constructor, including all 50
catalog kinds and the four original vertical-slice controls. Controls share a
model so edits, selections, values, commands, presentations, and disclosure
state visibly reconcile through the backend.

On macOS:

```console
stack run uih-control-gallery
```

The six tabs keep the complete catalog usable in one native window. Every
collection/navigation peer is permanently captioned so the native table cannot
be confused with the neighboring list, grid, tree, repeater, or source list.
Run `stack run uih-control-gallery -- --collections` to open that comparison
directly, or use `--layout` for the portable layout lab. The model
test proves catalog coverage, identity uniqueness, validation, and headless
retention. The native test additionally verifies rich-text attributes,
first-responder continuity while editing/selecting, distinct collection peers,
an `NSTableView` header, columns and alternating rows, popover
presentation/dismissal, and deterministic resource release.
