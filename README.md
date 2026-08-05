# UIH

UIH is an experimental native Haskell application framework. Applications describe semantic scenes, windows, controls, commands, bindings, and transactions without depending on SDL, AppKit, WinUI, or another backend API.

The repository is currently validating the architecture through small compiled and native vertical slices. It is not yet a usable application library.

## Repository layout

```text
packages/       Platform-independent core and runtime libraries
backends/       Headless, native-platform, and portable rendering backends
examples/       Executable architecture and backend examples
spikes/         Disposable compile-time API experiments
docs/design/    Current architecture proposal
docs/adr/       Accepted architecture decisions
```

Backends are isolated from the public core. See [backends/README.md](backends/README.md) for platform and operating-system versioning rules.

## Toolchain

UIH uses Stack with the installed system GHC 9.10.3 and `base-4.20.2.0`.

```console
stack test
```

The AppKit vertical example is macOS-only:

```console
stack exec uih-appkit-vertical
```

It opens two native windows and exercises retained native controls, shared menu/button commands, model-driven updates, declarative window lifetime, and close veto.

The macOS workspace text editor opens multiple UTF-8 files as document tabs in one native split-view workspace. It includes a left open-documents pane, central editors, a right inspector, a shared status area, dirty tracking, Command-S, deferred dirty-tab close, and pure Haskell syntax highlighting for `.hs` and `.lhs` files:

```console
stack exec uih-text-editor
```

See [the editor V1/V2 contract](examples/text-editor/README.md).

The native test deterministically exercises AppKit callbacks, focus, accessibility identity, Command-S routing, close veto, and zero-resource shutdown. The candidate macOS 13 deployment floor has a separate isolated build/test and Mach-O inspection gate:

```console
tests/macos/validate-deployment-target.sh 13.0
```

## Design documents

- [Architecture proposal](docs/design/architecture.md)
- [Document/workspace window surface API](docs/design/window-workspace-surface-api.md)
- [ADR 0001: pure bindings, transactions, and async validation](docs/adr/0001-pure-bindings-transactions-and-async-validation.md)
- [ADR 0002: backend layout and the AppKit C bridge](docs/adr/0002-backend-layout-and-appkit-c-bridge.md)
- [ADR 0003: explicit file effects and the native text-editor slice](docs/adr/0003-file-effects-and-native-text-editor.md)
- [ADR 0004: generic attributed text and presentation layers](docs/adr/0004-generic-text-styles-and-layers.md)

## License

BSD-3-Clause. See [LICENSE](LICENSE).
