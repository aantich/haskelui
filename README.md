# HaskeLUI

HaskeLUI is an experimental native Haskell application framework. Applications describe semantic scenes, windows, controls, commands, bindings, and transactions without depending on SDL, AppKit, WinUI, or another backend API.

The repository is currently validating the architecture through small compiled and native vertical slices. It is not yet a usable application library.

For a task-oriented explanation of the implemented application API, including
state management, windows, workspaces, controls, layout, collections, styled
text, effects, project structure, and testing, read the
[HaskeLUI User Guide](docs/USER_GUIDE.md).

## Repository layout

```text
packages/       Platform-independent core and runtime libraries
backends/       Headless, native-platform, and portable rendering backends
vh/             Visual Haskell, the featured native editor product
examples/       Executable architecture and backend examples
spikes/         Disposable compile-time API experiments
docs/design/    Current architecture proposal
docs/adr/       Accepted architecture decisions
```

Backends are isolated from the public core. See [backends/README.md](backends/README.md) for platform and operating-system versioning rules.

## Toolchain

HaskeLUI uses Stack with the installed system GHC 9.10.3 and `base-4.20.2.0`.

```console
stack test
```

The AppKit vertical example is macOS-only:

```console
stack exec haskelui-appkit-vertical
```

It opens two native windows and exercises retained native controls, shared menu/button commands, model-driven updates, declarative window lifetime, and close veto.

Visual Haskell opens multiple UTF-8 files as document tabs in one native split-view workspace. It includes a project tree, central editors, a right inspector, a shared status area, dirty tracking, Command-S, deferred dirty-tab close, pure Haskell syntax highlighting for `.hs` and `.lhs` files, and versioned `.vihs` workspace restoration:

```console
stack exec vh
```

See [the editor V1/V2 contract](vh/README.md).

The Core control gallery declares every portable control in one model-driven
native application. Its six tabs cover content, commands, text/value input,
collections, shell/presentation feedback, arbitrary-child containers, and the
portable layout system:

```console
stack exec haskelui-control-gallery
```

Open the visual layout lab directly with:

```console
stack exec haskelui-control-gallery -- --layout
```

The gallery's model/headless test proves exhaustive catalog coverage and its
deterministic AppKit test exercises representative typed events and resource
release.

The native test deterministically exercises AppKit callbacks, focus, accessibility identity, Command-S routing, close veto, and zero-resource shutdown. The candidate macOS 13 deployment floor has a separate isolated build/test and Mach-O inspection gate:

```console
tests/macos/validate-deployment-target.sh 13.0
```

## Design documents

- [User Guide](docs/USER_GUIDE.md)
- [Architecture proposal](docs/design/architecture.md)
- [Portable Core control catalog](docs/design/core-control-catalog.md)
- [Document/workspace window surface API](docs/design/window-workspace-surface-api.md)
- [Portable layout system](docs/design/layout-system.md)
- [Property and binding API](docs/design/property-binding-api.md)
- [ADR 0001: pure bindings, transactions, and async validation](docs/adr/0001-pure-bindings-transactions-and-async-validation.md)
- [ADR 0002: backend layout and the AppKit C bridge](docs/adr/0002-backend-layout-and-appkit-c-bridge.md)
- [ADR 0003: explicit file effects and the native text-editor slice](docs/adr/0003-file-effects-and-native-text-editor.md)
- [ADR 0004: generic attributed text and presentation layers](docs/adr/0004-generic-text-styles-and-layers.md)
- [ADR 0005: pure portable layout with native measurement](docs/adr/0005-pure-portable-layout.md)

## License

BSD-3-Clause. See [LICENSE](LICENSE).
