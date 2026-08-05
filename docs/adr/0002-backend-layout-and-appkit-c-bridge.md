# ADR 0002: Backend layout and the AppKit C bridge

Status: Accepted  
Date: 2026-08-05

## Context

UIH needs native and custom backends without allowing SDL, AppKit, WinUI, or foreign object types to shape the public core. Native APIs also evolve across operating-system releases, so repository layout must support capability differences without cloning an entire backend for each version.

The available Haskell Objective-C packages do not provide a sufficiently current, comprehensive AppKit foundation for UIH's GHC 9.10.3 baseline. Direct Objective-C runtime dispatch from Haskell would also expose ABI, ownership, delegate, and method-signature details to the backend implementation.

## Decision

### Repository direction

```text
packages/       platform-independent libraries
backends/       independently buildable realization packages
examples/       runnable vertical slices
spikes/         disposable API experiments
```

Examples and backends depend inward on runtime/core. Core never depends on a backend.

### Backend families and OS versions

Each operating-system family normally has one backend package. Version differences are handled in this order:

1. An explicit minimum deployment target
2. Runtime capability detection
3. Weak-linked symbols guarded by native availability checks
4. Small native compatibility implementations under `cbits/compat/`
5. Version-specific source directories only for irreducible compile-time incompatibility

Applications consume semantic capabilities rather than comparing raw OS versions. Whole backends are not copied per OS release.

### AppKit bridge

The AppKit backend uses:

```text
UIH semantic values
  -> Haskell AppKit reconciler
  -> narrow prefixed C ABI
  -> Objective-C implementation compiled with ARC
  -> AppKit
```

The C ABI exposes opaque handles, fixed-width identities, fixed-layout geometry, explicit UTF-8 conventions, and create/update/destroy operations. Haskell does not call `objc_msgSend` and shared/public types do not expose native objects.

### Event loop and callbacks

`NSApplication` owns the process main event loop. AppKit operations assert main-thread access. The blocking `NSApplication.run` bridge is imported as a safe FFI call; short nonblocking setters are unsafe FFI calls.

Target/action and delegate objects normalize AppKit callbacks into command, text-change, and close-request events carrying stable UIH identities. The Objective-C shim schedules these shallow callbacks onto the main queue so Haskell model transition and reconciliation occur after the originating AppKit callback returns.

### Ownership

Objective-C implementation files use ARC. Opaque handles returned to Haskell are retained exactly once and have explicit destroy functions. Reconciliation destroys controls before their windows, clears delegates and targets before release, and does not rely on Haskell finalizers for normal lifetime.

## Vertical-slice evidence

The initial implementation proves:

- Stack/Cabal compile Objective-C `.m` sources directly with ARC.
- AppKit and Foundation framework linkage works under system GHC 9.10.3.
- A bare Haskell executable can start the AppKit event loop.
- Two native windows and retained native label, button, and text-field peers render.
- Menus, key equivalents, runtime capability queries, and explicit peer teardown compile behind the C ABI.
- The platform-independent core/runtime and headless backend build without AppKit imports.

This is vertical-slice evidence, not a production claim. Automated native interaction and lifetime conformance remain required.

## Alternatives considered

### Comprehensive generated AppKit bindings

Rejected for the first implementation because UIH needs a small semantic adapter, not exposure of the entire object model. Generated bindings would increase ABI and ownership surface without resolving reconciliation policy.

### Direct Objective-C runtime calls from Haskell

Rejected because message signatures, structures, ARC ownership, delegates, and availability are safer when compiled by Clang.

### Swift bridge

Deferred. Swift is appropriate for selected newer platform APIs, but Objective-C provides the smallest stable C-facing boundary for the initial AppKit slice.

### One backend per macOS release

Rejected because it duplicates reconciliation and guarantees drift. Capability and compatibility layers isolate the smaller changing surface.

## Consequences

- UIH owns a small amount of Objective-C bridge code.
- Native ownership and callback lifetime can be audited locally.
- Backend packages remain independently replaceable.
- Adding a native operation requires coordinated C-header, Objective-C, and Haskell-FFI changes.
- Runtime capability data becomes part of backend diagnostics and conformance testing.

## Remaining implementation decisions

Each unresolved item has a current direction:

1. **Minimum macOS deployment target.** This determines which APIs may be strongly linked and how many compatibility paths require testing. Supporting an older release broadens reach but increases test and fallback cost. The PoC currently inherits the toolchain target: applying a linker flag only to the AppKit package produced correctly diagnosed mixed-object target warnings because Haskell objects and the GHC runtime were built differently. The recommendation is to evaluate macOS 13 first, but claim it only after one deployment setting is applied across Objective-C compilation, all Haskell compilation, final linking, and CI execution on a compatible machine.
2. **Application bundle packaging.** The bare executable is sufficient for ABI and event-loop proof but not for icons, entitlements, localization resources, document types, signing, or distribution. Alternatives are an Xcode-owned launcher or a generated `.app` bundle around the Cabal-built binary. The recommendation is to keep compilation in Stack/Cabal and add a deterministic bundle-packaging step once the backend contract stabilizes.
3. **Callback conformance automation.** Visual rendering is proven, but menu shortcuts, text editing, close veto, focus traversal, and stale-callback behavior need repeatable tests. The recommendation is a small backend test mode with native object/event counters plus macOS accessibility-driven integration tests, while pure event-to-transaction behavior remains covered headlessly.
4. **Resource conformance.** Explicit destroy paths exist but leak-free teardown has not been measured. The recommendation is bridge-level live counters for windows, controls, targets, and queued callbacks, asserted at shutdown in debug/test builds before expanding the native control set.
