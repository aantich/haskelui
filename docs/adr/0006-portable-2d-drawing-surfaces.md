# ADR 0006: Portable 2D drawing surfaces and display lists

Status: Accepted
Date: 2026-08-06

## Context

Visual Haskell needs charts, dependency graphs, and an interactive workspace
graph. These require arbitrary 2D paths, text, images, transforms, clipping,
zooming, and pointer input inside otherwise native application windows.

The existing `LayoutCanvas` and `CanvasContainer` are layout concepts. They
position child controls at explicit coordinates but do not provide a drawing
context. Reusing their name or representation for vector drawing would conflate
control layout with painting.

Both initial native platforms provide suitable drawing foundations, but not a
shared component or chart model:

- AppKit hosts custom drawing in an `NSView`; Core Graphics supplies portable
  path, transform, clip, image, gradient, and compositing operations, while
  Core Text supplies text layout.
- SwiftUI also has `Canvas`, but it is a SwiftUI drawing view rather than an
  AppKit or cross-platform object model. Swift Charts supplies conventional
  Apple-platform charts, not a portable workflow or node editor.
- WinUI `Canvas` is an absolute-positioning layout panel. Arbitrary drawing is
  available through Win2D `CanvasControl` or, at the native foundation, through
  Direct2D and DirectWrite.
- WinUI does not ship a general chart or workflow-graph editor corresponding to
  Swift Charts. Windows Workflow Foundation's designer is a specialized WPF
  tool for WF activities, not a general graph surface.

Platform chart controls could be useful optional semantic controls later, but
using one as the framework foundation would produce different application
models, capabilities, interaction behavior, and appearance on each backend.

## Decision

HaskeLUI will provide a distinct portable **drawing surface**. Its content is an
immutable backend-independent `Drawing`, lowered to an internal display list and
executed by a graphics backend. It will not expose `CGContext`, Direct2D,
Win2D, SDL, Metal, or native object handles.

Charts and graph editors are higher-level libraries:

```text
Chart data -> scales, axes, ticks, marks ---------+
                                                  |
Graph model -> layout, routing, spatial index ----+-> Drawing + semantics
                                                       |
                                                       v
                                                DrawingSurface
                                                       |
                           +---------------------------+------------------+
                           |                           |                  |
                    Core Graphics                Direct2D          SDL3 renderer
```

This keeps the drawing algebra small and reusable while allowing chart and
workflow APIs to evolve around their own domain semantics.

### Naming and package boundary

The public control is `DrawingSurface`, not `Canvas`. The latter already means
absolute child layout in Core, AppKit, and WinUI.

The first implementation exposes an opaque `Drawing` through smart
constructors. Its normalized display-list representation and executors remain
internal until at least two graphical backends validate the contract. The
implementation may live in an internal `haskelui-display-list` package, while
the small construction facade is exported through Core. Applications do not
pattern-match on executor commands.

The compiled control IR gains a leaf equivalent to:

```haskell
data DrawingSurfaceSpec = DrawingSurfaceSpec
  { drawingSurfaceKey              :: ElementKey
  , drawingSurfaceFrame            :: Rect
  , drawingSurfaceRevision         :: DrawingRevision
  , drawingSurfaceDrawing          :: Drawing
  , drawingSurfaceIntrinsicMetrics :: IntrinsicMetrics
  , drawingSurfaceAccessibleLabel  :: Text
  , drawingSurfaceInputMode        :: DrawingInputMode
  , drawingSurfaceHitTest          :: DrawingHitTest
  , drawingSurfaceCursor           :: DrawingCursor
  }
```

The first drawing surface is always on-demand. A continuously repainted
immutable value would only draw the same snapshot repeatedly. Continuous and
fixed-step content belongs to the separate `SceneDriver` scheduling contract,
or to a future retained animation model with an explicit time input; it is not
a flag on `DrawingSurface`.

`DrawingMeasure` supplies minimum, ideal, and maximum logical sizes plus an
optional aspect ratio. The surface is one rectangular custom-rendered island,
always clipped to its arranged bounds. Focus and enabled state are explicit;
cursor selection and input capabilities belong to its interaction contract.

An eventual opaque `View model` facade may add element-local state and accepts
callbacks separately from the drawing value:

```haskell
drawingSurface
  :: DrawingSurfaceOptions local
  -> local
  -> (DrawingEnvironment -> local -> DrawingProgram)
  -> (DrawingInput -> local -> DrawingUpdate model local)
  -> View model
```

The runtime retains `local` by `ElementKey`. `DrawingUpdate` returns new local
state, an optional durable `Action model`, and element responses such as
capture/release pointer, request focus, set cursor, scroll, or invalidate a
conservative rectangle. This is the seam for hover, drag previews, autoscroll,
and spatial indexes without forcing every pointer move through the application
model. Durable selection and graph edits still use `Action model`. The exact
surface syntax may reuse the framework's eventual `ElementProperty` and
`StateSource` APIs, but this lifecycle is required before the interactive graph
slice. Callbacks and state are not embedded in the display list.

The current concrete `Control` IR carries a pre-resolved `Drawing`, a separate
semantic hit-test tree, and typed pointer/scroll input. Input is delivered to
the serialized application reducer as `DrawingInputReceived`; high-frequency
movement is coalesced before the reducer drain. This intentionally supports
model-owned graph and chart interaction now without claiming the future
element-local reducer lifecycle.

### Drawing model

`Drawing` is a scoped, compositional picture tree. A valid construction API is
preferred over a public stateful `save`/`restore` command stream:

```haskell
data DrawingNode
  = Group [Drawing]
  | Transformed Affine2 Drawing
  | Clipped Clip Drawing
  | WithOpacity Double Drawing
  | Fill Geometry FillRule Paint
  | Stroke Geometry StrokeStyle Paint
  | DrawText TextLayoutKey Point
```

The internal lowering may flatten this into push/pop display-list operations.
The scoped public form prevents unbalanced graphics state and makes subtree
caching, bounds calculation, validation, and testing easier.

The portable baseline contains:

- Ordered groups using painter's order
- A six-value affine 2D transform
- Rectangular and path clips
- Rectangles, rounded rectangles, ellipses, and arbitrary paths
- Path verbs `move`, `line`, quadratic Bezier, cubic Bezier, and `close`
- Non-zero and even-odd filling
- Stroke width, cap, join, miter limit, dash pattern, and dash offset
- Solid sRGB color plus linear and radial gradients
- Source-over blending and group opacity
- References to text layouts resolved during the measurement prepass

Advanced blend modes, masks, filters, color spaces, and shadows are later
capabilities. They must not silently degrade in ways that change information;
the backend either supports them, uses a documented fallback, or diagnoses the
unsupported request.

Gradient geometry is expressed in the current local coordinate space. Initial
gradients use monotonic stops in `[0, 1]`, pad extension, and sRGB
interpolation. Degenerate paths are valid no-ops where their operation has no
area or length; non-finite geometry, transforms, stops, widths, and opacity are
invalid. A transform only has to be invertible when it is used for input or
hit-testing conversion.

### Coordinates and rasterization

Drawing coordinates reuse the framework's `Dp` logical unit rather than adding
a second unitless geometry family. The current compiled `Rect` fields using
`Double` are transitional. Coordinates have their origin
at the surface's top-left, positive x to the right, and positive y downward.
The native host supplies the logical-to-device transform. An executor must not
apply a Retina or DPI scale a second time, and it must not globally round vector
geometry. It uses the host scale for raster-resource allocation, damage extents,
and explicit snapping helpers for content such as hairlines or selected grid
lines.

Colors are unpremultiplied sRGB values at the portable boundary. Executors may
convert to premultiplied or linear representations internally. Path and stroke
geometry follow the current transform. A screen-space hairline is a helper that
derives an appropriate logical width from scale; it is not encoded as a
backend-specific pixel width.

A surface is cleared to transparent before its root drawing is executed. Its
host determines any opaque background. This permits composition without
embedding window or theme policy in the drawing algebra.

`WithOpacity` has isolated-group semantics: overlapping children are composed
first, then opacity is applied once to the result. Executors must use a native
transparency layer or an offscreen surface rather than multiplying the alpha of
each child. Future group blend modes follow the same isolation rule.

### Text and images

Text remains a measured subsystem rather than raw glyph painting. Drawing uses
a two-stage `DrawingProgram` analogous to native control measurement:

```haskell
data DrawingProgram = DrawingProgram
  { drawingTextRequests :: [TextLayoutRequest]
  , drawingBuild        :: TextLayoutMap -> DrawingOutput
  }

data DrawingOutput = DrawingOutput
  { drawingOutputContent   :: Drawing
  , drawingOutputSemantics :: DrawingSemantics
  }
```

A request has a stable `TextLayoutKey`, text, generic style, width constraint,
alignment, wrapping, and locale/direction hints. Before final drawing lowering,
the runtime asks the text backend to resolve and cache metrics for the current
font and locale environment, then invokes `drawingBuild`. `DrawText` references
that resolved key. This lets chart ticks, collision handling, node bounds, hit
testing, and the parallel semantic tree use actual metrics rather than
discovering them during execution. The headless backend accepts deterministic
reference or test metrics. Exact glyph fallback, final line breaks, and
rasterization may still differ across systems and are covered by bounded
conformance tests.

Images are deliberately outside the first static slice. Before `DrawImage` is
added, the runtime needs a resource protocol defining stable key plus content
generation, loading/registration effects, intrinsic logical size, scale
variants, color profile, failure placeholder, retained-reference lifetime, and
backend recreation after device loss. An eventual display list references only
that stable key and generation; it never decodes files, retains Haskell pointers
in native code, or contains native image handles. Headless validation receives
the same immutable resource snapshot as graphical executors.

### Input, hit testing, and accessibility

Painting is not the interaction model. Backends normalize pointer and scroll
events into surface-local logical coordinates. Core provides a separate
`DrawingHitTest` tree with affine transforms, clips, fill/stroke shapes, stable
region keys, and cursor hints. The runtime resolves the topmost target using
this portable tree rather than asking a native renderer to infer semantics
from pixels.

Graph and chart layers assign stable region identities to nodes, edges, ports,
data marks, or empty space and then produce model actions. Pointer down captures
the resolved target until up/cancellation; captures are removed with the
surface. Motion is coalesced per surface and pointer, and scroll deltas per
surface. Durable selections and graph edits remain application-model state.
Element-local hover/drag state and spatial-index hit-test nodes remain a future
optimization for very large scenes.

Accessibility is a parallel tree, not a flat list. Each node has identity unique
within its surface, ordered children, role, label, value, state, logical bounds,
focus order, and typed action identifiers. Bounds are surface-local results
after domain transforms and clipping. Accessibility actions return through a
`DrawingSemanticAction` event carrying surface, node, and action identities; no
native callback is stored in the compiled IR. The independent semantics
revision allows selection, focus, value, or description updates without
redrawing unchanged pixels. A conventional chart library can therefore expose
data points and summaries, while a workflow editor can expose nodes, ports,
connections, selection, and editing actions.

Focused native editors may be hosted only as explicit, untransformed rectangular
peer islands or portals. They do not automatically participate in arbitrary
drawing transforms, path clips, opacity, or z-order; the application or graph
component synchronizes their rectangular placement and visibility.

### Invalidation and caching

Separate content and semantics revisions let reconciliation avoid comparing
large trees and avoid repainting a semantics-only change. The first executor
invalidates the full surface whenever content revision or a referenced resource
generation changes. Text/font/locale environment generations also invalidate
measurement and the effective drawing snapshot even if the application-supplied
revision is unchanged. Later versions may accept conservative caller damage
hints or compute old/new bounds for keyed subdrawings; a revision alone does not
describe damage. Backends own native command lists/layers, tessellation caches,
text layouts, resource uploads, and device-loss recreation.

Revisions are contractual correctness tokens. Debug/headless builds may store a
fingerprint and diagnose changed content reused under one revision, but release
code need not deep-compare every drawing. The headless backend validates all
numeric values, path structure, gradient stops, stroke settings, resolved text
references, semantic-tree identity, and resource generations before a graphical
executor sees them.

### Backend mappings

#### macOS proof of concept

The AppKit backend creates a flipped custom `NSView` for each retained drawing
surface. The Objective-C view owns a native copy of the normalized display list,
overrides `-drawRect:`, and executes it through Core Graphics; Core Text supplies
display text. Updates replace the native snapshot transactionally and call
`setNeedsDisplay:` or `setNeedsDisplayInRect:`.

AppKit already installs its points-to-backing-pixels transform in the drawing
context. The executor preserves that scale and installs only the canonical
top-left/y-down adapter. Core Text and raw `CGImage` operations receive explicit
orientation transforms so they do not appear inverted in a flipped view. Image,
text, clipping, and scale behavior are covered by executor golden tests.

The existing narrow Objective-C C ABI gains create, update, invalidate, and
destroy operations. Native code never keeps pointers into the Haskell heap.
Core Graphics is the first executor because it maps closely to the portable
baseline and fits the current AppKit bridge. Metal is a later executor if
profiling demonstrates a need; it is not a path or text API by itself.

#### Windows

The production native mapping is Direct2D plus DirectWrite behind a narrow
C++/WinRT or Win32 bridge. A WinUI implementation may initially host Win2D's
`CanvasControl`, which packages DPI, device-loss, and XAML surface lifecycle,
but Win2D types do not cross the backend boundary. Swap-chain or animated
controls are reserved for content that actually needs continuous presentation.

#### SDL3

SDL3 supplies windows, input, presentation, triangles, and a cross-platform GPU
API, but its basic render API is not a complete path renderer. The SDL3
executor therefore needs shared curve flattening, fill tessellation, stroke
expansion, clipping, and text/image atlases, or it may use a renderer such as
Skia behind the same display-list contract. The public drawing vocabulary is
not reduced to SDL's line and rectangle operations.

### Delivery sequence

1. Add opaque drawing constructors, internal lowering, pure validation, and
   headless display-list capture/golden tests.
2. Add a static/on-demand `DrawingSurface` leaf to the compiled Core control IR.
3. Implement AppKit surface lifecycle and the Core Graphics executor for solid
   fills, strokes, transforms, clips, and simple text.
4. Add gradients, the text measurement/cache prepass, independent revisions,
   and full-surface invalidation.
5. Add normalized pointer/scroll events, portable hit regions, capture,
   coalescing, cursor updates, and an interactive drawing example. (Complete.)
   Retained element-local reducers and accessibility semantic subtrees remain
   follow-up work.
6. Implement a second executor, preferably Direct2D or SDL3, and only then
   freeze or publish the normalized display-list representation.
7. Define the resource registry/lifetime contract, then add images, resource
   generations, and incremental damage.
8. Build chart scales/axes/marks and graph layout/routing as separate packages
   over `Drawing`.

Every executor runs shared conformance cases for transforms, nested clips, fill
rules, degenerate paths and gradients, stroke caps/joins/dashes, isolated group
opacity, text orientation, scale changes, clearing and invalidation,
accessibility action routing, resource disposal/device loss, and bounded visual
snapshot tolerances.

## Alternatives considered

### Wrap each platform's chart library

Rejected as the common foundation. Swift Charts is useful but Apple- and
SwiftUI-specific, while modern WinUI has no corresponding built-in chart or
workflow editor. Native chart controls may later realize a sufficiently narrow
semantic chart control, but cannot support arbitrary Visual Haskell graph
editing.

### Make graph nodes ordinary native controls in a layout canvas

Rejected for the graph's visual layer. Thousands of transformed controls,
Bezier edges, zooming, clipping, z-order, and animated selection would create
heavy native view trees and inconsistent composition. Explicit native islands
may still be overlaid for focused text editing or other specialized controls.

### Expose an immediate backend callback

Rejected because a callback receiving `CGContext`, Direct2D, or SDL objects
would make application code backend-specific, obstruct headless tests, and
complicate thread, lifetime, and device-loss rules.

### Adopt Skia or Cairo as the public API

Rejected as a public boundary. A shared renderer can reduce executor work,
especially for SDL3, but it adds build, binary-size, and FFI costs and still
does not supply graph interaction, semantics, or accessibility. Skia remains a
valid internal executor if maintaining Core Graphics, Direct2D, and path
tessellation independently becomes uneconomical.

### Use a retained native layer per primitive

Rejected as the baseline. Core Animation and Windows Composition are valuable
for selected cached or independently animated groups, but a native layer per
node, edge, label, and decoration would make the platform compositor the public
scene model and impose significant retained-tree overhead.

## Consequences

- Visual Haskell gains one portable substrate for charts, graphs, timelines,
  minimaps, and other custom visualization.
- The same pure drawing can be captured headlessly and rendered through native
  or portable backends.
- Domain libraries must own scales, graph layout, routing, hit testing, and
  semantic accessibility rather than expecting the graphics backend to infer
  them.
- Backend implementations own nontrivial text, resource, caching, and
  device-loss work.
- Small text-layout and rasterization differences remain possible across native
  executors. Path/layout inputs, painter order, and portable semantics remain
  deterministic.
- The display-list representation stays intentionally unstable until a second
  graphical backend proves it.

## Primary platform references

- [Apple Core Graphics](https://developer.apple.com/documentation/coregraphics)
- [Apple `NSView`](https://developer.apple.com/documentation/appkit/nsview)
- [Apple SwiftUI `Canvas`](https://developer.apple.com/documentation/swiftui/canvas)
- [Apple Swift Charts](https://developer.apple.com/documentation/charts)
- [Microsoft Win2D overview](https://learn.microsoft.com/en-us/windows/apps/develop/win2d/in-a-core-app)
- [Microsoft Win2D `CanvasControl` tutorial](https://learn.microsoft.com/en-us/windows/apps/develop/win2d/quick-start)
- [Microsoft Direct2D overview](https://learn.microsoft.com/en-us/windows/win32/direct2d/direct2d-overview)
- [Microsoft WinUI layout panels](https://learn.microsoft.com/en-us/windows/apps/develop/ui/layout-panels)
- [SDL3 geometry rendering](https://wiki.libsdl.org/SDL3/SDL_RenderGeometry)
- [SDL3 GPU API](https://wiki.libsdl.org/SDL3/CategoryGPU)
