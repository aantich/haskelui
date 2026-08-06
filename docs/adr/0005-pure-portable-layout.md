# ADR 0005: Pure portable layout with native measurement

Status: Accepted  
Date: 2026-08-06

## Context

UIH must arrange the same semantic control tree through AppKit, a future
Windows backend, and custom renderers. Lowering every layout directly to native
constraints would make behavior diverge across backends, while measuring native
controls inside the recursive solver would make Core impure and hard to test.

## Decision

UIH uses the pure `UIH.Layout` constraint solver for portable control geometry.
Backends provide cached `IntrinsicMetrics` for native leaves in a separate
measurement phase and commit the resulting stable-keyed frames. The typed
built-in vocabulary is box, flow, wrap, grid, overlay, canvas, split, and
adaptive layout. Native scroll, group, and disclosure hosting is represented
separately by `LayoutContainerPresentation`.

Coordinates are device-independent and top-left. Inline layout, grid placement,
and logical anchors honor layout direction. Pixel rounding is a backend concern.
Specialized virtualized controls and interactive workspace panes keep their own
semantic behavior while using the same sizing principles.

## Consequences

- Layout results are deterministic and can be exhaustively tested headlessly.
- Native controls and custom-rendered elements compose under one geometry
  model.
- Backends must implement accurate, cached intrinsic measurement and top-left
  frame translation.
- Native platform constraint solvers are not the portable source of truth,
  though a backend may use them internally where it can preserve the contract.
- Reflow is explicit runtime work and can later use subtree invalidation and
  caching without changing the public layout types.

See [the implemented layout contract](../design/layout-system.md).

