# Noema architecture

Noema is a Chinese input method for macOS 26+ on Apple Silicon (arm64), built from a SwiftPM package with CommandLineTools only. Rationale lives in the [Agent Notes](../.agents/notes/README.md); standing rules live in [AGENTS.md](../AGENTS.md).

## Components

| Component | Kind | Role |
|---|---|---|
| `librime.1.dylib` | Vendored C++ library | Rime with the `lua` and `octagram` plugins merged in; dependencies linked statically; `install_name` `@rpath/librime.1.dylib`. |
| `CRime` | C target | Bridge to `rime_api.h`; `noema_rime_engine_api_available()` checks every member `RimeEngine` calls. |
| `NoemaCore` | Swift library | Domain types (`KeyEvent`, `NoemaError`, `UTF8OffsetConverter`, the `TypingEngine` protocol with `CompositionState`); `NoemaPaths` (IMKit and agent identifiers, directories); `NoemaLog` (per-component `os.Logger`; never logs user text). |
| `NoemaText` | Swift library | Text normalization. |
| `NoemaIPC` | Swift library | IME ⇄ agent IPC (see [Companion agent and IPC](#companion-agent-and-ipc)). Zero TCC. |
| `NoemaEngine` | Swift library | `RimeEngine` (see [Typing engine](#typing-engine)), `RimeKeyMapper`, `BootGuard`, `DeployManifest` (hashed inventory of a deployed `build/`), and the read-only `RimeRuntime` facade. |
| `Resources/rime-default` | Rime data | The built-in minimal pinyin schema `noema_pinyin`, used as `shared_data_dir`. |
| `NoemaIMEShell` | Swift library | Engine-independent IMKit logic: `InputSessionCoordinator` (see [Input method shell](#input-method-shell)), `NSEventKeyBridge`, and the `TextInputClient` and `CandidatePresenting` seams. Zero TCC. |
| `NoemaUI` | Swift library | The [candidate panel](#candidate-panel). Zero TCC. |
| `NoemaAgentCore` | Swift library | Agent logic without AppKit lifecycle: `AgentServiceCoordinator`, `LaunchAgentController` (`SMAppService.agent`), `AgentStatusModel`, and the SwiftUI `SettingsRootView`. |
| `noema-cli` | Executable | Developer command line: `version`, `check-rime`, `install`, `reload`, `repl`. |
| `noema-rime-deployer` | Executable | The only process that runs librime's deployer, into an empty staging directory; writes `build/.noema-deploy-manifest.json` ([header](../Sources/noema-rime-deployer/main.swift)). Ships in `NoemaIME.app`. |
| `NoemaIME` | Executable | The process inside `NoemaIME.app`: `NoemaInputController`, `EngineHost` (the one `RimeEngine` and the agent connection), and the `IMKServer`. |
| `NoemaAgent` | Executable | The menu bar process inside `Noema.app` (`dev.noema.agent`): status item, settings window, XPC listener. |

`NoemaIME` and `NoemaAgent` answer `--version` and `--help` before AppKit starts (`NoemaIME` also `--check-rime`); an unknown `--` option exits 2.

Module graph (arrows point at dependencies):

```
NoemaIME ────────────┬─> NoemaUI ─> NoemaIMEShell ───┐
noema-cli ───────────┼─> NoemaEngine ─> CRime ─> librime.1.dylib
noema-rime-deployer ─┘        │                      │
NoemaIME, NoemaAgent ─> NoemaIPC ─> NoemaCore <──────┘
NoemaAgent ─> NoemaAgentCore ─> NoemaIPC
NoemaText: standalone
```

Tests use Swift Testing only. `NoemaCoreTests` cover `NoemaCore` and `NoemaText`; `NoemaEngineTests` cover the engine helpers without librime; `NoemaIMEShellTests` feed real `NSEvent`s to `NSEventKeyBridge`; `NoemaUITests` cover panel layout with real CoreText fonts. `NoemaIPCTests` run the wire format, `GenerationGate`, and `IPCConnectionManager` on the in-memory transport and a manual clock, `PeerIdentityVerifier` on real audit tokens (including an ad-hoc signed child), real libxpc round trips on anonymous listeners, and the real `NoemaAgent` executable. `CRimeTests` holds every test that initializes librime, under the serialized suite `LibrimeSerializedTests`: the raw bridge, `RimeEngine` (every Safe Mode reason, P95 latency under 2 ms), `InputSessionCoordinator` on the real engine, the IME typing through a real XPC agent that is killed mid-run, and the real `noema-cli` and `NoemaIME` executables.

## Typing engine

`TypingEngine` is the synchronous, `@MainActor` boundary between the IMKit shell and an engine: `processKey(_:)` returns a `KeyHandlingResult` whose `committedText` and `handled` are independent (`,` after `nihao` commits "你好" and is still unhandled). `RimeEngine` implements it:

- **Boot** — claim the process-wide librime, take the `user_data_dir` lock and arm the `BootGuard` sentinel, prepare `build/` off the main actor, initialize, open a session on `schemaID`, then disarm.
- **Deployment** — `build/` is trusted only when `DeployManifest.validated` matches a fresh SHA-256 inventory. A deployment runs `noema-rime-deployer` with a 60-second timeout in staging, re-validates, and swaps `build/` with two renames; any failure leaves `build/` unchanged ([`RimeEngine+Deploy.swift`](../Sources/NoemaEngine/RimeEngine+Deploy.swift)).
- **Safe Mode** — any boot failure sets a `SafeModeReason`, releases librime, and answers every key with `handled: false`; `recoverFromSafeMode()` boots again.
- **State** — every call drains `RimeCommit` and rebuilds `CompositionState`; offsets are UTF-16, and `generationID` strictly increases.

Rationale: [process model note](../.agents/notes/proposed/architecture/2026-11-23-process-model-and-permissions.md).

## Input method shell

IMKit creates one `NoemaInputController` per client session; it forwards every call, on the main thread, to the process-wide `InputSessionCoordinator` with its session token. The coordinator:

- passes every key through, before the engine sees it, while `IsSecureEventInputEnabled()` is true, and hides the panel;
- gives the composition to one token at a time, ignoring a late `deactivate` and clearing the old client with `clearComposition()`, never `resetSession()`;
- returns `false` without an engine, in Safe Mode, and in idle ASCII mode;
- inserts `committedText` first, then shows or clears marked text, and returns `handled`; clients in `InlinePreeditDisabledBundleIDs` get no marked text;
- applies panel clicks like keys, ignoring stale generations and secure input;
- reports every composition change through `onCompositionChange`.

`EngineHost` registers the `IMKServer`, then starts `RimeEngine` and the agent connection after launch; until ready and after `shutdown()`, every key passes through.

`noema-cli install` validates a staged bundle (identifiers, executables, librime, strict signature; ad-hoc only with `--allow-adhoc`), swaps it in with one `renamex_np(RENAME_SWAP)` under a `flock`, and stops running `NoemaIME` processes ([`InstallCommand.swift`](../Sources/noema-cli/InstallCommand.swift)).

## Candidate panel

`CandidatePanelController` implements `CandidatePresenting` with one reused non-activating `NSPanel`. `CaretPositionResolver` places it below the caret, falling back to the client's last valid caret, then the mouse. `CandidateLayoutEngine` lays out with CoreText; `WidthHysteresis` keeps widths on 32 pt tiers that never shrink within a composition. The backdrop is `NSGlassEffectView` or `NSVisualEffectView`. Checks: [smoke checklist](runbooks/smoke-checklist.md). Rationale: [candidate panel note](../.agents/notes/implemented/architecture/2026-11-25-candidate-panel-coretext-glass.md).

## Companion agent and IPC

`Noema.app` is an `LSUIElement` menu bar app registered with `SMAppService.agent` from its embedded `Contents/Library/LaunchAgents/dev.noema.agent.plist`, which vends the Mach service `dev.noema.agent.ipc`. Its menu opens one reused settings window (基础设置, 快速操作, 其他). Outside launchd the listener check-in fails with `EPERM`: the agent hands off to a running instance (LaunchServices reopens it) and exits, or stays in standby until the launchd-managed instance posts `dev.noema.agent.ready`.

`NoemaIPC` carries JSON `IPCEnvelope`s (protocol version, kind, sequence, optional `generationID`, at most 256 KiB) under key `e` of an XPC dictionary:

- **Peer identity** — both sides set an `XPCPeerRequirement` and re-check every message's audit token with `PeerIdentityVerifier`. A certificate-signed binary always pins its own team and leaf certificate; ad-hoc peers pass only when the binary itself has a valid ad-hoc signature. Without a valid self signature the policy is unpinned strict: no session or listener is opened.
- **Connection** — `IPCConnectionManager` handshakes within 500 ms, heartbeats, and on failure degrades, backs off exponentially with jitter, and opens a circuit breaker; the agent's `dev.noema.agent.ready` notification retries at once, at most once per open circuit. `helloAck` counts only while connecting, `heartbeatAck` only while healthy, and settings never move to an older `settingsRevision`. Each attempt has an `attemptID`, so late callbacks are ignored.
- **Hot path** — the IME sends only fire-and-forget metadata (composition updates coalesce in a bounded outbox), dropped while unhealthy; under secure input neither `CompositionIPCReporter` nor `IPCConnectionManager` emits anything. `GenerationGate` drops agent messages from another epoch or older generation, and suggestions for a cleared composition.

Rationale: [XPC IPC note](../.agents/notes/implemented/architecture/2026-11-25-xpc-ipc-and-companion-agent.md).

## Build pipeline

1. **librime** — `scripts/build/librime.sh` builds `vendor-out/librime/` from `vendor/librime.lock`; its gate (`--verify`) requires an `@rpath` install name, system-only linkage, and arm64.
2. **Swift** — debug builds carry an rpath into `vendor-out/librime/lib`; release builds carry only `@executable_path/../Frameworks`.
3. **Tests** — `scripts/dev/test.sh` refuses a stale or unverified `vendor-out/librime`, then runs `swift test` with the CommandLineTools `Testing.framework` paths.
4. **Bundle** — [`scripts/build/bundle.sh`](../scripts/build/bundle.sh) builds the release executables, assembles and signs each app in staging, and publishes `<out>/NoemaIME.app` and `<out>/Noema.app` atomically (`--target ime|agent|all`). The Info.plists are [`Resources/IME/Info.plist.in`](../Resources/IME/Info.plist.in) and [`Resources/Agent/Info.plist.in`](../Resources/Agent/Info.plist.in) with version and build injected, without privacy usage descriptions. `Noema.app` holds no librime and no rpath.
5. **Signing** — inside-out, never `--deep`, with empty entitlements; a certificate SHA-1 adds Hardened Runtime and a secure timestamp; `-` signs ad-hoc.
6. **Bundle verification** — [`scripts/build/verify-bundle.sh`](../scripts/build/verify-bundle.sh) checks one app, or both in a directory: identifiers, zero TCC, linkage, signatures, entitlements, the LaunchAgent plist, and the `--version` probes. Its header lists the checks.

## Governance gates

`scripts/governance/check.sh` runs four gates and fails if any fails; `--base <ref>` adds merge-base comparisons inside a git work tree.

| Gate | Enforces |
|---|---|
| `verify-doc-budgets.mjs` | Word ceilings from [`doc-budgets.manifest.json`](../scripts/governance/doc-budgets.manifest.json); with `--base`, no raised ceiling. |
| `verify-agent-notes.mjs` | Note paths, the Status line, and required sections; with `--base`, frozen `archived/` and `rejected/` notes. |
| `verify-md-links.mjs` | Every relative Markdown link and anchor resolves. |
| `check-imports.sh` | `Sources/NoemaIME`, `NoemaIMEShell`, `NoemaUI`, and `NoemaIPC` use no networking, audio, AX, event-tap, pasteboard, or screen-capture API; no Xcode-only artifact, XCTest, or `xcodebuild`; `CLAUDE.md` aliases; `.kiln/agent/config.yml` holds only `version` and `review`. |

Only `--base` reads `.git`, so the gates and build scripts run in git-less Kiln workspaces.

## Continuous integration

Kiln runs `.kiln/workflows/ci.yml` for pushes and pull requests to `master`:

| Job | Needs | Runs |
|---|---|---|
| `governance` | — | `scripts/governance/check.sh` |
| `rime-deps` | — | `scripts/build/librime.sh`; publishes `vendor-out/librime/` |
| `test` | `rime-deps` | `scripts/dev/test.sh` |
| `bundle` | `rime-deps` | `bundle.sh --sign - --out dist` and `verify-bundle.sh dist` (both apps) |

`.kiln/merge.yml` squash-merges once all four jobs and `ai-review` pass. `.kiln/agent/config.yml` enables only pull-request review. No CI job reads secrets or signing certificates.

## Seams

- **New Swift module** — add a target to `Package.swift`; bundled executables inherit the release-only rpath from `CRime`.
- **Candidate presentation** — implement `CandidatePresenting` and pass it to `InputSessionCoordinator` in `EngineHost`.
- **New IPC message** — add a case to `IMEToAgent` or `AgentToIME` with a new `kind`; unknown kinds fail decoding, so both apps ship together.
- **New bundle content** — `bundle.sh` assembles it before signing; `verify-bundle.sh` gains the matching check.
- **librime inputs** — edit `vendor/librime.lock`; `test.sh` and `bundle.sh` refuse a stale `vendor-out/librime`.
- **Governance** — a new gate joins `check.sh`; a new budgeted document joins `doc-budgets.manifest.json`.
