# HaskeLUI diagnostics and Visual Haskell debug logging

Status: implemented foundation.

## Goals

Diagnostics must cross the same asynchronous boundaries as the application:
native events, pure transactions, effects, tasks, services, subscriptions,
TextMate, compiler-client supervision, and the compiler worker process. They
must remain optional, must not change behavior, and must not leak document
contents by default.

## Producer API

`HaskeLUI.Diagnostics` defines one backend-neutral envelope:

```haskell
data TraceEvent = TraceEvent
  { traceSeverity  :: TraceSeverity
  , traceSubsystem :: Text
  , traceOperation :: Text
  , traceFields    :: [(Text, Text)]
  }

type TraceSink = TraceEvent -> IO ()
```

Producers own stable subsystem/operation names and safe metadata. They do not
choose a file format, timestamp, session identifier, or destination. The
default sink is `noTrace`, so tracing has one predictable branch and no file
or console cost when disabled.

`RuntimeOptions.runtimeTraceSink` supplies the sink to the executor. Runtime
tracing covers startup/shutdown, backend events, external-event acceptance,
transactions and touched properties, renders, effects, task lifecycles,
service queues/restarts/exits, subscription generations, and invalidated late
events. New work expressed through HaskeLUI tasks/services/subscriptions gains
these boundary diagnostics automatically.

Domain services accept the same sink in their configurations. Visual Haskell
currently adds:

- TextMate registry roots/generation/counts, selected theme, commands,
  document revision/hash/size, completion, and failures;
- compiler command identities, workspace trust/generation, document
  revision/hash/size, worker generations, handshakes, protocol events,
  restart/exit state, and worker stderr;
- GHC worker command receipt, workspace opening, analysis timing, document
  identity, and result class.

## Visual Haskell sink and CLI

```console
stack exec vh -- --debug
stack exec vh -- --debug=/tmp/vh.jsonl
stack exec vh -- --debug-log /tmp/vh.jsonl
```

`--debug` creates one timestamped file under the platform per-user Visual
Haskell state directory's `logs` folder and prints the path. Each line is an
independent JSON object containing UTC timestamp, session-relative elapsed
milliseconds, session, monotonic sequence, severity, subsystem, operation, and
a metadata object. Writes are serialized
because the UI thread, services, subscriptions, and worker supervisor can log
concurrently. A compact human-readable copy is also written to stderr. Every
terminal line begins with UTC time, elapsed milliseconds, and sequence, for
example `[2026-08-07T12:34:56.123Z +1842ms #91]`, so delays remain visible even
when only terminal output is shared.

The GHC worker receives its own `--debug` switch only when the parent editor is
in debug mode. Its stderr is already a supervised protocol side channel; the
analysis service converts each line into the same structured session log.
Stdout remains reserved for framed protocol messages.

## Interactive compiler scheduling

Document snapshots are sent to the compiler service as soon as their revision
changes, but interactive analysis requests are debounced for 350 milliseconds
with a replace-running HaskeLUI task. After the user pauses, Visual Haskell
requests one analysis for the active Haskell document rather than enqueueing
one full GHC load for every open Haskell tab. All open Haskell snapshots remain
in the worker workspace, so the selected module is still checked in the
context of its imports and open dependencies.

Switching to a document requests analysis only when its accepted snapshot is
absent or stale. A workspace open or trust transition configures the workspace,
uploads every open Haskell snapshot, and requests the active document once.
This bounds interactive backlog to an already-running stale GHC pass plus the
latest requested revision. The GHC-9.10 worker retains one component-scoped
`runGhc` session, initializes `hie-bios` and GHC once, and assigns a stable
target timestamp to each path/revision/hash. Consequently `LoadAllTargets`
reuses GHC's module graph and parsed/typechecked home modules; only changed
targets and their invalidated dependents are rebuilt. Debug events report
`session=cold|warm` and preserve total analysis timing. Interrupting an
already-running stale load remains a separate efficiency improvement;
acceptance identities continue to provide correctness.

## Privacy and stability rules

- Never log source text, passwords, clipboard contents, or text-field values.
- File operations may log normalized paths and character/entry counts.
- Document operations may log stable identity, revision, content hash, and
  character count.
- UI text-change events log element identity and size, not the value.
- Errors may be logged verbatim because they are the primary debugging
  artifact; future diagnostic export must offer path redaction.
- Operation names are compatibility-facing diagnostic vocabulary. Prefer
  adding fields over renaming operations.
- Logging failures are isolated from application behavior and reported to
  stderr when possible. The current local-file sink is synchronous and
  appropriate for debug mode; a bounded writer service is the production
  follow-up if measurements show meaningful UI-thread cost.

## Rule for future operations

Every new external boundary gets at least a start/result trace with stable
identity and correlation fields. Pure internal helpers do not need logging;
their enclosing transaction already records description and touched
properties. Expensive phases additionally record elapsed time. Any field that
could contain user content must be summarized or explicitly redacted.
