# Portable layout system

Status: Implemented vertical slice  
Date: 2026-08-06  
Scope: Core layout vocabulary, deterministic solver, control integration, and AppKit realization

## 1. Contract

HaskeLUI layout is a pure, backend-neutral constraint system. A parent proposes
constraints, a child reports a legal measured size and optional baselines, and
the parent assigns a final rectangle. The result is a `LayoutPlan key` containing
stable-keyed frames, visibility, paint order, and diagnostics.

The solver never calls AppKit, WinUI, SDL, or a renderer. Native backends measure
leaf peers in a separate cached phase and supply those measurements to the pure
solver. This keeps the algorithm deterministic and makes the same layout tree
usable by native controls, custom-rendered elements, and headless tests.

```text
semantic controls + Layout ElementKey
                |
                v
      cached intrinsic measurements
                |
                v
        pure HaskeLUI.Layout solver
                |
                v
 frames + visibility + paint order + diagnostics
                |
       +--------+---------+
       |                  |
       v                  v
 native peer frames   custom renderer
```

Coordinates are device-independent `Dp` values in a top-left coordinate
system. `LayoutEnvironment` carries logical left-to-right/right-to-left
direction and scale. Pixel rounding belongs to the final backend boundary, not
to the solver.

## 2. Public model

`HaskeLUI.Layout` exposes four layers:

1. Geometry and constraints: `Dp`, `Size`, `LayoutRect`, `Limit`, and
   `Constraints`.
2. Measurement: `MeasureMode`, `Measurement`, `IntrinsicMetrics`, and
   `Measurer key`.
3. Typed layout specifications: box, flow, wrap, grid, overlay, canvas, split,
   and adaptive.
4. Results and diagnostics: `LayoutPlan key`, `LayoutDiagnostic key`,
   `solveLayout`, `measureLayout`, and `validateLayout`.

The recursive vocabulary is:

```haskell
data Layout key
  = LayoutEmpty
  | LayoutLeaf key
  | LayoutBox BoxSpec (Layout key)
  | LayoutFlow FlowSpec [FlowItem key]
  | LayoutWrap WrapSpec [FlowItem key]
  | LayoutGrid GridSpec [GridItem key]
  | LayoutOverlay OverlaySpec [OverlayItem key]
  | LayoutCanvas CanvasSpec [CanvasItem key]
  | LayoutSplit SplitSpec [SplitItem key]
  | LayoutAdaptive [AdaptiveCase key] (Layout key)
```

Stable leaf keys connect layout nodes to controls without putting backend
objects into Core. Containers are freely nestable; a layout does not care
whether a child is a button, code editor, graph, pane host, or custom-rendered
surface.

## 3. Strategies

### Box

`LayoutBox` supplies logical padding, min/ideal/max bounds, inline/block
alignment, fit/fill aspect ratio, overflow policy, and
visible/invisible/collapsed state. Collapsed content consumes no space;
invisible content is arranged but remains non-visible.

### Flow

`LayoutFlow` is the non-wrapping row/column primitive. Each item has intrinsic
or fixed basis, grow and shrink weights, min/max main-axis limits, and an
optional cross-axis override. Free space is redistributed iteratively so an
item that reaches a bound freezes and the remainder continues to eligible
siblings. Main-axis distribution supports start, center, end, space-between,
space-around, and space-evenly. Cross-axis placement supports start, center,
end, stretch, and baseline.

The axes are logical: `InlineAxis` follows writing direction, while
`BlockAxis` remains top-to-bottom. This lets right-to-left applications mirror
ordinary rows, grids, and anchors without rebuilding their trees.

### Wrap

`LayoutWrap` forms deterministic lines from flow items, then applies the same
per-line flow algorithm. Line gap and line distribution are independent of
item gap and main-axis distribution.

### Grid

`LayoutGrid` has explicit rows and columns with fixed, auto, min-content,
max-content, fit-content, fractional, and nested minmax tracks. Items have
stable integer placement, row/column spans, and per-cell alignment overrides.
Intrinsic single-track contributions are resolved first, spanning deficits are
distributed next, and remaining space is assigned to fractional tracks under
their bounds.

A grid arranges cells but does not paint them. Cell backgrounds, outlines, and
rules are presentation, so tables compose them explicitly from ordinary
children. The conformance gallery's lined-table fixture uses one-point
separator tracks around four content columns and five rows. This keeps plain
grids visually neutral while allowing table packages to offer reusable border,
header, zebra-striping, and selection policies without changing the solver.

### Overlay

`LayoutOverlay` places arbitrary children against logical parent anchors:
start/center/end/stretch independently on each axis, plus logical insets and
physical offsets. Source order is paint order. It is suitable for badges,
anchored decoration, and layered surfaces; semantic popovers remain dedicated
presentation controls.

### Canvas

`LayoutCanvas` is the explicit-positioning escape hatch. Children have x/y,
optional width/height, and z-index. Its natural content size can be inferred or
declared. It is appropriate for diagrams and other coordinate-based content,
not ordinary application forms.

### Split

`LayoutSplit` allocates an axis among children with minimum, preferred,
maximum, and stretch values plus divider extents. It provides the pure sizing
policy used below interactive pane/workspace state; pointer tracking and
committed splitter state remain specialized runtime behavior.

### Adaptive

`LayoutAdaptive` selects the first case whose inclusive inline-width range
matches, or a fallback. Alternative branches may reuse the same stable leaf
keys because only one branch is active. This permits a retained control to
move between compact and wide compositions without reconstruction.

## 4. Semantic container integration

Core connects the solver to controls with `LayoutContainerSpec`:

```haskell
data LayoutContainerSpec = LayoutContainerSpec
  { layoutContainerKey          :: ElementKey
  , layoutContainerFrame        :: Rect
  , layoutContainerPresentation :: LayoutContainerPresentation
  , layoutContainerEnvironment  :: LayoutEnvironment
  , layoutContainerLayout       :: Layout ElementKey
  , layoutContainerChildren     :: [Control]
  }
```

The presentation is independent of arrangement:

- `PlainLayoutContainer`
- `ScrollLayoutContainer Axis`
- `GroupLayoutContainer Text`
- `DisclosureLayoutContainer Text Bool`

This distinction is deliberate. Flow/grid/overlay determine child geometry;
scroll/group/disclosure determine native hosting, clipping, scrolling,
labelling, and accessibility semantics. Any child control can be placed inside
any layout strategy.

`resolveControlLayouts` and `resolveAppViewLayoutsWith` recursively solve
containers and write the resulting frames back into ephemeral control
descriptions. They validate that every referenced leaf exists, every direct
child is represented, keys are unambiguous in an active branch, and numeric
inputs are legal. Inactive adaptive children receive zero frames rather than
retaining stale geometry.

The runtime resolves layout before both initial realization and later backend
reconciliation.

## 5. Native realization

The AppKit backend follows a four-stage cycle:

1. Reconcile semantic native peers without replacing retained controls.
2. Measure only leaves referenced by portable layout trees, using `fittingSize`
   and text-specific constrained measurement where needed.
3. Run the pure Core solver with cached `IntrinsicMetrics`.
4. Commit only changed portable leaf frames, then parent them into native
   layout hosts.

Portable AppKit hosts use flipped top-left coordinates. Plain, scroll, group,
and disclosure containers use ordinary native view/scroll/group compositions,
but AppKit does not independently rearrange portable-layout children. Legacy
containers retain their existing backend-managed behavior.

Measurement caches are invalidated by semantic control changes, not by frame
changes. Layout-only reconciliation therefore does not detach first responder,
reset text selection, close popovers, or rebuild a tab page.

## 6. Performance model

Ordinary box, flow, wrap, overlay, canvas, split, and adaptive passes are
linear in their active subtree. Grid is linear for ordinary items plus work
proportional to declared spans; it intentionally avoids a general constraint
solver. Stable-key maps add logarithmic lookup/update factors at integration
boundaries.

The implementation avoids native calls during recursive solving, caches
intrinsic measurements, and computes only when the declarative view is
reconciled. A deterministic 2,500-leaf scale test exercises the solver. Large
lists, tables, trees, and collections continue to use their specialized
virtualized controls rather than materializing thousands of layout leaves.

Future invalidation can cache solved subtrees by constraints, environment,
layout hash, and measurement generation without changing the public types.

## 7. Verification

`packages/haskelui-core/test/LayoutSpec.hs` covers:

- box padding, alignment, bounds, aspect ratio, and visibility;
- every main and cross alignment, baseline alignment, grow/shrink freezing,
  reverse flow, and right-to-left behavior;
- deterministic wrapping;
- every grid track family, spans, gaps, per-cell placement, and a multirow
  table geometry fixture with explicit separator tracks;
- overlay anchors/insets/offsets and canvas position/z-order;
- split bounds and adaptive branch selection;
- malformed layouts and duplicate-key diagnostics;
- Core control-frame integration;
- deterministic fuzzed sizes with finite non-negative output;
- a 2,500-leaf scale fixture.

The AppKit native gallery test additionally asserts real peer hierarchy,
top-left hosting, fixed basis, weighted growth, grid track width, a lined table
with distinct rows and columns, wrapping, and both compact and wide adaptive
arrangements. The gallery's sixth page is a scrollable visual lab containing
native controls for every strategy:

```console
stack exec haskelui-control-gallery -- --layout
```

## 8. Deliberate boundaries

- Workspace pane interaction remains a semantic `PaneTree`; `LayoutSplit`
  supplies sizing, not pane lifecycle or drag events.
- Virtualization remains in collection controls, not in the general layout
  tree.
- Native text measurement can become more sophisticated behind `Measurer`
  without altering layout types.
- Animations and transitions are not part of this implementation.
- Custom user-defined layout algorithms require a future opaque `View`/element
  extension contract; the accepted built-in strategies do not expose internal
  solver state.
