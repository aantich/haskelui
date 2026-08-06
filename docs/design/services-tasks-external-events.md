# HaskeLUI services, tasks, and external events

Status: implemented runtime foundation; compatibility migration and
validation specialization remain

Date: 2026-08-06

Audience: HaskeLUI application authors, runtime implementers, backend authors,
and service-package authors

## 1. Decision summary

HaskeLUI now has one generic asynchronous runtime substrate with three distinct
concepts:

- An `ExternalEvent model` is a runtime-delivered, application-typed callback
  that turns the current model into a pure `Transaction model`.
- A task command is finite impure work started explicitly by a transaction. It
  has identity, ownership, cancellation, replacement policy, and one terminal
  outcome.
- A `Service model` is long-lived impure infrastructure with a typed
  command endpoint. It may emit any number of external events and has an
  explicit start, stop, health, and restart lifecycle.

Model-dependent `Subscription model` values are dynamically diffed long-lived
producers. They share the service/event machinery but follow declarative model
lifetime rather than whole-application lifetime.

All backend callbacks, task completions, service events, and subscription
events enter one serialized runtime inbox. Only that inbox may update the model
or ask a backend to reconcile UI. Background threads never mutate the model or
native UI objects.

This substrate is language-neutral. Visual Haskell analysis, filesystem
watching, network clients, timers, and asynchronous validation use it without
adding domain-specific constructors to `HaskeLUI.Core`.

## 2. Why this is needed

The implemented application and transaction envelopes now have:

```haskell
data App model = App
  { appInitialModel   :: model
  , appInitialEffects :: [Effect]
  , appInitialCommands :: [RuntimeCommand model]
  , appServices       :: [Service model]
  , appSubscriptions  :: model -> [Subscription model]
  , appView           :: model -> AppView
  , appHandleEvent    :: UIEvent -> model -> Transaction model
  }

data Transaction model = Transaction
  { transactionAction  :: Action model
  , transactionUndo    :: UndoPolicy
  , transactionEffects :: [Effect]
  , transactionCommands :: [RuntimeCommand model]
  }
```

`UIEvent` and the compatibility `Effect` algebra remain closed sums, and the
compatibility file interpreter still runs synchronously after reconciliation.
The generic runtime is the implemented answer for:

- A restartable compiler worker
- Background file I/O
- Filesystem watches
- Network requests
- Timers and process output
- Asynchronous validation
- Progress streams
- Work that outlives one control callback

Adding every application request to `Effect` and every completion to `UIEvent`
would make Core depend on application domains. Letting arbitrary threads call
the reducer would make ordering, ownership, and backend thread affinity
undefined.

## 3. Goals

The design must provide:

1. A callback-oriented surface consistent with existing HaskeLUI actions,
   bindings, and transactions.
2. Explicitly visible `IO`; no hidden impurity inside `Property` or `Binding`.
3. One serialized path from external work back into the current model.
4. Stable identity for tasks, services, subscriptions, and their owners.
5. Best-effort cancellation plus unconditional stale-result rejection.
6. Automatic cancellation when an owning window or element disappears.
7. Application-defined lifetime scopes for documents, workspaces, and other
   non-visual resources.
8. Deterministic shutdown and no callbacks after runtime disposal.
9. Backpressure and bounded UI-thread work.
10. Headless deterministic tests without real time, processes, or threads.
11. A small backend addition for scheduling inbox drainage on the platform UI
    thread.
12. Typed service commands without a global `Dynamic` event bus.

## 4. Non-goals

This proposal does not:

- Put Haskell compiler concepts in HaskeLUI.
- Make ordinary bindings effectful.
- Promise that cancellation stops arbitrary `IO` immediately.
- Make external effects undoable.
- Permit background code to retain or manipulate native UI peers.
- Require applications to define a top-level MVU message sum.
- Specify distributed services or a network protocol.
- Replace domain revision checks with runtime task generations.

## 5. Design principles

### 5.1 Current-model callbacks, not message adaptation

An external producer does not enqueue a model snapshot or mutate one. It
enqueues a handler that receives the model current at delivery time:

```haskell
data ExternalEvent model -- opaque

data EventDelivery
  = DeliverEvery
  | KeepLatest !EventCoalescingKey

externalEvent
  :: Text
  -> (model -> Transaction model)
  -> ExternalEvent model

latestExternalEvent
  :: EventCoalescingKey
  -> Text
  -> (model -> Transaction model)
  -> ExternalEvent model
```

This preserves the callback ergonomics selected for HaskeLUI. A service package
can accept an application callback such as:

```haskell
AnalysisResult -> EditorModel -> Transaction EditorModel
```

It does not force users to construct and route a large nested message sum.

An external handler may capture stable identifiers, request parameters, and
the revision it represents. It must not capture an old model and later replace
the current model with it.

### 5.2 Runtime identity and domain identity are complementary

The runtime rejects events from replaced tasks, stopped services, disposed
owners, and prior runtime generations. Applications must still reject results
that are semantically obsolete, such as analysis for an earlier
`TextRevision`.

Runtime generation prevents a dead producer from acting. Domain revision
prevents a valid producer's old answer from being displayed as current.

### 5.3 Cancellation is never correctness

Cancellation is a resource optimization. It can race, be ignored by foreign
code, or arrive after completion. Correctness comes from generation, owner, and
domain-revision validation at delivery.

### 5.4 Streams are services, not tasks with many special cases

A task has one terminal result. A compiler worker, file watcher, timer stream,
or process-output stream is a service or subscription. This keeps task state
and cancellation semantics small.

## 6. Public type proposal

The following declarations are illustrative surface types. Exact field names
may change during implementation, but their responsibilities are fixed by this
document.

### 6.1 Keys and scopes

```haskell
newtype TaskKey         = TaskKey Text
newtype ServiceKey      = ServiceKey Text
newtype SubscriptionKey = SubscriptionKey Text
newtype LifetimeKey     = LifetimeKey Text
newtype RuntimeGeneration = RuntimeGeneration Word64

data TaskScope
  = ApplicationScope
  | WindowScope !WindowKey
  | ElementScope !ElementKey
  | LifetimeScope !LifetimeKey
```

Keys are namespaced by convention and have diagnostic renderings. A later
implementation may give them structured namespaces without changing lifetime
semantics.

The runtime automatically knows when window and element scopes disappear from
the realized view. Applications explicitly open and close `LifetimeKey` scopes
for domains such as a document or workspace.

### 6.2 Task start policy

```haskell
data TaskStartPolicy
  = ReplaceRunning
  | KeepRunning
  | RequireIdle
```

- `ReplaceRunning` cancels the old task, advances the key generation, and
  starts the new one.
- `KeepRunning` leaves an existing task active and ignores the new request.
- `RequireIdle` reports a programming diagnostic when the key is active.

Parallel work uses distinct keys. Two current generations under one key would
make stale-result semantics ambiguous and are deliberately unsupported.

### 6.3 Cancellation and outcome

```haskell
data CancellationToken

cancellationRequested :: CancellationToken -> IO Bool
waitForCancellation    :: CancellationToken -> IO ()
throwIfCancelled       :: CancellationToken -> IO ()

data TaskFailure
  = TaskException !ExceptionSummary
  | TaskTimedOut
  | TaskExecutorStopped

data TaskOutcome result
  = TaskSucceeded !result
  | TaskCancelled
  | TaskFailed !TaskFailure
```

`ExceptionSummary` is data safe to retain and display. The runtime does not put
open `SomeException` values in the application model.

Domain failures are ordinary successful results such as `Either DomainError
value`. `TaskFailed` is reserved for execution failure, cancellation, timeout,
or runtime shutdown.

### 6.4 Finite tasks

```haskell
startTask
  :: TaskKey
  -> TaskScope
  -> TaskStartPolicy
  -> Text
  -> (CancellationToken -> IO result)
  -> (TaskOutcome result -> ExternalEvent model)
  -> RuntimeCommand model

cancelTask  :: TaskKey -> RuntimeCommand model
cancelScope :: TaskScope -> RuntimeCommand model
```

`startTaskWith` accepts `TaskOptions`, including an optional timeout in
milliseconds. `startTask` is the no-timeout convenience form built from
`defaultTaskOptions`.

The `IO` boundary is visible in `startTask`. Constructing the command does not
run it. The runtime starts it only after the pure transaction commits.

For example:

```haskell
readDocument :: FilePath -> TextRevision -> RuntimeCommand EditorModel
readDocument path requestedRevision =
  startTask
    (TaskKey ("document.read:" <> Text.pack path))
    (LifetimeScope (documentLifetime path))
    ReplaceRunning
    "Read document"
    (\cancel -> readUtf8File cancel path)
    (\outcome ->
      externalEvent "Document read completed" $ \model ->
        handleDocumentRead path requestedRevision outcome model
    )
```

The callback receives the current model. It compares `requestedRevision` and
other domain evidence before accepting the result.

### 6.5 Long-lived services

A service has a typed command channel and emits already-adapted external
events:

```haskell
data Service model
data ServiceEndpoint command

data ServiceContext model command = ServiceContext
  { receiveCommand       :: IO (Maybe command)
  , serviceEvents        :: ExternalSink model
  , serviceCancellation  :: CancellationToken
  , reportServiceHealth  :: ServiceHealth -> IO ()
  }

data RestartPolicy
  = DoNotRestart
  | RestartOnFailure !BackoffPolicy

data ServiceOptions command = ServiceOptions
  { serviceRestartPolicy   :: !RestartPolicy
  , serviceCommandCapacity :: !Int
  , serviceOverflowPolicy  :: !(OverflowPolicy command)
  }

service
  :: Typeable command
  => ServiceKey
  -> Text
  -> ServiceOptions command
  -> (ServiceContext model command -> IO ())
  -> (Service model, ServiceEndpoint command)

serviceWithStatus
  :: Typeable command
  => ServiceKey
  -> Text
  -> ServiceOptions command
  -> (ServiceStatus -> ExternalEvent model)
  -> (ServiceContext model command -> IO ())
  -> (Service model, ServiceEndpoint command)

sendService
  :: ServiceEndpoint command
  -> command
  -> RuntimeCommand model
```

`service` returns the specification and its only correctly typed endpoint.
The implementation selected a pure endpoint containing a service key plus a
`Typeable`-checked heterogeneous runtime registry. Concrete bounded `TBQueue`
values are created when each service generation starts. Application code never
sends `Dynamic`, and failed casts are not a normal runtime path.

An analysis service can be assembled without a top-level message type:

```haskell
(analysisService, analysis) =
  service
    (ServiceKey "visual-haskell.analysis")
    "Visual Haskell analysis worker"
    analysisServiceOptions
    (runAnalysisService analysisConfiguration onAnalysisEvent)

onAnalysisEvent result =
  externalEvent "Analysis result" (acceptAnalysisResult result)
```

The application's transaction sends a request with:

```haskell
sendService analysis (AnalyzeDocument snapshot)
```

Service implementations may use `typed-process`, STM, sockets, or other IO.
Those choices stay behind the service boundary.

### 6.6 Declarative subscriptions

```haskell
data Subscription model = Subscription
  { subscriptionKey         :: !SubscriptionKey
  , subscriptionFingerprint :: !SubscriptionFingerprint
  , startSubscription       :: ExternalSink model -> IO SubscriptionStop
  }

data ExternalSink model = ExternalSink
  { emitEvery  :: ExternalEvent model -> IO ()
  , emitLatest :: EventCoalescingKey -> ExternalEvent model -> IO ()
  }

type SubscriptionStop = IO ()
```

`appSubscriptions model` returns desired subscriptions after each committed
model update. The runtime diffs by key and fingerprint:

- Same key and fingerprint: retain the producer.
- Same key, new fingerprint: stop the old generation and start a new one.
- Removed key: stop and reject all later events from its old generation.
- New key: start after the model commit.

Filesystem watches, timers, application activation streams, and model-selected
external streams fit this API. An application-wide compiler worker is a static
service; its currently watched workspace folders can be service commands or
subscriptions according to which ownership model proves clearer.

### 6.7 Runtime commands and application declaration

```haskell
data RuntimeCommand model -- opaque through the focused public modules

data Transaction model = Transaction
  { transactionAction      :: !(Action model)
  , transactionUndo        :: !UndoPolicy
  , transactionDescription :: !(Maybe Text)
  , transactionEffects     :: ![Effect]
  , transactionCommands    :: ![RuntimeCommand model]
  }

data App model = App
  { appInitialModel   :: !model
  , appInitialEffects :: ![Effect]
  , appInitialCommands :: ![RuntimeCommand model]
  , appServices       :: ![Service model]
  , appSubscriptions  :: model -> [Subscription model]
  , appView           :: model -> AppView
  , appHandleEvent    :: UIEvent -> model -> Transaction model
  }
```

`RuntimeCommand` has smart constructors for tasks, typed service sends/restart,
task/scope cancellation, and custom lifetimes. The current
`transactionEffects` and `appInitialEffects` remain compatibility fields during
migration, then become platform-command smart constructors or are removed.
Existing applications do not need an immediate all-at-once rewrite.

The public modules should make impurity visible:

```text
HaskeLUI.Core                 Pure model/action interpretation and transaction envelopes
HaskeLUI.Task                 Finite task declarations and outcomes
HaskeLUI.Service              Services, endpoints, and subscriptions
HaskeLUI.Validation.Async     Validation specialization over Task
HaskeLUI.Runtime              Executor implementation and runApp
```

The task and service declarations may contain `IO`, but ordinary `Action`,
`Property`, and `Binding` remain pure. A `Transaction` remains a pure value and
its model action is interpreted purely; it may additionally carry explicit
opaque commands whose `IO` is executed later by the runtime.

## 7. Runtime internals

### 7.1 One serialized inbox

Conceptually the runtime owns:

```haskell
data RuntimeState model = RuntimeState
  { currentModel        :: !model
  , runtimeGeneration   :: !RuntimeGeneration
  , inbox               :: !(TQueue (RuntimeEnvelope model))
  , latestEvents        :: !(Map EventCoalescingKey (RuntimeEnvelope model))
  , activeTasks         :: !(Map TaskKey ActiveTask)
  , activeServices      :: !(Map ServiceKey ActiveService)
  , activeSubscriptions :: !(Map SubscriptionKey ActiveSubscription)
  , openLifetimes       :: !(Set LifetimeKey)
  , drainScheduled      :: !Bool
  , shuttingDown        :: !Bool
  }
```

`RuntimeEnvelope model` records its source identity and generation separately
from the `ExternalEvent model` payload. Producers cannot forge a current
generation. Lossless control and terminal events use the FIFO queue.
Explicitly coalescible progress or snapshot events use `latestEvents`, where a
newer event for the same key replaces the pending one.

Backend callbacks enqueue `UIEvent` envelopes. Tasks, services, and
subscriptions receive sinks that stamp and enqueue external envelopes. No
producer receives the model reference or backend session.

### 7.2 Platform-thread wakeup

`BackendSession` gains a narrow scheduling operation:

```haskell
backendScheduleOnUI :: IO () -> IO ()
```

Enqueueing the first item while no drain is scheduled asks the backend to run a
drain callback on its UI thread. Further enqueues coalesce until drainage.

- AppKit implements this with main-queue or run-loop scheduling.
- A future Windows backend schedules through its dispatcher queue.
- Runtime tests use a deterministic queued scheduler; a reusable public manual
  executor remains follow-up work.

`appHandleEvent`, `applyTransaction`, `appView`, layout resolution, and
`backendRender` therefore all run serially on the platform UI thread.

### 7.3 Drain and render order

A drain performs a bounded micro-batch:

1. Dequeue envelopes up to the configured event-count budget.
2. Reject envelopes with dead sources, old generations, or disposed scopes.
3. Apply accepted handlers sequentially; each sees the model resulting from
   the preceding event.
4. Compute the desired view after each accepted model update, immediately
   invalidate window/element scopes absent from it, and diff subscriptions.
   Retain only the newest desired view for native reconciliation.
5. Interpret that transaction's runtime commands in order. Replacement,
   cancellation, and lifetime invalidation take effect before the next
   envelope. Task/service work may start here, but every completion re-enters
   the inbox and therefore cannot apply inside the current batch.
6. Accumulate compatibility/platform effects in transaction order.
7. Reconcile the final desired view once for the batch.
8. Execute accumulated compatibility/platform effects after reconciliation.
9. Reschedule drainage if work remains.

One native render per micro-batch prevents a burst of compiler diagnostics
from causing a native reconciliation per message while preserving
deterministic model and lifetime order. `appView` may be evaluated more than
once in the batch so automatic element/window ownership remains correct; only
its last value is reconciled.

Platform commands that require newly realized UI execute after reconciliation.
Finite tasks and service sends may begin before it because they cannot access
native peers or the model. External completions always re-enter the inbox and
cannot run reentrantly inside command execution.

`runApp` currently defaults to 128 envelopes. `runAppWith` makes the maximum
configurable, and the runtime clamps it to at least one. A wall-clock budget is
deferred until instrumentation demonstrates a useful portable default.

## 8. Task lifecycle and stale-result rules

Starting `ReplaceRunning` for an active key performs:

1. Mark old generation inactive.
2. Request cancellation of its async thread/token.
3. Allocate the next generation.
4. Start the new task.

When a task finishes, its event is accepted only if:

- The application runtime generation is current.
- The task key still exists.
- The task generation is current.
- Its scope is alive.
- Shutdown has not begun.

The runtime then removes the active task before delivering its terminal event.
The domain callback may perform additional revision checks.

Element and window scopes are derived from the newest desired view. Removal by
one event invalidates the scope before the next envelope in the same batch is
validated. Task startup occurs only after the updated desired view has made its
scope live. It may begin before native reconciliation, but its completion
cannot be processed until a later drain, after the current final view has been
reconciled.

Custom lifetimes use explicit commands:

```haskell
openLifetime  :: LifetimeKey -> RuntimeCommand model
closeLifetime :: LifetimeKey -> RuntimeCommand model
```

Closing a lifetime invalidates and cancels all owned tasks before subsequent
external events are processed.

## 9. Service lifecycle, supervision, and backpressure

Static services start before initial commands and stop after the backend event
loop ends but before backend shutdown completes. A service generation changes
on every restart.

Shutdown first invalidates all producer generations, requests cancellation in
parallel, and waits up to the configurable
`runtimeShutdownGraceMilliseconds`. The default is two seconds. No late event
can update the model even if arbitrary uninterruptible `IO` exceeds that grace
period.

Service exit is classified as:

```haskell
data ServiceExit
  = ServiceStoppedNormally
  | ServiceCancelled
  | ServiceFailed !ExceptionSummary
```

`RestartOnFailure` applies bounded exponential backoff with jitter and a
circuit-breaker threshold. Restart policy never hides permanent failure: the
service reports health through an application-provided external callback, and
the UI can offer Retry, Logs, or Disable.

Each service command channel is bounded. The endpoint declares a
command-overflow policy appropriate to its domain:

- `RejectNewCommand`
- `DropOldestCommand`
- `ReplacePendingCommand commandCoalescingKey`

Sending from a transaction never blocks the UI thread. Applications that must
surface admission failure use `sendServiceWithResult`; ordinary
`sendService` intentionally ignores the admission result.

The UI event/control inbox is lossless and must never block the platform UI
thread. Backpressure is applied before high-volume producers enter it:
service/subscription output explicitly chooses `DeliverEvery` or
`KeepLatest EventCoalescingKey`. Lossless queue depth has warning and emergency
thresholds in the production observability plan; those thresholds are not yet
part of the public runtime. A future emergency policy must fail or stop the
offending external producer rather than dropping native input or terminal
results.

The Visual Haskell analysis endpoint should coalesce pending document commands
by document identity and retain only the newest revision. Its emitted
intermediate analysis/progress events may also use a document-specific
`KeepLatest` key. Diagnostics and terminal request results must not be silently
dropped.

## 10. Failure taxonomy

The generic runtime distinguishes:

- Requested cancellation
- Runtime shutdown
- Timeout
- Thrown synchronous exception
- Async executor failure
- Service process exit, expressed by the service domain

Services retain domain-specific failures such as protocol mismatch, compiler
crash, malformed message, or unsupported GHC version. Those should not be
flattened into generic task exceptions.

Exception handlers must not swallow runtime cancellation exceptions and must
not catch process-wide fatal conditions indiscriminately. Implementation should
use `safe-exceptions`-style semantics or equivalent disciplined masking.

## 11. Platform commands

Native file/folder choosers remain platform services because their realization
belongs to a backend. Their future callback-oriented surface should resemble:

```haskell
requestOpenFiles
  :: OpenFilesOptions
  -> ([FilePath] -> ExternalEvent model)
  -> RuntimeCommand model
```

Portable file reads and writes become ordinary tasks. This separates:

- Platform interaction: native panels and OS services
- Background computation/I/O: generic task executor
- Application policy: callbacks and model transactions

The current first-order `Effect` constructors remain operational until Visual
Haskell and the examples migrate and equivalent headless fixtures exist.

## 12. Async validation integration

`AsyncValidation control` remains a separate control declaration as accepted by
ADR 0001. Internally it uses `startTask` with:

- `ElementScope elementKey`
- A key derived from validation and element identity
- `ReplaceRunning`
- The retained edit revision as domain evidence

Cancellation never appears as invalid input. Execution failure maps to the
validation-specific unavailable/error state. A successful negative response
maps to a binding issue. Authoritative domain validation still occurs in the
operation's own task or service command.

## 13. Testing contract

The implemented suite uses a deterministic queued backend to control inbox
drainage and prove ordering. A reusable public manual executor should
eventually be capable of:

- Recording declared tasks without running their `IO`
- Completing a selected task with success, cancellation, or failure
- Emitting service events and service exits
- Advancing a test clock for timeout/backoff
- Starting and stopping subscriptions deterministically
- Draining exactly one event or one bounded batch
- Inspecting active keys, scopes, generations, and queued commands

Required tests include:

1. External events observe the latest model, not the model at request time.
2. A replaced task can finish but its old generation is rejected.
3. A removed element cancels owned work and rejects racing completion.
4. A closed custom lifetime rejects all later owner events.
5. Task exceptions become data and do not terminate the runtime.
6. Service restart advances generation and rejects old-process output.
7. Bounded queues apply their declared overflow policy.
8. Micro-batches preserve model order and render once.
9. No external event is delivered after shutdown begins.
10. All AppKit model handling and reconciliation remain on the main thread.
11. Headless and AppKit implementations have identical event ordering.
12. Async validation distinguishes negative, unavailable, and cancelled.

The current runtime suite covers items 1, 2, 4, 5, 7, and 8 directly, plus typed
service delivery, service restart, and subscription teardown. Native suites
cover AppKit scheduling/shutdown and parity with existing application flows.
Element-scope races, a public fake clock/executor, and the future
async-validation specialization remain explicit follow-up coverage.

## 14. Implementation sequence

### Phase R1: Serialized inbox

- **Implemented:** runtime envelopes, thread-safe/coalescing inbox,
  `backendScheduleOnUI`, AppKit main-queue wakeup, backend-event routing,
  compatibility effects after final reconciliation, and native shutdown tests.

### Phase R2: External events and finite tasks

- **Implemented:** `ExternalEvent model`, task keys/scopes/policies/outcomes,
  task generations, cooperative cancellation, timeout, automatic window and
  element ownership, and custom lifetime commands.
- **Pending:** reusable public manual executor, migration of portable file
  effects, and `AsyncValidation` integration.

### Phase R3: Static services

- **Implemented:** typed specifications/endpoints, `Typeable`-checked registry,
  bounded reject/drop/coalescing queues, admission results, health/status,
  exponential restart with deterministic jitter/circuit breaker, explicit
  retry, generation rejection, and shutdown.
- **Pending:** first real Visual Haskell GHC worker and reusable fake-service
  harness beyond the runtime integration fixtures.

### Phase R4: Declarative subscriptions and lifetimes

- **Implemented:** subscription diffing by key/fingerprint, generation-safe
  external sinks, teardown, and explicit custom lifetime scopes.
- **Pending:** reusable filesystem-watch and fake-clock/timer fixtures.

### Phase R5: Compatibility cleanup

- Migrate examples and Visual Haskell from first-order file effects.
- Convert platform effects to callback-oriented platform commands.
- Remove obsolete `Effect` and completion `UIEvent` constructors only after
  migration and compatibility documentation.

## 15. Performance expectations

The design adds one queue hop for backend and external events. That cost is
small compared with native reconciliation or compiler work and buys consistent
ordering and reentrancy control.

Performance-sensitive rules are:

- One scheduled drain for a burst, not one platform callback per event.
- Bounded micro-batches to preserve input responsiveness.
- One render per batch.
- Coalesce analysis document updates by identity.
- Never perform task/service work on the UI thread.
- Never hold the runtime-state lock while running application callbacks or IO.
- Measure queue depth, event latency, handler time, render time, active tasks,
  and service restarts.

## 16. Resolved decisions

This proposal resolves the architecture questions as follows:

1. HaskeLUI supports the existing small platform-effect algebra alongside
   extensible typed tasks/services. The future callback-oriented platform
   commands can replace those compatibility constructors without allowing
   application domains to extend `UIEvent` or Core effects.
2. Completion uses current-model callbacks rather than requiring an MVU message
   hierarchy.
3. Tasks are finite; streams use services or subscriptions.
4. Cancellation is best effort; generation and owner checks enforce safety.
5. Static services have application lifetime; subscriptions are diffed from
   model state.
6. Backend, task, service, and subscription events share one serialized inbox.
7. Model updates and native reconciliation occur only on the backend UI thread.
8. Impure declarations live in explicit task/service modules; bindings remain
   pure.

## 17. Follow-up implementation decisions

The first implementation resolves endpoint storage, timeout mechanism, and the
initial deterministic batch limit. These remaining questions do not change the
surface responsibilities:

1. **Production micro-batch time budget.** `runApp` defaults to at most 128
   envelopes and one reconciliation; `runAppWith` makes the count configurable.
   Event count is deterministic, but can
   monopolize the UI when handlers are expensive. Add a time budget only after
   instrumentation establishes an appropriate cross-platform default; tests
   should retain an exact count mode.
2. **Shared timeout scheduler.** Per-task `System.Timeout` threads are simple
   and correct for the expected initial task count. A shared timer wheel is an
   internal optimization if Visual Haskell measurements justify it.
3. **Runtime diagnostics and observability.** `RequireIdle`, duplicate service
   or subscription keys, queue depth, event latency, handler time, render time,
   active task count, and restart count need a structured observer API before
   production profiling. They must not become application-domain events by
   default.
4. **Render coalescing around modal platform requests.** Native panels may start
   nested event loops. Platform commands must execute after reconciliation and
   their callbacks must enqueue normally. AppKit tests must prove that modal
   interaction cannot reenter the reducer.
5. **Automatic document lifetime.** Core cannot assume a document model. Visual
   Haskell will explicitly open and close `LifetimeKey` values first. A future
   document framework may automate that policy without changing tasks.
6. **Reusable deterministic executor.** The runtime tests already use a queued
   backend, but service backoff and task timeout tests still use small real-time
   delays. A public test harness should expose a fake clock, selectable task
   completion, service exit injection, and registry snapshots without exposing
   executor internals in production APIs.
