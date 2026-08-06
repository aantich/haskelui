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

The five tabs keep the complete catalog usable in one native window. The model
test proves catalog coverage, identity uniqueness, validation, and headless
retention. The native test additionally verifies rich-text attributes,
first-responder continuity while editing/selecting, distinct collection peers,
popover presentation/dismissal, and deterministic resource release.
