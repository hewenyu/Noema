# Noema architecture

Noema is a Chinese input method for macOS 26+ on Apple Silicon (arm64), built from a SwiftPM package with CommandLineTools only. Rationale lives in the [Agent Notes](../.agents/notes/README.md); standing rules live in [AGENTS.md](../AGENTS.md).

## Components

| Component | Role |
|---|---|
| `librime.1.dylib` | Vendored C++ library: Rime with the `lua` and `octagram` plugins, dependencies static; `install_name` `@rpath/librime.1.dylib`. |
| `CRime` | C bridge to `rime_api.h`; `noema_rime_engine_api_available()` checks every member `RimeEngine` calls. |
| `NoemaCore` | Domain types (`KeyEvent`, `TypingEngine`, `SchemaSetID`), the pure v-mode state machine `VModeReducer`, `NoemaPaths`, and `NoemaLog` (never logs user text). |
| `NoemaText` | Text and pinyin normalization; v-mode's offline tools: `CalculatorEvaluator` (`Decimal`, never `NSExpression`), `DateTimeTemplates`, `SymbolPalette`, `SnippetStore`. |
| `NoemaLearning` | `learning.sqlite` (`LearningStore`, system SQLite, WAL), the non-blocking `LearningStoreWriter`, and the `noema_learned.tsv` exporter. Zero networking. |
| `NoemaLexiconAdmin` | `dictionaries.lock.json` validation, verified downloads, safe ZIP extraction, `LexiconInventory`. Agent and `noema-cli` only. |
| `NoemaIPC` | IME ⇄ agent [IPC](#companion-agent-and-ipc). Zero TCC. |
| `NoemaEngine` | `RimeEngine` (see [Typing engine](#typing-engine)), `RimeKeyMapper`, `BootGuard`, `DeployManifest`, `UserDBGuardian`, `SchemaSetSwitcher`, and the read-only `RimeRuntime`. |
| `Resources/rime-default`, `Resources/rime-lua` | The built-in pinyin schema `noema_pinyin` with OpenCC emoji data (`opencc/noema_emoji.*`); `noema_learned.lua`, the learned-phrase translator. |
| `NoemaIMEShell` | Engine-independent IMKit logic: `InputSessionCoordinator` (see [Input method shell](#input-method-shell)), `NSEventKeyBridge`, and the `TextInputClient`, `CandidatePresenting`, and `VModePresenting` seams. Zero TCC. |
| `NoemaUI` | The [candidate panel](#candidate-panel), which also shows [v-mode](#v-mode). Zero TCC. |
| `NoemaAgentCore` | Agent logic without AppKit lifecycle: `AgentServiceCoordinator`, `LaunchAgentController`, `AgentStatusModel`, `LexiconController`, and the SwiftUI `SettingsRootView`. |
| `noema-cli` | Developer command line: `version`, `check-rime`, `install`, `reload`, `repl`, `lexicon list\|verify\|switch`. |
| `noema-rime-deployer` | The only process that runs librime's deployer, into an empty staging directory; writes `build/.noema-deploy-manifest.json` ([header](../Sources/noema-rime-deployer/main.swift)). Ships in `NoemaIME.app`. |
| `NoemaIME` | The process inside `NoemaIME.app`: `NoemaInputController`, `EngineHost` (the one `RimeEngine`, learning, schema switches, the agent connection), and the `IMKServer`. |
| `NoemaAgent` | The menu bar process inside `Noema.app`: status item, settings window, XPC listener. |

Module graph (arrows point at dependencies):

```
NoemaIME ────────────┬─> NoemaUI ─> NoemaIMEShell ───┐
noema-cli ───────────┼─> NoemaEngine ─> CRime ─> librime.1.dylib
noema-rime-deployer ─┘        └─> NoemaLearning ─> NoemaText
NoemaIME, NoemaAgent ─> NoemaIPC ─> NoemaCore <──────┘
NoemaAgent ─> NoemaAgentCore ─> NoemaIPC, NoemaLexiconAdmin ─> NoemaLearning
noema-cli ─> NoemaLexiconAdmin
```

Tests use Swift Testing, one target per library; `CRimeTests` (serialized suite `LibrimeSerializedTests`) holds every test that initializes librime and drives the real engine, deployer, XPC agent, and executables.

## Typing engine

`TypingEngine` is the synchronous, `@MainActor` boundary between the IMKit shell and an engine: `processKey(_:)` returns a `KeyHandlingResult` whose `committedText` and `handled` are independent. `RimeEngine` implements it:

- **Boot** — claim librime, lock the root, arm `BootGuard`, migrate legacy data; off the main actor, prepare `build/`, initialize, run `UserDBGuardian`, open a session; disarm.
- **Deployment** — `build/` is trusted only when `DeployManifest.validated` matches a fresh SHA-256 inventory. `noema-rime-deployer` runs with a timeout in a locked staging directory; the result is re-validated and swapped in with `renamex_np(RENAME_SWAP)`, and any failure leaves `build/` unchanged. Every staged schema patch clears `recognizer/patterns/v` and `v_mode` to `""`; a build whose manifest lacks a required `schemaPatches` ID is redeployed ([`RimeEngine+Deploy.swift`](../Sources/NoemaEngine/RimeEngine+Deploy.swift)).
- **Safe Mode** — any boot failure sets a `SafeModeReason`, releases librime, and answers every key with `handled: false`; `recoverFromSafeMode()` boots again.
- **State** — every call drains `RimeCommit` and rebuilds `CompositionState`; offsets are UTF-16, and `generationID` strictly increases.

Rationale: [process model note](../.agents/notes/proposed/architecture/2026-11-23-process-model-and-permissions.md).

## Schema sets and learning

One root, `~/Library/Application Support/Noema/rime/`, holds the `.noema-rime.lock`, `learning.sqlite`, and `active-schema-set.json`. Each `SchemaSetID` (`builtin`, `wanxiang`, `rime-ice`, `mint`) runs with its own librime `user_data_dir` `sets/<set>/` (`build/`, userdbs, `lua/noema_learned.lua`, `noema_learned.tsv`); downloads extract to `schemas/<set>/`, models to `models/`. `EngineHost` boots the recorded set if installed, falling back once to `builtin`.

- **Learning** — `RimeEngine.recordCommits` queues Han commits to `LearningStoreWriter`, never under secure input; it writes off the main actor and flushes before shutdown and switches. Keys are full pinyin, one syllable per Han character; unverifiable spellings, shape or non-Mandarin schemas, and reverse lookups are never learned.
- **Switch** — `SchemaSetSwitcher` waits for idle, deploys and swaps librime off the main actor, and reports `pendingIdle`, `compiling`, `ready`, or `failed`. `UserDBGuardian` restores a corrupt userdb from a verified snapshot or the store and imports entries past its watermark in the dictionary's spelling; `noema_learned.tsv` is re-exported.
- **Agent** — Settings › 词库 (`LexiconController`) reads the inventory and the store read-only, installs from the bundled lockfile, and sends `switchSchemaSet`.

Rationale: [lexicon note](../.agents/notes/implemented/architecture/2026-11-23-lexicon-canonical-and-userdb-isolation.md).

## Input method shell

Each IMKit `NoemaInputController` forwards every call, with its session token, to the process-wide `InputSessionCoordinator`, which:

- passes every key through, before the engine sees it, while `IsSecureEventInputEnabled()` is true, and hides the panel;
- gives the composition to one token at a time, clearing the old client with `clearComposition()`, never `resetSession()`;
- returns `false` without an engine, in Safe Mode, and in idle ASCII mode;
- inserts `committedText` first, then shows or clears marked text (none for `InlinePreeditDisabledBundleIDs`), and returns `handled`;
- reports every composition change through `onCompositionChange`.

`EngineHost` registers the `IMKServer`, then starts `RimeEngine` and the agent connection after launch; until ready and after `shutdown()`, every key passes through. `noema-cli install` validates a staged bundle and swaps it in atomically ([`InstallCommand.swift`](../Sources/noema-cli/InstallCommand.swift)).

## v-mode

A plain `v` with no composition opens v-mode; once Rime composes, `v` is Rime's (`lv` is 绿). The coordinator feeds keys and panel clicks to `VModeReducer` and applies its effect: marked text and a 2-column menu (`v1`…`v9`) or sub-mode list, a commit, or `quickActionRequested` to the agent. Secure input, Safe Mode, ASCII mode, focus loss, and a click outside end it. Emoji candidates follow matching words through `simplifier@emoji_suggestion`; the agent's `emojiCandidatesEnabled` sets that librime option. Rationale: [v-mode note](../.agents/notes/implemented/feature/2026-11-26-v-mode-offline-tools-and-emoji.md).

## Candidate panel

`CandidatePanelController` implements `CandidatePresenting` and `VModePresenting` with one reused non-activating `NSPanel`. `CaretPositionResolver` places it below the caret, falling back to the client's last valid caret, then the mouse. `CandidateLayoutEngine` lays out with CoreText; `WidthHysteresis` keeps widths on 32 pt tiers that never shrink within a composition. The backdrop is `NSGlassEffectView` or `NSVisualEffectView`. Checks: [smoke checklist](runbooks/smoke-checklist.md). Rationale: [candidate panel note](../.agents/notes/implemented/architecture/2026-11-25-candidate-panel-coretext-glass.md).

## Companion agent and IPC

`Noema.app` is an `LSUIElement` menu bar app registered with `SMAppService.agent` from its embedded `Contents/Library/LaunchAgents/dev.noema.agent.plist`, which vends the Mach service `dev.noema.agent.ipc`. Its menu opens one reused settings window (基础设置, 快速操作, 词库, 其他); outside launchd it hands off to a running instance or stands by.

`NoemaIPC` carries JSON `IPCEnvelope`s (protocol version, kind, sequence, optional `generationID`, at most 256 KiB) under key `e` of an XPC dictionary:

- **Peer identity** — both sides set an `XPCPeerRequirement` and re-check every message's audit token with `PeerIdentityVerifier`, pinning the signer's team and leaf certificate (ad-hoc peers only under an ad-hoc self signature).
- **Connection** — `IPCConnectionManager` handshakes within 500 ms, heartbeats, and on failure backs off with jitter into a circuit breaker; `dev.noema.agent.ready` retries at once. Settings never move to an older `settingsRevision`; late callbacks of a stale `attemptID` are ignored.
- **Hot path** — the IME sends only fire-and-forget metadata, schema-switch status, and quick-action requests, dropped while unhealthy and under secure input. `GenerationGate` drops agent messages from another epoch or older generation, and suggestions for a cleared composition.

Rationale: [XPC IPC note](../.agents/notes/implemented/architecture/2026-11-25-xpc-ipc-and-companion-agent.md).

## Build pipeline

1. **librime** — `scripts/build/librime.sh` builds `vendor-out/librime/` from `vendor/librime.lock`; `--verify` requires an `@rpath` install name, system-only linkage, and arm64.
2. **Swift** — debug builds carry an rpath into `vendor-out/librime/lib`; release builds only `@executable_path/../Frameworks`.
3. **Tests** — `scripts/dev/test.sh` refuses a stale `vendor-out/librime`, then runs `swift test` with the CommandLineTools `Testing.framework`.
4. **Bundle** — [`scripts/build/bundle.sh`](../scripts/build/bundle.sh) assembles and signs each app in staging, then atomically publishes `NoemaIME.app` (with `rime-default/` and `rime-lua/`) and `Noema.app` (with `dictionaries.lock.json`, no librime, no rpath).
5. **Signing** — inside-out, never `--deep`, with empty entitlements; a certificate SHA-1 adds Hardened Runtime and a secure timestamp; `-` signs ad-hoc.
6. **Verification** — [`scripts/build/verify-bundle.sh`](../scripts/build/verify-bundle.sh) checks one app, or both in a directory; its header lists the checks.

## Governance gates

`scripts/governance/check.sh` runs four gates and fails if any fails; `--base <ref>` adds merge-base comparisons (only it reads `.git`):

- `verify-doc-budgets.mjs` — word ceilings from [`doc-budgets.manifest.json`](../scripts/governance/doc-budgets.manifest.json); with `--base`, no raised ceiling.
- `verify-agent-notes.mjs` — note paths, the Status line, and required sections; with `--base`, frozen `archived/` and `rejected/` notes.
- `verify-md-links.mjs` — every relative Markdown link and anchor resolves.
- `check-imports.sh` — targets `NoemaIME` links use no networking, audio, AX, event-tap, pasteboard, screen-capture, or `NSExpression` API, nor `NoemaAgentCore` or `NoemaLexiconAdmin`; no Xcode-only artifact, XCTest, or `xcodebuild`; `CLAUDE.md` aliases; `.kiln/agent/config.yml` holds only `version` and `review`.

## Continuous integration

Kiln runs `.kiln/workflows/ci.yml` for pushes and pull requests to `master`: `governance` (`check.sh`) and `rime-deps` (`librime.sh`, publishing `vendor-out/librime/`), then `test` (`test.sh`) and `bundle` (`bundle.sh --sign - --out dist`, then `verify-bundle.sh dist`). `.kiln/merge.yml` squash-merges once all four and `ai-review` pass. No CI job reads secrets or signing certificates.

## Seams

- **New Swift module** — add a target to `Package.swift`; one `NoemaIME` links joins `IME_SOURCE_DIRS` in `check-imports.sh`.
- **Panels** — implement `CandidatePresenting` or `VModePresenting` and pass it to `InputSessionCoordinator` in `EngineHost`.
- **New IPC message** — add a case to `IMEToAgent` or `AgentToIME` with a new `kind`; unknown kinds fail decoding, so both apps ship together.
- **New schema set** — add a `SchemaSetID` case and a `dictionaries.lock.json` entry.
- **New bundle content** — `bundle.sh` assembles it before signing; `verify-bundle.sh` gains the matching check.
- **librime inputs** — edit `vendor/librime.lock`; `test.sh` and `bundle.sh` refuse a stale `vendor-out/librime`.
