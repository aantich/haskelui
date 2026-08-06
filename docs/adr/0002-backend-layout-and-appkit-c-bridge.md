# ADR 0002: Backend layout and the AppKit C bridge

Status: Accepted  
Date: 2026-08-05

## Context

HaskeLUI needs native and custom backends without allowing SDL, AppKit, WinUI, or foreign object types to shape the public core. Native APIs also evolve across operating-system releases, so repository layout must support capability differences without cloning an entire backend for each version.

The available Haskell Objective-C packages do not provide a sufficiently current, comprehensive AppKit foundation for HaskeLUI's GHC 9.10.3 baseline. Direct Objective-C runtime dispatch from Haskell would also expose ABI, ownership, delegate, and method-signature details to the backend implementation.

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
HaskeLUI semantic values
  -> Haskell AppKit reconciler
  -> narrow prefixed C ABI
  -> Objective-C implementation compiled with ARC
  -> AppKit
```

The C ABI exposes opaque handles, fixed-width identities, fixed-layout geometry, explicit UTF-8 conventions, and create/update/destroy operations. Haskell does not call `objc_msgSend` and shared/public types do not expose native objects.

### Event loop and callbacks

`NSApplication` owns the process main event loop. AppKit operations assert main-thread access. The blocking `NSApplication.run` bridge is imported as a safe FFI call; short nonblocking setters are unsafe FFI calls.

Target/action and delegate objects normalize AppKit callbacks into command, text-change, and close-request events carrying stable HaskeLUI identities. The Objective-C shim schedules these shallow callbacks onto the main queue so Haskell model transition and reconciliation occur after the originating AppKit callback returns.

### Ownership

Objective-C implementation files use ARC. Opaque handles returned to Haskell are retained exactly once and have explicit destroy functions. Reconciliation destroys controls before their windows, clears delegates and targets before release, and does not rely on Haskell finalizers for normal lifetime.

## Vertical-slice evidence

The initial implementation proves:

- Stack/Cabal compile Objective-C `.m` sources directly with ARC.
- AppKit and Foundation framework linkage works under system GHC 9.10.3.
- A bare Haskell executable can start the AppKit event loop.
- Two native windows and retained native label, button, and text-field peers render.
- Menus, key equivalents, runtime capability queries, accessibility identities, explicit focus order, and explicit peer teardown operate behind the C ABI.
- The platform-independent core/runtime and headless backend build without AppKit imports.
- A deterministic native driver exercises dirty-window close veto, text-field delegate delivery, Haskell reconciliation, Command-S through the AppKit menu, focus transfer, and successful final close.
- Shutdown counters prove release of backend-owned windows, controls, target/action objects, window-delegate attachments, and queued callbacks.
- An isolated Stack build with `MACOSX_DEPLOYMENT_TARGET=13.0` produces a final executable plus Objective-C and Haskell objects whose Mach-O load commands report `minos 13.0`; representative objects from the selected GHC 9.10.3 base and threaded RTS archives report the compatible older floor `11.0`.

The target-built native suite also passes on the development host. This remains vertical-slice evidence, not a claim that the executable has been run on macOS 13 hardware or a macOS 13 virtual machine.

## Alternatives considered

### Comprehensive generated AppKit bindings

Rejected for the first implementation because HaskeLUI needs a small semantic adapter, not exposure of the entire object model. Generated bindings would increase ABI and ownership surface without resolving reconciliation policy.

### Direct Objective-C runtime calls from Haskell

Rejected because message signatures, structures, ARC ownership, delegates, and availability are safer when compiled by Clang.

### Swift bridge

Deferred. Swift is appropriate for selected newer platform APIs, but Objective-C provides the smallest stable C-facing boundary for the initial AppKit slice.

### One backend per macOS release

Rejected because it duplicates reconciliation and guarantees drift. Capability and compatibility layers isolate the smaller changing surface.

## Consequences

- HaskeLUI owns a small amount of Objective-C bridge code.
- Native ownership and callback lifetime can be audited locally.
- Backend packages remain independently replaceable.
- Adding a native operation requires coordinated C-header, Objective-C, and Haskell-FFI changes.
- Runtime capability data becomes part of backend diagnostics and conformance testing.

## Follow-up implementation decisions

Each unresolved item has a current direction:

1. **Formal macOS support floor.** This determines which APIs may be strongly linked and how many compatibility paths require testing. Supporting an older release broadens reach but increases test and fallback cost. macOS 13 is now the candidate floor: the repository has a reproducible isolated build, native test, and Mach-O inspection gate that covers project Objective-C, project Haskell, the final link, and compatibility of representative selected-GHC runtime objects. That does not prove execution on macOS 13. The recommendation is to declare macOS 13 production-supported only after the same native suite passes on an actual or virtual macOS 13 CI worker; if that worker cannot be maintained, raise the declared floor rather than publishing an untested compatibility promise.
2. **Application bundle packaging.** The bare executable is sufficient for ABI and event-loop proof but not for icons, entitlements, localization resources, document types, signing, or distribution. Alternatives are an Xcode-owned launcher or a generated `.app` bundle around the Cabal-built binary. The recommendation is to keep compilation in Stack/Cabal and add a deterministic bundle-packaging step once the backend contract stabilizes.
3. **External accessibility, IME, and display-environment conformance.** Stable accessibility IDs and native roles are now asserted in process, but that does not prove the complete out-of-process accessibility tree, input-method composition, screen-scale changes, or multi-monitor frame behavior. Alternatives are only in-process bridge tests, a permissioned macOS Accessibility client, or both. The recommendation is both: keep the deterministic in-process suite fast, then add a signed/bundled test host driven through the Accessibility API plus dedicated IME and scale-transition cases before calling text input and window placement production-ready.
