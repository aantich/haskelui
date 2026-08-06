# Property API spike

Status: completed and superseded by the production `UIH.Property` and
`UIH.Binding` modules. This package remains as a compiler-diagnostic and design
history fixture; application code should use `uih-core`.

This is deliberately disposable architecture-testing code. It checks the proposed UIH property surface against GHC 9.10.3 rather than establishing a stable package API.

The spike exercises:

- A total `Property model value` wrapping a van Laarhoven `Lens'`
- Generic overloaded-label lenses such as `#document . #title`
- Stable property identities and identity-preserving composition
- Reified, inspectable assignment and modification actions
- `properties.document.title .= value` using `OverloadedRecordDot`, not `OverloadedRecordUpdate`
- A distinct `setElement` operation that avoids ambiguous model inference
- A distinct `OptionalProperty` with explicit missing-target failure

Run it from the repository root:

```console
stack test
```

## Findings

1. GHC 9.10.3 accepts `property id (#document . #title)` with `generic-lens`.
2. UIH only needs the small van Laarhoven `Lens'` representation and three tiny interpreters (`view`, `set`, and `over`). Pulling the full `lens` package is unnecessary for core interoperability and substantially increases the transitive dependency graph.
3. A generic virtual `HasField` instance can turn `properties.document.title` into a typed path on GHC 9.10.3. Each segment contributes both a generic lens and its type-level field name, so the resulting action reports `document.title` without duplicated strings or Template Haskell.
4. This dot syntax is ordinary `OverloadedRecordDot`; it does not use `OverloadedRecordUpdate` or `RebindableSyntax`.
5. Total properties and partial properties should remain distinct. A partial keyed lookup needs an explicit missing-target result; a total lens cannot represent that honestly.
6. Giving model-free `ElementProperty value` the same overloaded `.=` operation causes ambiguous model inference when an action lacks an enclosing `View model` context. `setElement` is clearer and keeps ownership visible.
7. Invalid dotted fields produce a focused GHC error such as `The type Document does not contain a field named 'unknown'`, pointing at the complete bad path. Error quality is good enough for the default API.

## Provisional recommendation

- UIH core owns or exposes a minimal van Laarhoven-compatible lens type.
- Generic derivation is supplied by `generic-lens`, potentially through a small adapter package if core dependency size becomes important.
- The preferred generated surface is `properties.document.title`, with `property id (#document . #title)` as the explicit constructor and interoperability escape hatch.
- Model properties use `.=`; element properties use `setElement`.
- `OptionalProperty` remains a separate type whose final failure policy needs an ADR.

The intentionally invalid fixture can be checked with:

```console
stack ghc -- -fno-code -ispikes/property-api/src spikes/property-api/diagnostics/UnknownField.hs
```
