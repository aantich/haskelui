# Public API spike

This package is a compile-only design test for UIH's surface API. Its types have enough representation for smoke tests, but deliberately contain no reconciler, renderer, native objects, or effect interpreter.

The first example is a realistic multiwindow document editor. It exercises:

- Multiple keyed document windows
- A separately managed settings window and confirmation dialog
- Keyed child-component scoping through a model property
- Lens-backed text and checkbox bindings
- Shared commands invoked by buttons, menus, and shortcuts
- Focus-dependent command availability
- Typed save effects and result events
- Close requests that can remove a document or open a confirmation flow
- Application subscriptions
- Direct bindings with validation, dirty-state updates, and coalesced undo
- Formatted bindings whose control value (`Text`) differs from model state (`Int`)
- Element-owned valid and invalid drafts with explicit commit policy

Run from the repository root:

```console
stack test
```

## Findings

1. `App model` with `model -> [Scene model]` expresses multiple document windows, settings, and state-driven dialogs without treating windows as widgets.
2. Stable `WindowKey` and `SceneKey` values are sufficient at the surface; reconciliation and native lifetime stay below the API.
3. Commands should separate global metadata from focused handlers. Save is declared once, invoked identically by the editor button, menu, and shortcut, and handled by the active document focus scope.
4. Focus normally belongs to the retained runtime. Mirroring `focusedDocument` into the application model was unnecessary and made command routing worse, so the final sketch removed it.
5. Dynamic child models need a first-class keyed scope. `scopeAt documentsProperty documentId component` can lift document actions while the key exists and gives the runtime a place to diagnose a late callback after removal.
6. Typed `Effect model input output` and `Event model payload` values make asynchronous save and close-policy flows readable without a global message ADT.
7. `Binding model control` should be a first-class value, not merely a control option. It existentially hides the authoritative model-value type, allowing a `Text` control to edit an `Int` without weakening the model type.
8. `bind property` is the safe default for lossless live assignment. `bindWith` adds validation, semantic writes, related state updates, commit policy, undo policy, and external-update policy without complicating `Property` itself.
9. Invalid or not-yet-committed control values are retained element state. The spike preserves the exact text `"12x"` while preventing it from entering an `Int` model property.
10. A successful write and related updates such as `dirty .= True` are produced as one action batch inside an explicit `Transaction model`, alongside undo policy and an optional description.
11. The binding is the positional value source for a control: `textField (bind property) options`. This avoids competing `value`, callback, and binding options. Callback-only code can construct `controlled currentValue callback`.
12. Binding constructors accept both explicit `Property` values and dotted paths, so ordinary code uses `bind properties.document.title` without `asProperty` noise.
13. Binding and draft reconciliation remain entirely pure. `captureDraftBaseline` and `reconcileDraft` implement three-way comparison and return explicit refresh, preservation, or conflict values.
14. Live bindings default to refreshing pristine drafts; staged bindings default to concurrent-change detection. An explicit policy can preserve a local draft.
15. Async validation is visibly separate: `AsyncValidation control` contains the `IO` request, and `validateAsync` attaches it to a control rather than smuggling it into `Binding`.
16. Async declarations identify requests, debounce them, and state whether pending work blocks commit, permits optimistic commit, or is advisory. The future runtime must add revision checks, cancellation, and stale-result suppression.

## Provisional recommendations

- Keep scenes as desired-state declarations and windows as keyed top-level resources.
- Keep focus in the runtime unless focus itself is durable application data.
- Declare command identity, label, and shortcut globally; register behavior and availability in focused view/window scopes.
- Add a real keyed child-scope abstraction alongside total and optional properties.
- Preserve typed effects and events in the primary action vocabulary.
- Keep `Property` concerned with authoritative state location and keep parsing, drafts, validation, commit, undo, and synchronization in `Binding`.
- Store staged and invalid drafts in retained element state; only a valid commit dispatches a model action.
- Treat `writeWith` as replacement of ordinary property assignment and `alsoWrite` as additional work in the same transaction.
- Keep the ordinary binding pipeline pure and place visibly impure validation in a separate runtime-owned declaration.
- Begin the undo interpreter with before/after model snapshots, while recording touched property identities for diagnostics and later patch optimization.
- Run async validation through an element-owned, revision-tagged cancellable task substrate; ignore every stale result regardless of cancellation outcome.
- Keep server/domain correctness in authoritative typed events and effects, even when async control validation provides earlier feedback.

The package intentionally does not execute effects or async validators, reduce events, reconcile scenes, or lift scoped actions yet. Those are responsibilities of the future headless runtime, not this surface compilation test.
