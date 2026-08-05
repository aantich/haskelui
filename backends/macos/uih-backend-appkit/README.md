# UIH AppKit backend

This package realizes the initial semantic UIH view through native AppKit objects. It is a vertical architectural slice, not a production backend.

## Layers

```text
UIH.Backend.AppKit
  Haskell reconciliation and normalized event translation

UIH.Backend.AppKit.Internal.FFI
  opaque handles and the C FFI declarations

cbits/include/UIHAppKit.h
  stable prefixed C ABI

cbits/UIHAppKit.m
  ARC-owned NSApplication, NSWindow, controls, menus, targets, and delegates

cbits/compat/
  isolated availability and compatibility helpers
```

Ordinary development builds inherit the toolchain target. macOS 13 is the candidate production floor and has a separate validation build that applies `MACOSX_DEPLOYMENT_TARGET=13.0` across the Stack invocation, runs the native suite, checks project Objective-C/Haskell objects and the final executable with `vtool`, and verifies that representative selected-GHC base/RTS objects do not require a newer system. Runtime execution on a macOS 13 worker is still required before making a production support claim. Newer APIs must be guarded by native availability checks and reflected through `Internal.Capabilities`; application code must not branch on macOS versions directly.

## Run the vertical slice

From the repository root:

```console
stack test
stack exec uih-appkit-vertical
stack exec uih-text-editor
tests/macos/validate-deployment-target.sh 13.0
```

The example starts with two windows. Editing the text field changes shared model state; Save is shared by a native button and Command-S; the inspector is created and destroyed declaratively; closing the edited main window is vetoed until Save runs.

## Current boundary

Implemented:

- AppKit-owned main event loop
- Multiple retained native windows
- Native labels, buttons, and text fields
- Native scrolling multiline text editors
- Native split-view workspace composition with semantic sidebar, content, and inspector pane hosts
- Independently keyed movable workspace item hosts
- Native document tab strip, selected content hosts, tab selection, and close requests
- Shared native workspace status area
- Revision-bound portable text-style layers, scalar-to-UTF-16 range translation, and temporary native presentation attributes
- File-menu commands and key equivalents
- Native multiple-selection text-file Open panel
- Window activation events for focused command routing
- Close-request normalization
- Explicit native create/update/destroy operations
- Runtime macOS capability query
- Stable native accessibility identities and roles
- Explicit native key-view ordering
- Deterministic native interaction test mode
- Backend-owned resource and queued-callback counters
- Reproducible macOS 13-targeted build and Mach-O inspection

Still required before production use:

- Out-of-process accessibility and IME contracts
- DPI/multi-monitor frame policy
- Execution of the target-built suite on the oldest supported macOS release
- `.app` bundle, signing, resources, and entitlements
- A broader semantic control IR derived from more than one backend
