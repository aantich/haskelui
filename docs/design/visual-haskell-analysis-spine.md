# Visual Haskell analysis spine

Status: native semantic editing and Stack/Cabal project loading implemented

Updated: 2026-11-07

This document describes the implemented boundary between the Visual Haskell
product and compiler-specific workers. Sections 1–9 record the original
foundation and its staged roadmap; section 10 records the feasibility gate.
Section 11 describes the current project-loading implementation and limits.
The [long-term vision](visual-haskell-vision.md) remains broader than this work.

## 1. Dependency direction

```mermaid
flowchart LR
    MODEL["visual-haskell-semantic-model"]
    PROTOCOL["visual-haskell-analysis-protocol"]
    CLIENT["visual-haskell-analysis-client"]
    FAKE["visual-haskell-analysis-fake-worker"]
    VH["Visual Haskell model + typed HaskeLUI service"]
    GHC["Direct GHC 9.10.3 worker"]

    PROTOCOL --> MODEL
    CLIENT --> PROTOCOL
    FAKE --> PROTOCOL
    VH --> CLIENT
    GHC --> PROTOCOL
```

The semantic and protocol packages import neither HaskeLUI nor GHC. Compiler
workers translate private compiler values into this stable domain. The UI
process receives ordinary Haskell values and remains alive if a worker exits.

## 2. Semantic model

`VisualHaskell.Semantic` provides:

- Stable `WorkspaceId`, `SessionId`, `DocumentId`, declaration, diagnostic,
  and type identifiers.
- `DocumentSnapshot`, carrying path, monotonically increasing text revision,
  content hash, complete text, and line-ending policy.
- `AnalysisSnapshot`, carrying the workspace generation, worker session,
  document revision/hash, completeness/freshness, diagnostics, declarations,
  and a normalized type table.
- `RevisionedSourceRange`, which prevents a range from silently escaping the
  document revision that gave it meaning.
- A precomputed `CoordinateIndex` for exact conversion among normalized GHC
  display columns, UTF-8 byte columns, Unicode scalar columns, and UTF-16 code
  units.

All public positions are zero-based. A GHC worker must subtract GHC's
one-based line/column origin before constructing a `GhcColumn` position. Tabs
advance to eight-column display stops. Conversions reject negative positions,
missing lines, columns inside a multi-unit character, mixed coordinate spaces,
stale revisions, and reversed ranges.

The current `contentHash` is stable FNV-1a over UTF-8. It is a cheap stale-data
guard paired with the monotonic revision, not a security primitive or a
content-addressed storage identity.

## 3. Protocol and framing

Every message is a `ProtocolEnvelope payload` with protocol version and
optional request/workspace/session/document correlation plus required workspace
generation. V1 uses explicit hand-written JSON rather than generic-derived
constructor encodings, so Haskell refactoring cannot accidentally change the
wire format.

The transport is:

```text
4-byte unsigned big-endian JSON length | UTF-8 JSON payload
```

The default maximum is 16 MiB. An oversized announced length is rejected
before payload allocation. The negotiated outbound maximum is the smaller of
the client's configured bound and the worker's advertised bound. Stdout is
protocol-only; stderr is delivered as generation-tagged log events.

Handshake negotiation requires protocol-major compatibility and a nonzero
worker frame bound. Known capabilities use typed constructors. Unknown names
round-trip as `UnsupportedCapability`, allowing compatible minor-version
extension without pretending the feature is understood.

## 4. Supervised client API

The process API is intentionally small:

```haskell
startAnalysisClient
  :: WorkerLaunch
  -> ProtocolEnvelope ClientMessage
  -> (AnalysisClientEvent -> IO ())
  -> IO AnalysisClient

sendAnalysisMessage  :: AnalysisClient -> ProtocolEnvelope ClientMessage -> IO ()
restartAnalysisWorker :: AnalysisClient -> IO ()
stopAnalysisClient    :: AnalysisClient -> IO ()
waitAnalysisClient    :: AnalysisClient -> IO ()
```

`WorkerLaunch` declares the executable, arguments, working directory,
environment override, handshake timeout, restart limit, and local frame bound.
`AnalysisClientEvent` reports starting/ready/restarting/stopped lifecycle,
protocol messages, stderr logs, protocol failures, and observed process exits.
Every worker-originated event carries a `WorkerGeneration`.

The callback is the transport-to-application seam. The production adapter
translates each event into a HaskeLUI `ExternalEvent`, so the pure editor model
is changed only by the serialized runtime inbox and on the backend's UI thread.

## 5. Authoritative replay

The client retains desired state, not a transcript:

```text
latest OpenWorkspace and selected component
latest full snapshot for each open DocumentId
latest AnalyzeDocument intent for each open document
```

An update replaces the retained open snapshot; close removes both the snapshot
and analysis intent; opening another workspace clears the preceding set. On
restart, replay is ordered workspace, component, documents, then analysis
intents.

Replay and live sends share an atomic monotonic sequence watermark. Commands
already represented by the replay snapshot are skipped when their queued copy
is later encountered, while commands created after the snapshot are still
sent. Replayed messages clear old request and session identities: a new worker
owns a new session, even though workspace/document identity and revision remain
stable.

The stdout reader, stderr reader, and process watcher start before replay. This
prevents a worker producing responses during a large replay from filling its
stdout pipe while the client is blocked writing snapshots.

## 6. Product service and acceptance

Worker generation is necessary but insufficient for accepting semantic data.
`VisualHaskell.Analysis.Service` supplies the product-owned typed boundary:

```haskell
analysisService
  :: AnalysisConfiguration
  -> (AnalysisServiceEvent -> ExternalEvent model)
  -> (Service model, ServiceEndpoint AnalysisCommand)
```

`AnalysisCommand` describes workspace configuration, component selection,
document upsert/close, analysis, configuration reload, and explicit worker
restart in semantic types. Only this adapter constructs wire envelopes. Its
bounded queue replaces pending snapshots and analysis requests per document.

The Visual Haskell model accepts a result only when all of these still match:

```text
runtime service generation
worker generation
workspace generation
active component/session
document identity
text revision
content hash
```

Cancellation improves efficiency but never establishes correctness. A late
result is harmless because the pure reducer rejects mismatched identity.

Opening another project increments `WorkspaceGeneration` and clears the
selected component and old snapshots. An explicit Open Folder action grants
trust and configures analysis. On restart, trusted mode is restored only when
the workspace `.vihs` preference and user-owned trust registry both agree.
Otherwise the workspace remains text-only until the user invokes the trust
command. Full snapshots for all open Haskell documents remain authoritative in
the worker, while interactive requests are debounced and target the active
document. A component-scoped persistent GHC session uses its retained module
graph to invalidate the changed target and affected dependents.

## 7. Direct GHC 9.10.3 worker

`vh/workers/ghc-9.10` uses `hie-bios` 0.21 to load explicit or implicit
cradles. The repository's checked-in multi-component `hie.yaml` maps source
trees to exact Stack targets, avoiding ambiguous executable `Main` selection.
The worker rejects untrusted workspaces and any compiler other than GHC 9.10.3.

All direct compiler imports are isolated under
`VisualHaskell.Analysis.Ghc910.Compat`. The worker starts one `runGhc` engine
for the selected component, initializes `hie-bios`/GHC once, and keeps the
engine alive until workspace/configuration replacement or process shutdown.
Every analysis sets GHC targets for all open documents and uses `targetContents`
for authoritative in-memory text. A path/revision/hash retains its prior target
timestamp; a changed version receives a new timestamp. This lets GHC reuse its
module graph and parsed/typechecked cache while still invalidating edited
modules and dependents. GHC diagnostics are intercepted by one session-level
log hook whose current capture is switched per request; stdout remains
protocol-only. Top-level declarations and GHC types are translated to stable
semantic DTOs before they cross the process boundary.

The worker serializes analysis within its GHC session and does not yet
advertise in-progress cancellation. That is an explicit current limit, not an
implied guarantee: correctness still comes from acceptance identities.

## 8. Verification

The implemented tests cover:

- Tabs, CRLF, emoji, Unicode, UTF-8 and UTF-16 boundaries, invalid mid-unit
  columns, stale revisions, and JSON snapshot round trips.
- Semantic JSON fixtures, forward-compatible capabilities, bounded frame round
  trips, truncated input, and oversized input before allocation.
- A real fake-worker process that exits once during analysis. The client
  automatically starts the next generation, replays the newest document (not
  an older queued update), receives the expected result, and emits no old
  generation message after the replacement worker is ready.
- Real `hie-bios` discovery of this repository's Stack component through the
  checked-in multi-cradle mapping. This is a post-build check because a Stack
  cradle starts `stack repl`, which must not wait on an enclosing `stack test`
  process that still owns the build lock.
- Two dependent modules whose on-disk types disagree but whose two unsaved
  snapshots typecheck, plus a broken unsaved revision whose GHC diagnostic is
  bound to that exact revision and a corrected revision checked in the same
  live GHC session. The fixture enforces a one-second warm-edit budget.
- The real GHC worker protocol across two revisions, component/session events,
  normalized declarations and types, and a forced child-process crash. The
  replacement generation replays workspace, buffers, and analysis intent,
  creates one replacement session, and then reuses it for the next revision.
- A full Visual Haskell/HaskeLUI runtime fixture that opens a workspace and
  observes a strictly accepted direct-GHC result in the rendered status area.

Run the focused verification from the repository root:

```console
stack test visual-haskell-semantic-model \
  visual-haskell-analysis-protocol \
  visual-haskell-analysis-client \
  visual-haskell-analysis-ghc910 \
  visual-haskell:vh-analysis-service-test --fast --jobs 1

tests/visual-haskell/validate-analysis-self-host.sh
```

## 9. Native semantic editor slices

Implemented diagnostics slice:

1. Present accepted diagnostics as a generic revision-bound colored-underline
   text layer plus a Problems inspector list.
2. Selecting a problem activates the owning tab and sends one keyed,
   revision-bound reveal/select request; normal native caret motion remains
   backend-local.
3. Suppress stale document/revision/hash/freshness/range projections entirely.

Next slice:

1. Surface top-level declarations and normalized signatures in the inspector
   and provide source navigation using the existing stable ranges.
2. Add typed hover and definition-at-position protocol messages with concrete
   GHC fixtures and exact stale-result acceptance tests.
3. Expose discovered components and explicit selection when more than one
   component owns a file.
4. Watch cradle/configuration dependencies and request explicit reloads for
   trusted workspaces.

Cancellation, concurrent scheduling, incremental invalidation, HIE indexing,
and cross-workspace caches remain later performance/indexing work. They should
be added only after profiling the current correct full-snapshot path.

## 10. Project-loading Stage 0

This section records the original feasibility investigation. The production
implementation and its current compatibility boundary are in section 11 below.

Investigation date: 2026-11-06.

The compatibility investigation upgrades the pinned dependency from
`hie-bios-0.18.0` to `hie-bios-0.21.0` and adapts discovery to
`TargetWithContext` / `LoadFileWithContext`. Existing product session routing
is deliberately unchanged. This is a research gate, not a claim that general
Stack/Cabal project loading is implemented in the UI.

### Reproduction

```console
stack test visual-haskell-semantic-model visual-haskell-analysis-protocol \
  visual-haskell-analysis-client visual-haskell-analysis-ghc910 \
  visual-haskell:vh-analysis-service-test visual-haskell:vh-model-test \
  visual-haskell:vh-workspace-persistence-test --fast --jobs 1
tests/visual-haskell/validate-analysis-self-host.sh
tests/visual-haskell/validate-project-loading-stage0.sh
```

The new runner first builds `visual-haskell-project-loading-spike`, then runs
the binary after the enclosing Stack build has released its lock. Optional
`cabal` or `stack` arguments select one half of the investigation. Fixtures are
copied to canonical temporary roots; no probe saves source edits into the
repository or its copied fixture. Explicit cradle, raw-GHC interface and
response-file caches live with the temporary project and are removed when
that probe finishes. The production-engine check still uses its ordinary
hie-bios interface cache; build tools may also populate their normal
dependency and wrapper caches. Each build-tool probe has a five-minute limit.

### Environment and baseline

Investigation environment: macOS aarch64, GHC 9.10.3, Stack 3.11.1,
cabal-install 3.16.1.0, and Stack's GHC-bundled Cabal library 3.12.1.0.
Fixture dependencies are only `base` and the other local package.

Before the dependency upgrade, all five focused suites and the real Stack
self-hosting check passed. Self-hosting measured 16 ms engine startup,
909 ms first analysis and 46 ms warm edit. The two-module fixture measured
1–4 ms warm broken/recovered edits. These are diagnostic samples, not timing
guarantees.

After upgrading to 0.21.0, all seven focused analysis/model/persistence suites
passed, as did the separate real Stack self-hosting check. Self-hosting measured
15 ms startup, 880 ms first analysis and 45 ms warm edit. The added Cabal and
Stack fixtures both passed explicit executable/test selection and the unsaved
cross-package mismatch/recovery proof; Stack used build-info metadata for the
multi-unit proof rather than its flattened repl environment.

The final two-unit probe measured Cabal initial analysis at 375 ms, unsaved
mismatch at 5 ms and recovery at 40 ms. Stack's build-info preparation took
4596 ms, followed by 124 ms initial analysis, 4 ms unsaved mismatch and 35 ms
recovery. These samples include only the tiny fixture, not a project-size or
toolchain compatibility guarantee.

Stage 0's decision is to retain the pinned 0.21.0 upgrade and proceed with
project/context contracts. Cabal can use hie-bios unit environments directly;
Stack needs a distinct per-unit build-metadata adapter for live local-package
dependencies. Neither result makes the current UI component-aware by itself.

### Loading strategy

- Use `hie-bios` for explicit/implicit cradle environments and compiler
  selection. Construct explicit cradles in memory with `getCradleWithConfig`;
  do not write or overwrite a user's `hie.yaml` to select a target.
- Cabal's `LoadUnitsFromCradle` produces separate `-unit @response-file`
  environments. `initSession'` in 0.21 initialises those home units and returns
  targets with their unit identities. `CradleRunConfig.cradleCacheDir` and
  `initSession'` accept explicit IDE-owned cache roots.
- Stack's ordinary single-component environments work, but its multi-component
  `stack repl` environment merges flags/source paths. Merely upgrading hie-bios
  or asking for all components does not provide unit-preserving Stack loading.
- The Stack proof uses Cabal's generated `build-info.json` from the actual
  Stack build. The fixture explicitly enables `--enable-build-info` through
  `configure-options`. It yields real unit IDs, per-component compiler args,
  modules and source files without a second solver or guessed package flags.
  The spike validates the compiler and Cabal-library version before converting
  those environments to GHC response files with `GHC.ResponseFile.escapeArgs`.

Build-info's JSON format is experimental. The proof intentionally targets the
tested Cabal 3.12 schema; a production adapter must validate versions and
availability, handle multiple component kinds, and arrange explicit opt-in or a
semantically equivalent IDE-owned configuration for build-info generation.
It must not silently rewrite Stack configuration. Custom Setup, preprocessors,
plugins and other compiler versions remain outside this small fixture's proof.

### Required follow-up contracts

1. Separate stable package/component IDs from live context/session identities.
2. Represent selected component plus local home-unit dependency closure,
   retaining exact ordered flags, working directories and configuration inputs.
3. Retain returned unit-aware targets. The production worker currently discards
   those targets and guesses new ones without explicit unit IDs; the spike does
   not make that product path multi-unit safe.
4. Keep all response files, generated macros and interface inputs alive for the
   context lifetime. Do not treat a list of temporary argument paths as a
   self-contained, indefinitely cacheable environment.
5. Bind results to component/context, configuration generation and relevant
   dependency-buffer generation as well as the existing revision/session checks.
6. Resolve and prepare in cancellable helper processes after trust; query
   compiler/version before launching the matching analysis worker. hie-bios
   discovery can build dependencies and is not a read-only parser.

The acceptance fixtures deliberately give executable and test components
different CPP definitions, distinct `Main` modules, and one shared source file.
The cross-package proof changes the upstream `Int` to an unsaved `String`,
requires unchanged downstream analysis to fail, then supplies an unsaved
downstream correction in the same GHC session and verifies neither file was
saved. Counting distinct GHC target unit IDs prevents a flattened session from
being mistaken for a valid multi-unit proof.

Primary references:

- [hie-bios changelog](https://github.com/haskell/hie-bios/blob/master/ChangeLog.md)
- [GHC multiple home units and closure invariant](https://downloads.haskell.org/ghc/9.10.3/docs/users_guide/using.html#multiple-home-units)
- [Cabal build-info JSON](https://cabal.readthedocs.io/en/3.12/cabal-commands.html)
- [Stack maintainer discussion of build-info generation](https://github.com/commercialhaskell/stack/issues/6154)

## 11. Production project/context loading

Implemented in November 2026 on the native HaskeLUI editor, without HLS, LSP or
ghcide. Stage 0's prototype build-info opt-in is superseded by the configured
Cabal helper; no `configure-options`, `hie.yaml`, or user project edits are
required.

### Discovery and environment providers

`visual-haskell-projects` is GHC-free and uses `Cabal-syntax`, not handwritten
`.cabal` or project-file parsers. It discovers nearest Stack/Cabal roots and
named configurations, stops at repository boundaries, and exposes stable
profile/package/component identities. More than one possible profile requires
explicit selection. Package inventory includes conditional candidate roots;
these are not mistaken for the finalized analysis environment.

Cabal discovery reads an IDE-owned dry-run plan, including local dependencies,
internal libraries and Custom Setup package nodes. Preparation constructs an
in-memory explicit hie-bios Cabal cradle with the selected local dependency
closure and requests `LoadUnitsFromCradle`. GHC interprets the returned flags
to obtain actual finalized unit roots and directories. Standalone `.cabal`
packages use Cabal's implicit project without creating `cabal.project`.

Stack discovery uses `stack ide packages --cabal-files`, including Hpack output.
Preparation queries the real compiler version/libdir, then uses Stack's repl
initial-build-steps for its actual dependencies, Setup hooks and preprocessing.
The final GHCi launch is replaced with the helper's no-op mode using Stack's
documented `--with-ghc` option: a flattened Stack environment is neither loaded
nor used as analysis metadata. Internal libraries use package-level Stack
preparation targets because Stack does not accept Cabal's `pkg:lib:name`
syntax. The selected analysis unit remains exact.

The helper is compiled with the project's GHC and boot `Cabal` library and reads
`setup-config` using Cabal's APIs. It exports real component unit IDs, compiler
arguments, modules, entry points, finalized source roots and dependency unit
IDs. Version checks currently require GHC 9.10.3/Cabal 3.12.x. Dependency-first
`-unit @response-file` environments preserve the local-library closure. Main
source paths resolve against configured `hs-source-dirs`, not just the package
directory. Interfaces/objects/HIE/stubs go into IDE-owned unit directories so
unsaved analyses cannot contaminate Stack's build products.

### Scheduling, isolation and correctness

The outer worker is an asynchronous coordinator: trust, discovery, preparation,
watch events and newest pending analysis are handled independently of compiler
work. Preparation itself is a separate helper process, including hie-bios's
internal Cabal/Setup invocations, so it has one cancellable process group.
Tool stdout/stderr are drained concurrently with bounded output and a
15-minute operation limit. Cancellation kills the whole tool/compiler process
group. One live child GHC session and two cached prepared contexts are the
initial memory budget. Switching context starts a fresh child/session nonce;
crashes replay the workspace, exact selected environment, latest open buffers
and latest analysis intent.

The compiler retains hie-bios's target order and explicit unit identities.
Buffer overlays use unit-qualified targets with in-memory contents and logical
monotonic timestamps. The same physical shared source can be compiled under
different component CPP/options without mixing snapshots. Local-library
buffers are loaded as home units rather than stale installed interfaces.
Queries and visual composition activate the exact primary unit, restoring
the prior environment after successful or failed checks.

Protocol v2 includes an all-open-input stamp as well as document revision/hash,
component session and worker/workspace generations. Any dependency-buffer edit,
open or close invalidates the UI's dependent semantic snapshots, assistance and
composition. Results computed against older dependency inputs are rejected even
when the requested file itself has not changed.

Native filesystem subscriptions watch project/configuration dependencies,
recursive Cabal imports (including absent files), and closed source inputs.
Atomic replacements are supported; events are deduplicated by content and
generated-source rewrites during preparation do not cause reload loops. Open
buffers remain authoritative. A watch failure is visible with manual Reload as
the fallback. Configuration changes discard prepared contexts and compiler
sessions; buffers are retained.

### Native editor and trust

The sidebar provides profile/component selectors plus Trust, Reload and Cancel;
the Project inspector shows bounded progress and actionable failures. Choices
are stored in `.vihs` v3, including per-file shared-source contexts. v1/v2 files
migrate without granting trust. Opening a folder does not execute tools. Trust
requires a separate per-user canonical-path registry, and can be revoked while
the editor is running. Unsupported compilers/tool failures leave text editing
available. Trust authorizes arbitrary project build/compiler code; it does not
claim to sandbox Custom Setup, preprocessors, plugins or Template Haskell.

### Acceptance and limits

`tests/visual-haskell/validate-project-loading.sh` builds the worker and real
acceptance executable, releases Stack's outer lock, and runs copied fixtures
under Cabal and Stack. It checks unsaved cross-package break/recovery, separate
and shared Main/module contexts, compiler restart replay, in-flight preparation
cancellation/retry,
configuration atomic replacement, dependency close, Hpack, internal libraries,
benchmarks, conditional flags/roots, named configurations, paths with spaces,
Custom Setup-generated source and standalone `.cabal`. The `self-host` argument
loads this repository's actual editor library and model-test component with
their local home-unit closures. Focused model/protocol/client/project/worker,
service/persistence and native AppKit suites complement those end-to-end tests.

Verified on macOS aarch64 with GHC 9.10.3, Stack 3.11.1, cabal-install 3.16.1.0
and Cabal 3.12.1.0: both real-tool matrices, all ten focused/native suites, and
self-hosting pass. The editor library loads seven local home units; its model
test loads eight. A native smoke test loaded the same workspace under Cabal
and Stack through the real trust/profile controls and reached clean typed
analysis. Native regression counters finish with no live windows, controls,
action targets or test failures. The retained legacy self-hosting path also
passes (one observed warm in-memory edit: 63 ms; not a performance guarantee).

Supported compiler compatibility is intentionally explicit: GHC 9.10.3 and the
tested Stack/Cabal metadata boundary above, not every installed compiler. There
is no automatic compiler download or HLS dependency. Windows process/watch
adapters, additional compiler workers, a complete project-wide index, build/run
commands, dependency installation UI and debugging remain separate work.
