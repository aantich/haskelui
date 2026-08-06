# HaskeLUI TextMate Runtime Design

Status: Proposed; documentation only  
Date: 2026-08-05  
Implementation status: No package, dependency, FFI binding, or executable code exists yet

## 1. Purpose

`haskelui-textmate` will load declarative TextMate grammars and themes at runtime, tokenize edited documents, and convert the result into HaskeLUI's generic revision-bound text presentation layers.

The package belongs outside `haskelui-core`. Core owns portable text ranges, styles, attributed content, and presentation layers. This package will own TextMate-specific manifests, grammar rules, scope stacks, theme selectors, regex execution, line-state caching, and compatibility behavior.

The intended result is broad language highlighting without adding language concepts to the renderer:

```text
VS Code extension or TextMate bundle
        │
        ├── manifest and language associations
        ├── JSON/plist grammar
        └── JSON/plist theme
                │
                ▼
        HaskeLUI TextMate runtime
                │
        scalar-indexed styled spans
                │
                ▼
          HaskeLUI TextLayer
                │
        ┌───────┴────────┐
        ▼                ▼
     AppKit        custom renderer
```

## 2. Goals

- Load TextMate JSON grammars and XML plist grammars at runtime.
- Read declarative language, grammar, injection, embedded-language, and theme contributions from a VS Code extension manifest.
- Execute Oniguruma-compatible regular expressions without JavaScript in the shipping application.
- Produce generic `TextSpan TextStyle` values accepted by the existing `TextEditorSpec` and `TextLayer` APIs.
- Preserve the grammar rule stack between lines.
- Incrementally retokenize after edits and discard results for obsolete document revisions.
- Support nested scopes, cross-grammar includes, injections, and embedded languages in staged compatibility levels.
- Load themes independently from grammars.
- Permit differential testing against Microsoft's `vscode-textmate` implementation without making Node.js part of the runtime.
- Remain independent of AppKit, WinUI, SDL, and any other rendering backend.

## 3. Non-goals

- Executing JavaScript or native code from a VS Code extension.
- Implementing the VS Code extension host.
- Loading arbitrary extension commands, language servers, debuggers, snippets, or settings.
- Reproducing semantic tokens supplied by a language server. Semantic highlighting is a separate layer above TextMate tokenization.
- Providing parsing, type checking, completion, navigation, refactoring, or diagnostics.
- Guaranteeing pixel-identical output with every VS Code release and user configuration.
- Putting TextMate scopes, selectors, or grammar types into `haskelui-core`.

## 4. Compatibility target

The target is practical compatibility with declarative VS Code/TextMate syntax highlighting:

1. The same grammar should produce equivalent character ranges and ordered scope stacks for supported rules.
2. The same `tokenColors` rules should resolve the same foreground and supported font traits.
3. Unsupported contribution points must produce explicit diagnostics rather than being silently executed or misinterpreted.
4. Full-document and incremental tokenization must produce equivalent final spans.

Compatibility is versioned by feature rather than expressed as a blanket claim:

| Level | Required behavior |
|---|---|
| TM1 | JSON grammar, `match`, `begin`/`end`, captures, repository includes, `$self`, `$base` |
| TM2 | plist grammar, `while`, back-references, cross-scope includes, theme selectors |
| TM3 | injection grammars, embedded-language mappings, token-type overrides |
| TM4 | broad differential corpus compatibility and incremental stabilization |

The first useful release should target TM1 plus basic JSON themes. Higher levels should be enabled only after their conformance suites pass.

## 5. Planned package boundary

The directory is expected eventually to become a Stack/Cabal package:

```text
packages/haskelui-textmate/
├── DESIGN.md
├── package.yaml                 # future
├── src/HaskeLUI/TextMate/
│   ├── Extension.hs             # future: manifest and contribution loading
│   ├── Grammar.hs               # future: decoded grammar representation
│   ├── Linker.hs                # future: includes and repository resolution
│   ├── Oniguruma.hs             # future: managed native regex handles
│   ├── Tokenizer.hs             # future: line tokenizer and rule stack
│   ├── Incremental.hs           # future: line cache and edit invalidation
│   ├── Scope.hs                 # future: scope names and stacks
│   ├── Theme.hs                 # future: selector matching and style resolution
│   ├── Provider.hs              # future: language registry
│   └── HaskeLUI.hs                   # future: conversion to TextLayer
├── cbits/                       # future: small prefixed Oniguruma C bridge
└── test/                        # future: fixtures and differential tests
```

`haskelui-core` must not depend on this package. `haskelui-textmate` may depend on `haskelui-core` in its HaskeLUI adapter because the dependency direction remains one-way.

## 6. Data model

The exact constructors are not committed, but the conceptual types are:

```haskell
newtype LanguageId = LanguageId Text
newtype ScopeName = ScopeName Text
newtype GrammarId = GrammarId ScopeName

data LanguageBundle
data CompiledGrammar
data RuleStack
data TextMateTheme

data ScopeSpan = ScopeSpan
  { scopeRange :: TextRange
  , scopeStack :: ScopeStack
  }

newtype ScopeStack = ScopeStack [ScopeName]
```

Grammar, compiled regex, and rule-stack representations should remain opaque. Consumers may inspect scope stacks for diagnostics and theme development, but cannot construct invalid compiled state.

The high-level boundary is expected to resemble:

```haskell
loadLanguageBundle
  :: ExtensionSource
  -> IO (Either BundleError LanguageBundle)

tokenizeSnapshot
  :: CompiledGrammar
  -> TextRevision
  -> Text
  -> IO (Either TokenizeError TokenizedSnapshot)

resolveTheme
  :: TextMateTheme
  -> TokenizedSnapshot
  -> [TextSpan TextStyle]

toTextLayer
  :: TextLayerKey
  -> TokenizedSnapshot
  -> [TextSpan TextStyle]
  -> TextLayer
```

These signatures are design sketches, not an implementation commitment. In particular, incremental tokenization will take an edit description and cache rather than a complete `Text` value alone.

## 7. Inputs and extension discovery

### 7.1 Direct files

The smallest supported source is an explicit grammar path plus a declared root scope. This is useful for tests, application-bundled grammars, and users who do not have VS Code installed.

### 7.2 Extension directories

For a VS Code extension directory, the loader reads only declarative fields from `package.json`:

- `contributes.languages`
- `contributes.grammars`
- `contributes.themes`

Language associations include identifiers, filename extensions, filenames, and first-line patterns. Grammar contributions include root scope, path, injection targets, embedded-language mappings, and token-type mappings.

Paths are resolved relative to the extension root and must not escape that root.

### 7.3 VSIX archives

VSIX support is a later convenience. It is a packaging reader, not an extension installer. Archive paths must be normalized and checked against traversal, absolute paths, symlink escapes, duplicate entries, decompression limits, and unreasonable file counts before extraction or in-memory access.

### 7.4 Registry conflicts

Multiple extensions may claim the same filename extension or scope. Resolution must be deterministic and visible:

1. An explicit application or user choice wins.
2. An application-bundled provider wins over auto-discovered providers.
3. Otherwise the registry reports ambiguity and exposes candidates.

Silently selecting whichever directory was enumerated first would make editor behavior non-reproducible.

## 8. Grammar loading and linking

The loader parses JSON and XML plist into a loss-preserving raw representation. XML parsing must disable external entities and network resolution.

The linker resolves:

- Local repository references such as `#expression`.
- `$self` and `$base`.
- Includes of another root scope.
- Recursive rule graphs without recursively expanding them into an infinite tree.
- Capture rules attached to `match`, `begin`, `end`, and `while` patterns.
- Injection sources at the compatibility level where injections are enabled.

Rules compile into an indexed graph. Includes should become stable rule identifiers rather than repeated copies. Regex compilation is lazy per rule so loading many language bundles does not compile every unused expression at startup.

Diagnostics retain extension path, grammar path, rule location where available, and include chain. A missing included scope is a structured linking error or warning according to whether tokenization can safely continue.

## 9. Oniguruma bridge

TextMate grammars depend on the Oniguruma regular-expression dialect. Replacing it with `regex-tdfa`, PCRE, or a simplified Haskell regex engine would reject valid grammars and subtly change captures, look-arounds, back-references, and Unicode behavior.

The recommended native design is:

- Pin and bundle a reviewed Oniguruma source release for consistent macOS and Windows behavior.
- Expose a small HaskeLUI-prefixed C ABI rather than binding the complete library directly.
- Represent compiled regex and match-region objects as opaque Haskell handles with deterministic finalization.
- Compile with explicit UTF-8 encoding and syntax options matching the TextMate runtime.
- Copy match offsets into Haskell-owned values before releasing native match state.
- Keep regex calls off the UI thread once the background task executor exists.

Native Oniguruma reports byte offsets for UTF-8 input. Each line cache therefore needs a validated boundary index capable of converting UTF-8 byte offsets to HaskeLUI Unicode scalar offsets. The AppKit backend will continue converting HaskeLUI scalar offsets to UTF-16; TextMate-specific units must not leak into Core.

The bridge should expose cancellation checks between regex searches and lines. It cannot reliably interrupt every pathological backtracking operation inside an arbitrary regex, so grammar trust and workload limits remain part of the security model.

## 10. Tokenization model

TextMate tokenization is line-oriented but stateful across lines. Each line records:

```haskell
data TokenizedLine = TokenizedLine
  { incomingStack :: RuleStack
  , scopeSpans    :: [ScopeSpan]
  , outgoingStack :: RuleStack
  }
```

For each search position, the tokenizer evaluates eligible patterns from the active rule stack, selects the next match according to TextMate precedence, emits capture scopes, and pushes or pops frames for `begin`, `end`, and `while` rules. It must guarantee forward progress even for zero-width matches and diagnose invalid rule behavior rather than looping.

Newline treatment must match the compatibility oracle. Lines retain enough terminator information to distinguish final lines, CRLF input, and grammars whose patterns explicitly inspect line endings.

## 11. Incremental editing

The document cache is keyed by grammar identity, document identity, and `TextRevision`. It stores tokenized lines and their incoming/outgoing stacks.

After an edit:

1. Determine the first affected logical line.
2. Restore the incoming stack from the nearest valid preceding cache entry.
3. Retokenize forward.
4. Stop after both the outgoing stack and emitted scopes converge with the previous cache.
5. Publish a `TextLayer` only if the result revision still matches the current document.

Viewport lines should be prioritized once background execution exists, but publishing a partial layer must be explicit so the application can distinguish complete, visible-range, and stale presentations.

Full-document tokenization remains the reference implementation. Every incremental test compares its final result against a fresh full pass.

## 12. Purity and execution

The boundary between pure and impure work remains visible:

Pure operations include:

- Decoding already-loaded JSON values into validated grammar values.
- Linking rule identifiers once regex source strings are known.
- Parsing scope selectors.
- Resolving scope stacks through a loaded theme.
- Converting token spans into HaskeLUI styles and layers.
- Cache invalidation and convergence decisions over immutable results.

Impure operations include:

- Reading extension files or archives.
- Compiling and executing native Oniguruma regex handles.
- Discovering installed extensions.
- Running background tokenization and cancellation.

The package must not use `unsafePerformIO` to present compiled regex execution as a pure highlighter. Initial experiments may run synchronously from an explicit effect, but production editor integration must use the task executor so a grammar cannot block the UI event loop.

## 13. Theme resolution

TextMate tokenization produces nested scope stacks such as:

```text
source.js
meta.function.js
storage.type.function.js
```

A theme rule contains one or more selectors plus partial style properties. Resolution must account for selector specificity and parent scopes. Each style property is selected independently, matching VS Code behavior where a more specific foreground rule need not erase italic supplied by another applicable rule.

Supported output maps naturally to current Core fields:

| Theme value | HaskeLUI value |
|---|---|
| foreground | `textForeground` |
| background | `textBackground` |
| bold | `textFontWeight` |
| italic | `textFontSlant` |
| underline | `textUnderline` |
| strikethrough | `textStrikethrough` |

Editor selection, IME, search results, diagnostics, and other HaskeLUI presentation layers remain independent and may overlay theme output property-by-property.

VS Code workbench colors and semantic-token theme rules are outside the initial TextMate theme contract. They can be modeled later by separate HaskeLUI theme and semantic-token adapters.

## 14. HaskeLUI integration

The text editor owns document revision and language choice. A TextMate service owns loaded bundles, compiled grammars, line caches, and tokenization tasks.

Conceptually:

```text
file opened or language changed
        → request grammar load/selection
        → tokenize document revision
        → resolve selected theme
        → publish syntax TextLayer

text edited
        → increment TextRevision
        → invalidate affected line cache
        → request incremental tokenization
        → ignore completion if revision is stale
        → replace syntax layer if current
```

Syntax remains only one layer. A later semantic-token provider may place a second layer above it, while diagnostics and search can use additional stable keys.

## 15. Errors and diagnostics

Errors are structured by phase:

- Manifest or archive error
- Grammar parse error
- Include/link error
- Regex compile error
- Tokenization error
- Theme parse or selector error
- Resource-limit or cancellation result
- Unsupported feature diagnostic

Applications choose whether an error is displayed in the document, logged, or causes fallback to plain text. A broken grammar must never make the document uneditable.

Diagnostic messages must include source identity and rule context without exposing arbitrary file contents or native pointers.

## 16. Security and trust model

Declarative does not mean harmless. Grammars can contain computationally expensive regexes and archives can contain hostile paths or sizes.

The initial policy should treat grammars as trusted application or user-installed resources while still enforcing:

- No execution of extension JavaScript, binaries, commands, activation events, or install scripts.
- Extension-root path confinement.
- XML external-entity and network access disabled.
- Archive traversal and decompression limits.
- Grammar size, rule count, include depth, capture count, and token count limits.
- Cancellation between lines and match searches.
- Background execution away from the UI thread.
- Clear failure and plain-text fallback.

Supporting arbitrary untrusted downloaded grammars would require stronger isolation, potentially a helper process with memory and time limits. That is not part of the first release.

## 17. Licensing and distribution

The runtime implementation, regex engine, each bundled grammar, each theme, and each extension have independent licenses and notice requirements.

The first release should load user-supplied or application-explicit grammar directories and ship only small test fixtures written for HaskeLUI. A curated built-in grammar collection should be a later, separately reviewed distribution decision with machine-readable provenance, version pins, licenses, and notices.

Loading an extension already present on a user's machine does not by itself authorize HaskeLUI to redistribute that extension.

## 18. Testing strategy

### 18.1 Pure unit tests

- JSON/plist decoding and validation.
- Include and recursive repository linking.
- Scope selector parsing and specificity.
- Per-property theme merging.
- UTF-8 byte to scalar conversion, including non-BMP characters and combining sequences.
- Cache invalidation and convergence.

### 18.2 Grammar feature fixtures

Small grammars isolate `match`, captures, nested `begin`/`end`, `while`, back-references, zero-width matches, `$self`, `$base`, external includes, injections, and embedded languages.

### 18.3 Differential oracle

Development tests invoke a pinned `vscode-textmate` plus `vscode-oniguruma` tool outside the shipping application. Given identical grammar, theme, and input, it records per-line scopes and rule-state behavior. HaskeLUI output is normalized to the same index convention and compared.

The oracle version and fixtures are pinned. It is a test dependency, not a runtime dependency.

### 18.4 Incremental equivalence

For generated edit sequences, incremental output after every edit must equal a clean full-document tokenization at the same revision.

### 18.5 Robustness

- Fuzz grammar and theme decoders.
- Fuzz edit sequences and Unicode boundary conversion.
- Exercise cancellation and stale completions.
- Verify malformed rules fail without infinite loops.
- Run native resource counters for regex and grammar handles.

### 18.6 Performance gates

Measure grammar load, first full tokenization, single-line edit convergence, memory per cached line, and visible-layer construction. Test small, medium, and pathological documents separately so averages do not hide editor stalls.

## 19. Delivery phases

### Phase 0: conformance spike

- Pin the differential oracle.
- Define normalized golden output.
- Select a few permissively licensed fixture grammars.
- Prove Oniguruma byte/scalar conversions on macOS and Windows.

Exit criterion: representative regex and token ranges agree with the oracle.

### Phase 1: TM1 grammar engine

- JSON grammar loading.
- Native Oniguruma bridge.
- `match`, `begin`/`end`, captures, repositories, `$self`, and `$base`.
- Full-document tokenization.
- Scope spans without theming.

Exit criterion: TM1 fixtures and differential tests pass with deterministic resource cleanup.

### Phase 2: manifests, themes, and HaskeLUI adapter

- Extension-directory manifests.
- Language selection by explicit ID and filename.
- JSON `tokenColors` theme loading.
- Theme specificity and per-property merging.
- `TextLayer` output in the existing editor.

Exit criterion: at least JavaScript, Python, JSON, and Haskell fixtures render through AppKit without application-specific lexers.

### Phase 3: incremental service

- Revisioned line cache.
- Edit invalidation and convergence.
- Task execution, cancellation, and stale-result handling.
- Visible-range prioritization.

Exit criterion: generated edits remain equivalent to full passes and large documents do not tokenize on the UI thread.

### Phase 4: compatibility expansion

- XML plist grammars and themes.
- `while`, advanced captures, and cross-scope includes.
- Injections, embedded languages, and token-type mappings.
- Larger real-world differential corpus.

Exit criterion: each advertised compatibility level has a published passing matrix.

### Phase 5: distribution policy

- Optional VSIX reader.
- Curated grammar/theme provenance if desired.
- Packaging, notices, updates, and cache invalidation across grammar versions.

Exit criterion: distribution is reproducible and all shipped resources have reviewed licensing metadata.

## 20. Deferred decisions and recommendations

### 20.1 Native Oniguruma source

Options are a system library, a vendored pinned source release, or Microsoft's WebAssembly binding. System libraries reduce repository weight but are inconsistent or absent across target platforms. The WASM binding offers compatibility but introduces a WASM host and is intentionally scoped to VS Code. A pinned native source release adds build responsibility but gives macOS/Windows parity and native packaging.

Recommendation: vendor a pinned, minimally configured native Oniguruma source after license and security review, behind a small prefixed C ABI.

### 20.2 Bundled versus user-provided grammars

Bundling provides immediate language coverage but creates update, provenance, binary-size, and licensing obligations. User-provided extensions avoid redistribution and allow experimentation but make behavior less reproducible.

Recommendation: start with explicit user/application grammar directories and HaskeLUI-owned fixtures. Design a curated bundle only after the engine is stable and provenance automation exists.

### 20.3 Compatibility versus strict rejection

Permissively ignoring unknown grammar fields loads more files but can silently produce misleading highlighting. Strict rejection makes unsupported behavior obvious but may reject harmless metadata.

Recommendation: preserve unknown fields, warn for unknown behavioral fields, ignore known non-tokenization metadata, and fail only when correct tokenization depends on an unsupported construct.

### 20.4 Theme ownership

The TextMate package could emit semantic scope spans and leave all theme resolution to the application, or it could load themes and emit final HaskeLUI styles. The first is more composable; the second is much easier for applications and necessary for VS Code theme reuse.

Recommendation: expose both boundaries. Scope spans remain inspectable and cacheable; the optional theme module resolves them into portable `TextStyle` spans.

### 20.5 Background execution timing

A synchronous first implementation is simpler, but compiling or running arbitrary grammar regexes in the UI callback risks visible stalls and undermines the framework's pure update boundary.

Recommendation: a tiny conformance spike may call the engine synchronously from a test harness, but the first editor-integrated version should use an explicit tokenization effect/task with revision correlation.

### 20.6 Exact VS Code parity

VS Code combines TextMate scopes, theme customization, semantic tokens, workbench settings, and extension-host behavior. Claiming exact visual parity would therefore extend beyond grammar interpretation.

Recommendation: advertise versioned TextMate grammar/theme compatibility only. Add semantic tokens later as a separate presentation provider layered above TextMate output.

## 21. References

- [VS Code syntax highlighting guide](https://code.visualstudio.com/api/language-extensions/syntax-highlight-guide)
- [VS Code grammar contribution point](https://code.visualstudio.com/api/references/contribution-points#contributes.grammars)
- [Microsoft vscode-textmate](https://github.com/microsoft/vscode-textmate)
- [Microsoft vscode-oniguruma](https://github.com/microsoft/vscode-oniguruma)
- [Oniguruma](https://github.com/kkos/oniguruma)

