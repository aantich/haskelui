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

## Design documents

- [Architecture proposal](docs/design/architecture.md)
- [ADR 0001: pure bindings, transactions, and async validation](docs/adr/0001-pure-bindings-transactions-and-async-validation.md)
- [ADR 0002: backend layout and the AppKit C bridge](docs/adr/0002-backend-layout-and-appkit-c-bridge.md)

## License

BSD-3-Clause. See [LICENSE](LICENSE).
