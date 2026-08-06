# ADR 0001: Pure bindings, edit transactions, and separate async validation

Status: Accepted  
Date: 2026-08-05

Implementation: `UIH.Property` and the pure `UIH.Binding` layer are implemented;
retained edit sessions, async validation, and the undo interpreter remain.

## Context

Editable controls must support direct property assignment, formatted values, invalid drafts, synchronous validation, commit timing, dirty-state updates, undo grouping, and concurrent authoritative updates. Some validation also requires network, file-system, or other asynchronous work.

Putting all of these responsibilities in `Property`, or hiding `IO` inside an apparently pure `Binding`, would blur state ownership and make application behavior difficult to test and inspect.

## Decision

### Pure binding layer

`Property model value` only identifies authoritative model state. `Binding model control` is a pure typed editing protocol. Its hidden authoritative value may differ from the control value.

The following operations remain pure:

- Reading and formatting authoritative values
- Parsing control values
- Synchronous validation
- Capturing an edit baseline
- Reconciling external model changes
- Constructing actions and transactions

`Binding` contains no `IO`.

### Explicit edit transactions

A successful commit produces:

```haskell
data Transaction model = Transaction
  { transactionAction      :: Action model
  , transactionUndo        :: UndoPolicy
  , transactionDescription :: Maybe Text
  }
```

The action is interpreted atomically. The retained runtime adds element identity, scene/document scope, time, and other origin metadata when dispatching the transaction.

The initial undo interpreter will store before/after model snapshots for correctness. It will also record touched `PropertyId` values so later implementations may use patches or inverse actions without changing the public envelope. External effects start only after the pure model transaction commits and are not automatically undoable.

### Pure three-way draft synchronization

At edit start, the runtime captures an opaque typed `DraftBaseline`. Reconciliation compares the original value, local control draft, and current authoritative value.

- A pristine draft refreshes from an externally changed model.
- A local-only change remains local.
- Concurrent local and authoritative changes produce `BindingConflict` under `DetectConcurrentChange`.
- No default silently overwrites both changes.

Live bindings default to `RefreshIfPristine`. Staged bindings default to `DetectConcurrentChange`. IME composition temporarily preserves the native draft.

### Separate asynchronous validation

Asynchronous validation is represented by `AsyncValidation control`, not by `BindingOption`:

```haskell
asyncValidation
  :: ValidationId
  -> (control -> Either BindingIssue request)
  -> (request -> IO response)
  -> (response -> AsyncValidationResult)
  -> [AsyncValidationOption]
  -> AsyncValidation control
```

The `IO` boundary is visible in the type and at the control use site through `validateAsync`.

The runtime associates each request with an element owner and edit revision. It requests cancellation when work becomes obsolete or the element is disposed, and it always rejects stale results even if cancellation races or is unavailable.

Pending validation explicitly selects `BlockCommit`, `OptimisticCommit`, or `AdvisoryOnly`. UI validation is feedback, not the final authority for server uniqueness, authorization, or other domain invariants; authoritative typed events/effects enforce those rules.

### Module boundary

The production package places pure editing in `UIH.Binding`. Impure validation declarations will live in `UIH.Validation.Async`. An umbrella module may re-export both without erasing their type-level distinction.

## Alternatives considered

### Put async validators inside `Binding`

Rejected because an ordinary binding would become implicitly effectful, lifetime and cancellation ownership would be unclear, and pure binding tests would require an executor.

### Validate only at commit through application effects

Rejected as the only mechanism because it gives poor feedback for interactive forms. It remains required for authoritative domain validation.

### Always replace or always preserve drafts

Rejected because replacement loses active work while preservation can silently overwrite newer authoritative state. Three-way comparison distinguishes pristine refresh from a genuine conflict.

### Store only inverse actions for undo

Deferred because arbitrary typed domain events may not be invertible. Initial snapshots establish correct semantics first; touched-property metadata leaves room for later optimization.

## Consequences

- Pure editing logic is deterministic and headless-testable.
- Impurity is visible in API signatures and control declarations.
- Bindable values require equality or an eventual explicit equivalence function for conflict comparison.
- Retained elements must own draft, validation, request revision, and cancellation state.
- The runtime needs a transaction interpreter before undo behavior is complete.
- Async optimistic failure requires explicit presentation and, where necessary, an application-domain response rather than hidden rollback.

## Remaining implementation decisions

Two implementation choices remain, with current direction recorded so they are not merely unspecified:

1. **Task executor and error taxonomy.** We must distinguish a valid negative response from timeout, cancellation, transport failure, and thrown exception. Reusing the general runtime task substrate minimizes machinery; a validation-specific result state still provides control presentation. The current recommendation is a shared cancellable executor plus a validation-specific unavailable/error result, with cancellation never treated as validation failure.
2. **Snapshot retention and coalescing boundaries.** Complete model snapshots are simplest but may retain large structures. Patches are smaller but cannot automatically describe opaque reducers. The current recommendation is snapshot correctness first, measurement before optimization, and coalescing only when undo group, retained element identity, scene/document scope, and uninterrupted interaction all match.
