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

The PoC currently inherits the build toolchain's deployment target. A production minimum must be configured across Objective-C, every Haskell object, the final link, and the selected GHC runtime—not only this package. Newer APIs must be guarded by native availability checks and reflected through `Internal.Capabilities`; application code must not branch on macOS versions directly.

## Run the vertical slice

From the repository root:

```console
stack test
stack exec uih-appkit-vertical
```

The example starts with two windows. Editing the text field changes shared model state; Save is shared by a native button and Command-S; the inspector is created and destroyed declaratively; closing the edited main window is vetoed until Save runs.

## Current boundary

Implemented:

- AppKit-owned main event loop
- Multiple retained native windows
- Native labels, buttons, and text fields
- File-menu commands and key equivalents
- Close-request normalization
- Explicit native create/update/destroy operations
- Runtime macOS capability query

Still required before production use:

- Automated native interaction and focus tests
- IME and accessibility contracts
- Native object and callback leak counters
- DPI/multi-monitor frame policy
- `.app` bundle, signing, resources, and entitlements
- A broader semantic control IR derived from more than one backend
