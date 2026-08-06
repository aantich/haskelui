# Portable drawing primitives

This standalone example exercises every primitive currently supported by
`HaskeLUI.Drawing`: rectangles, rounded rectangles, ellipses, compound paths,
non-zero and even-odd fills, quadratic and cubic curves, stroke caps, joins and
dashes, affine transforms, nested clipping, group opacity, and explicit-box
text layout.

Run the native macOS gallery:

```console
stack run haskelui-drawing-primitives
```

Run its deterministic display-list and native paint-pass tests:

```console
stack test haskelui-example-drawing-primitives
```

The model test uses the headless backend to inspect the normalized display
list. The macOS test forces the AppKit view through an offscreen bitmap paint
pass and verifies that all native resources are released during shutdown.
