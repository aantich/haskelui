# macOS validation

Run the candidate deployment-floor gate from the repository root:

```console
tests/macos/validate-deployment-target.sh 13.0
```

The script uses an isolated Stack work directory and applies one `MACOSX_DEPLOYMENT_TARGET` value to the whole invocation. It:

1. Builds and runs the AppKit vertical and multi-window text-editor native interaction/resource tests.
2. Uses `vtool` to require that both final executables, the Objective-C bridge object, and representative project Haskell objects have the requested `minos` value.
3. Samples the selected system GHC's threaded RTS and `base` archives and rejects a runtime object whose `minos` is newer than the requested target.
4. Prints the final binary's dynamic system-library and framework dependencies.

This proves consistent build metadata and execution on the current host. It does not emulate the requested macOS release. Before UIH publishes a production support floor, the same target-built native suite must run on that oldest release in a maintained physical, virtual, or CI environment.
