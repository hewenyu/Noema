# Noema architecture

Noema is a Chinese input method for macOS 26+ on Apple Silicon (arm64), built from a SwiftPM package with CommandLineTools only. Rationale lives in the [Agent Notes](../.agents/notes/README.md); standing rules live in [AGENTS.md](../AGENTS.md).

## Components

| Component | Kind | Role |
|---|---|---|
| `librime.1.dylib` | Vendored C++ library | Rime with the `lua` and `octagram` plugins, dependencies static; `install_name` `@rpath/librime.1.dylib`. |
| `CRime` | C target | Bridge to `rime_api.h`; `noema_rime_engine_api_available()` checks every member `RimeEngine` calls. |
| `NoemaCore` | Swift library | Domain types (`KeyEvent`, `TypingEngine`, `SchemaSetID`); `NoemaPaths` (identifiers, directories); `NoemaLog` (never logs user text). |
| `NoemaText` | Swift library | Text and toneless-pinyin normalization. |
| `NoemaLearning` | Swift library | `learning.sqlite` (`LearningStore`, system SQLite, WAL), the non-blocking `LearningStoreWriter`, and the `noema_learned.tsv` exporter. Zero networking. |
| `NoemaLexiconAdmin` | Swift library | `dictionaries.lock.json` validation, verified downloads, safe ZIP extraction, `LexiconInventory`. Agent and `noema-cli` only. |
| `NoemaIPC` | Swift library | IME ⇄ agent IPC (see [Companion agent and IPC](#companion-agent-and-ipc)). Zero TCC. |
| `NoemaEngine` | Swift library | `RimeEngine` (see [Typing engine](#typing-engine)), `RimeKeyMapper`, `BootGuard`, `DeployManifest`, `UserDBGuardian`, `SchemaSetSwitcher`, and the read-only `RimeRuntime`. |
| `Resources/rime-default`, `Resources/rime-lua` | Rime data | The built-in pinyin schema `noema_pinyin`; `noema_learned.lua`, the learned-phrase translator. |
| `NoemaIMEShell` | Swift library | Engine-independent IMKit logic: `InputSessionCoordinator` (see [Input method shell](#input-method-shell)), `NSEventKeyBridge`, and the `TextInputClient` and `CandidatePresenting` seams. Zero TCC. |
| `NoemaUI` | Swift library | The [candidate panel](#candidate-panel). Zero TCC. |
| `NoemaAgentCore` | Swift library | Agent logic without AppKit lifecycle: `AgentServiceCoordinator`, `LaunchAgentController`, `AgentStatusModel`, `LexiconController`, and the SwiftUI `SettingsRootView`. |
| `noema-cli` | Executable | Developer command line: `version`, `check-rime`, `install`, `reload`, `repl`, `lexicon list\|verify\|switch`. |
| `noema-rime-deployer` | Executable | The only process that runs librime's deployer, into an empty staging directory; writes `build/.noema-deploy-manifest.json` ([header](../Sources/noema-rime-deployer/main.swift)). Ships in `NoemaIME.app`. |
| `NoemaIME` | Executable | The process inside `NoemaIME.app`: `NoemaInputController`, `EngineHost` (the one `RimeEngine`, learning, schema switches, the agent connection), and the `IMKServer`. |
| `NoemaAgent` | Executable | The menu bar process inside `Noema.app`: status item, settings window, XPC listener. |

`NoemaIME` and `NoemaAgent` answer `--version` and `--help` before AppKit starts (`NoemaIME` also `--check-rime`); an unknown `--` option exits 2.

Module graph (arrows point at dependencies):

```
NoemaIME ────────────┬─> NoemaUI ─> NoemaIMEShell ───┐
noema-cli ───────────┼─> NoemaEngine ─> CRime ─> librime.1.dylib
noema-rime-deployer ─┘        └─> NoemaLearning ─> NoemaText
NoemaIME, NoemaAgent ─> NoemaIPC ─> NoemaCore <──────┘
NoemaAgent ─> NoemaAgentCore ─> NoemaIPC, NoemaLexiconAdmin ─> NoemaLearning
noema-cli ─> NoemaLexiconAdmin
```

Tests use Swift Testing only, one target per library (see `Package.swift`). `CRimeTests` holds every test that initializes librime, under the serialized suite `LibrimeSerializedTests`, and drives the real engine, deployer, XPC agent, and executables.

## Typing engine

`TypingEngine` is the synchronous, `@MainActor` boundary between the IMKit shell and an engine: `processKey(_:)` returns a `KeyHandlingResult` whose `committedText` and `handled` are independent. `RimeEngine` implements it:

- **Boot** — claim the process-wide librime, take the `user_data_dir` lock and arm the `BootGuard` sentinel, prepare `build/` off the main actor, initialize, open a session on `schemaID`, then disarm.
- **Deployment** — `build/` is trusted only when `DeployManifest.validated` matches a fresh SHA-256 inventory. `noema-rime-deployer` runs with a timeout in a locked staging directory; the result is re-validated and swapped in with `renamex_np(RENAME_SWAP)`, and any failure leaves `build/` unchanged ([`RimeEngine+Deploy.swift`](../Sources/NoemaEngine/RimeEngine+Deploy.swift)).
- **Safe Mode** — any boot failure sets a `SafeModeReason`, releases librime, and answers every key with `handled: false`; `recoverFromSafeMode()` boots again.
- **State** — every call drains `RimeCommit` and rebuilds `CompositionState`; offsets are UTF-16, and `generationID` strictly increases.

Rationale: [process model note](../.agents/notes/proposed/architecture/2026-11-23-process-model-and-permissions.md).

## Schema sets and learning

One root, `~/Library/Application Support/Noema/rime/`, holds the `.noema-rime.lock`, `learning.sqlite`, and `active-schema-set.json`. Each `SchemaSetID` (`builtin`, `wanxiang`, `rime-ice`, `mint`) runs with its own librime `user_data_dir` `sets/<set>/` (`build/`, userdbs, `lua/noema_learned.lua`, `noema_learned.tsv`); downloads extract to `schemas/<set>/`, models to `models/`. `EngineHost` boots the recorded set when installed, else `builtin`, and falls back once to `builtin` when the recorded set fails to boot.

- **Learning** — `RimeEngine.recordCommits` queues Han commits to `LearningStoreWriter`, never under secure input; it writes off the main actor and flushes before shutdown and switches. Keys are full pinyin, one standard syllable per Han character (jianpin expanded from the system reading); unverifiable spellings and shape or non-Mandarin schemas (Wubi, Jyutping) are never learned.
- **Switch** — `SchemaSetSwitcher` parks a request while composing (`pendingIdle`), deploys off the main actor (`compiling`), waits for idle again, then swaps librime (`ready` or `failed`). `UserDBGuardian` then probes the userdb with `export_user_dict`, restores a corrupt one from a SHA-256-verified snapshot or the store, and imports entries past that userdb's watermark, skipping non-Mandarin schemas; `noema_learned.tsv` is re-exported.
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

## Candidate panel

`CandidatePanelController` implements `CandidatePresenting` with one reused non-activating `NSPanel`. `CaretPositionResolver` places it below the caret, falling back to the client's last valid caret, then the mouse. `CandidateLayoutEngine` lays out with CoreText; `WidthHysteresis` keeps widths on 32 pt tiers that never shrink within a composition. The backdrop is `NSGlassEffectView` or `NSVisualEffectView`. Checks: [smoke checklist](runbooks/smoke-checklist.md). Rationale: [candidate panel note](../.agents/notes/implemented/architecture/2026-11-25-candidate-panel-coretext-glass.md).

## Companion agent and IPC

`Noema.app` is an `LSUIElement` menu bar app registered with `SMAppService.agent` from its embedded `Contents/Library/LaunchAgents/dev.noema.agent.plist`, which vends the Mach service `dev.noema.agent.ipc`. Its menu opens one reused settings window (基础设置, 快速操作, 词库, 其他). Outside launchd the check-in fails with `EPERM`: the agent hands off to a running instance, or stands by until the launchd-managed one posts `dev.noema.agent.ready`.

`NoemaIPC` carries JSON `IPCEnvelope`s (protocol version, kind, sequence, optional `generationID`, at most 256 KiB) under key `e` of an XPC dictionary:

- **Peer identity** — both sides set an `XPCPeerRequirement` and re-check every message's audit token with `PeerIdentityVerifier`; a certificate-signed binary pins its own team and leaf certificate, ad-hoc peers pass only for a valid ad-hoc self signature.
- **Connection** — `IPCConnectionManager` handshakes within 500 ms, heartbeats, and on failure backs off with jitter into a circuit breaker; `dev.noema.agent.ready` retries at once. Settings never move to an older `settingsRevision`; late callbacks of a stale `attemptID` are ignored.
- **Hot path** — the IME sends only fire-and-forget metadata and schema-switch status, dropped while unhealthy and under secure input. `GenerationGate` drops agent messages from another epoch or older generation, and suggestions for a cleared composition.

Rationale: [XPC IPC note](../.agents/notes/implemented/architecture/2026-11-25-xpc-ipc-and-companion-agent.md).

## Build pipeline

1. **librime** — `scripts/build/librime.sh` builds `vendor-out/librime/` from `vendor/librime.lock`; `--verify` requires an `@rpath` install name, system-only linkage, and arm64.
2. **Swift** — debug builds carry an rpath into `vendor-out/librime/lib`; release builds only `@executable_path/../Frameworks`.
3. **Tests** — `scripts/dev/test.sh` refuses a stale `vendor-out/librime`, then runs `swift test` with the CommandLineTools `Testing.framework`.
4. **Bundle** — [`scripts/build/bundle.sh`](../scripts/build/bundle.sh) assembles and signs each app in staging and publishes `<out>/NoemaIME.app` (with `rime-lua/noema_learned.lua`) and `<out>/Noema.app` (with `dictionaries.lock.json`, no librime, no rpath) atomically. Info.plists come from [`Resources/IME/Info.plist.in`](../Resources/IME/Info.plist.in) and [`Resources/Agent/Info.plist.in`](../Resources/Agent/Info.plist.in).
5. **Signing** — inside-out, never `--deep`, with empty entitlements; a certificate SHA-1 adds Hardened Runtime and a secure timestamp; `-` signs ad-hoc.
6. **Bundle verification** — [`scripts/build/verify-bundle.sh`](../scripts/build/verify-bundle.sh) checks one app, or both in a directory; its header lists the checks.

## Governance gates

`scripts/governance/check.sh` runs four gates and fails if any fails; `--base <ref>` adds merge-base comparisons inside a git work tree.

| Gate | Enforces |
|---|---|
| `verify-doc-budgets.mjs` | Word ceilings from [`doc-budgets.manifest.json`](../scripts/governance/doc-budgets.manifest.json); with `--base`, no raised ceiling. |
| `verify-agent-notes.mjs` | Note paths, the Status line, and required sections; with `--base`, frozen `archived/` and `rejected/` notes. |
| `verify-md-links.mjs` | Every relative Markdown link and anchor resolves. |
| `check-imports.sh` | Every target `NoemaIME` links uses no networking, audio, AX, event-tap, pasteboard, or screen-capture API, nor `NoemaAgentCore` or `NoemaLexiconAdmin`; no Xcode-only artifact, XCTest, or `xcodebuild`; `CLAUDE.md` aliases; `.kiln/agent/config.yml` holds only `version` and `review`. |

Only `--base` reads `.git`, so the gates and build scripts run in git-less Kiln workspaces.

## Continuous integration

Kiln runs `.kiln/workflows/ci.yml` for pushes and pull requests to `master`:

| Job | Needs | Runs |
|---|---|---|
| `governance` | — | `scripts/governance/check.sh` |
| `rime-deps` | — | `scripts/build/librime.sh`; publishes `vendor-out/librime/` |
| `test` | `rime-deps` | `scripts/dev/test.sh` |
| `bundle` | `rime-deps` | `bundle.sh --sign - --out dist` and `verify-bundle.sh dist` (both apps) |

`.kiln/merge.yml` squash-merges once all four jobs and `ai-review` pass. No CI job reads secrets or signing certificates.

## Seams

- **New Swift module** — add a target to `Package.swift`; one `NoemaIME` links joins `IME_SOURCE_DIRS` in `check-imports.sh`.
- **Candidate presentation** — implement `CandidatePresenting` and pass it to `InputSessionCoordinator` in `EngineHost`.
- **New IPC message** — add a case to `IMEToAgent` or `AgentToIME` with a new `kind`; unknown kinds fail decoding, so both apps ship together.
- **New schema set** — add a `SchemaSetID` case and a `dictionaries.lock.json` entry.
- **New bundle content** — `bundle.sh` assembles it before signing; `verify-bundle.sh` gains the matching check.
- **librime inputs** — edit `vendor/librime.lock`; `test.sh` and `bundle.sh` refuse a stale `vendor-out/librime`.
