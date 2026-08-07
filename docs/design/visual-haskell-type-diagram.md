# Visual Haskell interactive Type Universe

Status: implemented V1

Date: 2026-08-07

## Purpose and invariants

The Types inspector is a native, interactive projection of Visual Haskell's
accepted `TypeUniverse`. It never parses source, stores compiler values, or
creates a second semantic truth. Source remains authoritative and every
navigable visual part retains a stable semantic identity and revision-bound
source range.

The implementation is the independent `visual-haskell-type-diagram` package.
It depends on `visual-haskell-semantic-model` and `haskelui-core`, but not on
GHC, AppKit, the editor model, or I/O.

## Public pipeline

```haskell
projectTypeDiagram
  :: TypeUniverse range
  -> TypeDiagramState
  -> TypeDiagram

layoutTypeDiagram
  :: DiagramMetrics
  -> Rect
  -> TypeDiagram
  -> TypeDiagramState
  -> LaidOutTypeDiagram

renderTypeDiagram
  :: DiagramMetrics
  -> DiagramTheme
  -> Rect
  -> TypeDiagram
  -> TypeDiagramState
  -> TypeDiagramPresentation

handleTypeDiagramInput
  :: DiagramMetrics
  -> TypeDiagramPresentation
  -> DrawingInput
  -> TypeDiagramState
  -> TypeDiagramUpdate
```

`TypeDiagramPresentation` contains the retained `Drawing`, exactly matching
`DrawingHitTest`, bidirectional semantic region maps, layout snapshot,
deterministic drawing revision, cursor, accessible summary, and intrinsic
metrics. A backend needs no Type Universe knowledge.

## Scene vocabulary

- `DiagramNodeId` distinguishes declared entities from compact external type
  references.
- `DiagramAnchor` identifies an entity header, constructor, record field,
  method, or alias RHS.
- `DiagramPart` adds disclosures, edges, and recursive family hulls to the
  selectable/hit-testable vocabulary.
- `DiagramNodeKind` distinguishes ADT, newtype, alias, class, family,
  unresolved, and external-reference cards.
- `DiagramNodeOrigin` distinguishes current document, workspace, package,
  built-in, unknown, and external references.
- `DiagramEdge` preserves reference/alias/constraint/superclass/recursive
  semantics and the originating `TypeId`.

External constructors referenced by structured types are materialized as
compact read-only stubs when no full local entity exists. They can later be
replaced by indexed package entities without changing the scene or renderer
contract.

GHC constructor names are retained with their defining module. Cards render a
short type name as the title and the defining module as their secondary line
(for example, `FilePath` from `GHC.Internal.IO`). A source filename is shown
only after a workspace/package index can prove the module-to-source mapping;
the diagram never guesses a path. Double-click already navigates full entities
with revision-bound source ranges. A compact external stub deliberately has no
navigation result until that resolver promotes it to an indexed entity.

Exact local alias right-hand sides are compacted at the visual projection
boundary. Thus a field whose GHC type is structurally `TraceEvent -> IO ()`
targets the declared `TraceSink` card when `type TraceSink = TraceEvent -> IO
()` is in the same accepted universe. This compaction is not applied while
rendering the alias's own right-hand side, so it cannot create a false
self-reference. Aliases which GHC itself retains, such as `FilePath`, remain
named in the structured type table.

## Layout and interaction

Layout computes strongly connected components, condenses recursion for
dependency ranking, stacks members of each component together, and creates a
family hull for self- or mutually recursive components. Curves leave the exact
row which introduced the reference; self loops route outside the owning card.
Pinned card positions override automatic placement.

Constructor result types do not create dependency edges: `C :: fields -> T`
states which declaration is constructed, not that `T` is stored by itself.
Only constructor arguments, record fields, constraints, aliases, and methods
participate in reference/recursion projection.

All measurements—including widths, row heights, gaps, corner radii, canvas
padding, and zoom bounds—are fields of `DiagramMetrics`. There are no native
backend layout constants.

Ordinary and external cards compute a natural width from their title,
provenance badge, subtitle, and rows, then clamp it between configurable
minimum and maximum widths. Long text is ellipsized inside its allocated rect;
hovering the affected semantic row/header draws a wrapped detail popover above
the retained surface. Separators own a band before row text rather than
sharing its baseline, and the header title/detail use explicit top/bottom
padding.

A top-level `FunctionType` is projected as one composite dependency instead of
one unrelated edge per nested constructor. Its argument/result endpoints reuse
compact reference cards and are connected by a prominent directional arrow.
Curried chains retain their order. When the configured maximum width cannot
hold every endpoint, layout keeps the leading endpoints and final result with
an interactive ellipsis between them; hovering the ellipsis shows the complete
function type. Nested applications such as `IO ()` remain one endpoint.

The product inspector has no maximum extent, uses a 360-point preferred width,
and adds an outer canvas inset. Its default metrics use larger card/canvas
padding with tighter row, node, and rank gaps. Before the first current
semantic snapshot exists, rich mode replaces the empty canvas with a native
activity indicator and the live compiler status; Debug mode remains available
throughout.

`TypeDiagramState` is ordinary pure application state:

- selection and hover
- collapsed entity identities
- pinned node positions
- viewport offset and scale
- active pan/card drag
- monotonic presentation revision

Blank-canvas drag pans; ordinary scroll pans; Command/Control-scroll zooms
around the pointer; card drag pins a position; disclosures collapse cards;
double-click returns an activated semantic part. Visual Haskell resolves that
part against the same universe, rejects obsolete range revisions, converts GHC
coordinates to Unicode-scalar `TextRange`, activates the existing tab, and
issues normal editor navigation.

## Rendering and accessibility

The renderer uses portable fills, strokes, paths, transforms, clips, opacity,
and text. It does not require gradients or backend-specific controls. Origin
is encoded with both a badge and color; relationship kinds use both line style
and text; selection uses an outline. Light and dark palettes are explicit
`DiagramTheme` values.

The Drawing API currently exposes one surface accessibility label rather than
a semantic child tree. Therefore the Types tab retains its selectable,
scrollable Debug mode as the exhaustive textual representation. Rich semantic
drawing accessibility is a future generic HaskeLUI capability, not an
AppKit-only workaround.

## Verification

The package test suite covers structured projection, structured function
nodes/endpoints, defining-module provenance, bounded content-sized cards,
local-alias compaction,
ordinary-result non-recursion, row anchors, external stubs, recursion,
deterministic non-overlapping layout, row containment, edge
routing, drawing and hit-tree validation, semantic hit resolution, light/dark
presentation, deterministic revisions, collapse, activation, pan, zoom, and
source-location recovery. The Visual Haskell model suite additionally verifies
that the live Types tab owns an enabled valid drawing surface, input updates
its retained revision, the inspector has no artificial maximum extent, and a
pending first snapshot presents native progress rather than an empty diagram.
