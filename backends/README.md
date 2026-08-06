# HaskeLUI backend organization

Backends realize the platform-independent semantic runtime. Nothing under `packages/haskelui-core` may import a module from this directory.

```text
backends/
  headless/
    haskelui-backend-headless/
  macos/
    haskelui-backend-appkit/
  windows/                    added when its vertical slice begins
    haskelui-backend-windows/
  portable/                   added when its vertical slice begins
    haskelui-backend-sdl3/
```

Each backend is an independently buildable package. Backend internals may depend on the shared runtime, but applications depend only on the umbrella/public API plus the selected runtime launcher.

## Operating-system versions

One operating-system family normally has one backend package. Version differences are handled in layers:

1. Compile against the declared minimum deployment target.
2. Detect runtime capabilities in an `Internal.Capabilities` module.
3. Weak-link newer symbols and guard them with platform availability checks.
4. Keep small native compatibility implementations under `cbits/compat/`.
5. Expose semantic capability flags to the backend; do not expose raw OS-version conditionals to applications.

Version-named source directories such as `macos-13/` and `macos-14/` should be introduced only when compile-time source incompatibility cannot be isolated behind the compatibility layer. Copying the whole backend per OS release is prohibited.

The same rules apply to Windows SDK/Windows App SDK versions and to SDL feature levels.

## Native bridge boundary

Native backends use a narrow, prefixed C ABI:

- Opaque native handles
- Fixed-width numeric types
- Explicit UTF-8 ownership
- Explicit create/update/destroy operations
- Shallow callbacks carrying stable HaskeLUI identities
- No native platform objects in public Haskell types

The macOS backend implements this ABI in Objective-C with ARC. Haskell does not call the Objective-C message runtime directly.
