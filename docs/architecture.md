# Noema architecture

Noema is a Chinese input method for macOS 26+ on Apple Silicon (arm64), built from a SwiftPM package with CommandLineTools only. This page maps the components, the build and packaging pipeline, the governance gates, and the seams where new parts attach. Rationale lives in the [Agent Notes](../.agents/notes/README.md); standing rules live in [AGENTS.md](../AGENTS.md).

## Components

| Component | Kind | Role |
|---|---|---|
| `librime.1.dylib` | Vendored C++ library | Rime engine with the `lua` and `octagram` plugins merged in; Boost, leveldb, marisa, OpenCC, yaml-cpp, and spdlog are linked statically. `install_name` is `@rpath/librime.1.dylib`. |
| `CRime` | C target | Bridge to `rime_api.h`. `noema_rime_get_api()` wraps `rime_get_api()` in `pthread_once`; `noema_rime_engine_api_available()` checks every member `RimeEngine` calls. |
| `NoemaCore` | Swift library | Domain types: `NoemaVersion`, `KeyEvent`, `VirtualKeyCode`, `NoemaError`, `UTF8OffsetConverter`, the `TypingEngine` protocol with `CompositionState` and `KeyHandlingResult`; `NoemaPaths` (IMKit identifiers, standard directories, `rime-default` lookup); `NoemaLog` (per-component `os.Logger`; never logs user text). |
| `NoemaText` | Swift library | Text normalization. |
| `NoemaIPC` | Swift library | IPC envelope types. |
| `NoemaEngine` | Swift library | `RimeEngine`, the `TypingEngine` over in-process librime (see [Typing engine](#typing-engine)); `RimeKeyMapper`; `BootGuard`; `DeployManifest`, the hashed input and output inventory of a deployed `build/`; and the read-only `RimeRuntime` facade (librime version, required module registration). |
| `Resources/rime-default` | Rime data | The built-in minimal pinyin schema `noema_pinyin` (`default.yaml`, `noema_pinyin.schema.yaml`, `noema_pinyin.dict.yaml`), plain UTF-8 YAML used as `shared_data_dir`. |
| `NoemaIMEShell` | Swift library | IMKit shell logic, engine-independent: `InputSessionCoordinator` (see [Input method shell](#input-method-shell)), `NSEventKeyBridge`, and the `TextInputClient` and `CandidatePresenting` seams. Zero TCC, like `NoemaIME`. |
| `noema-cli` | Executable | Developer command line: `version`, `check-rime`, `install`, `reload`, `repl` (each takes `--help`). |
| `noema-rime-deployer` | Executable | The only process that runs librime's deployer: it deploys into an empty staging directory, requires every output the schema needs, and writes `build/.noema-deploy-manifest.json`; any failure exits non-zero. Its [header](../Sources/noema-rime-deployer/main.swift) lists arguments and checks. Ships as `NoemaIME.app/Contents/MacOS/noema-rime-deployer`. |
| `NoemaIME` | Executable | The process inside `NoemaIME.app`: `NoemaInputController`, `EngineHost` (the one `RimeEngine`), and the `IMKServer`. `--version`, `--check-rime`, and `--help` answer before AppKit starts; an unknown `--` option exits 2. |

Module graph (arrows point at dependencies):

```
NoemaIME ────────────┬─> NoemaIMEShell ──────────────┐
noema-cli ───────────┼─> NoemaEngine ─> CRime ─> librime.1.dylib
noema-rime-deployer ─┘        │                      │
                              └─> NoemaCore <────────┘
NoemaText, NoemaIPC: standalone libraries
```

Tests use Swift Testing only. `NoemaCoreTests` cover `NoemaCore`, `NoemaIPC`, and `NoemaText`; `NoemaEngineTests` cover `RimeKeyMapper`, `BootGuard`, `DeployManifest`, and candidate labels without librime; `NoemaIMEShellTests` feed real `NSEvent`s to `NSEventKeyBridge`. `CRimeTests` holds every test that initializes librime, under the serialized suite `LibrimeSerializedTests`: the raw bridge, `RimeEngine` on `Resources/rime-default` (every Safe Mode reason, failed and cancelled deployments, P95 latency under 2 ms), `InputSessionCoordinator` on the real engine, and the real `noema-cli` and `NoemaIME` executables, which `swift test` therefore builds.

## Typing engine

`TypingEngine` is the synchronous, `@MainActor` boundary between the IMKit shell and an engine: `processKey(_:)` returns a `KeyHandlingResult`. `committedText` and `handled` are independent: without a punctuator, `,` after `nihao` commits "你好" and is still unhandled. `RimeEngine` implements it:

- **Key mapping** — `RimeKeyMapper` turns a `KeyEvent` into an X11 keysym and mask or `.passthrough`; its header lists the pass-through rules.
- **Boot** — claim the process-wide librime (one live `RimeEngine`; `RimeApi.setup` runs once), take the `user_data_dir` lock and arm the `BootGuard` sentinel, prepare `build/`, initialize, open a session on `schemaID`, then disarm. `RimeEngine.start` prepares `build/` off the main actor; cancelling it stops the deployer, disarms, and unlocks.
- **Deployment** — `build/` is trusted only when `DeployManifest.validated` passes: the manifest names `schemaID` and equals a fresh inventory of `build/` (sizes and SHA-256, nothing unlisted). `deployIfNeeded` deploys when that fails or the recorded inputs (every file under `sharedDataDir` and each top-level `*.custom.yaml`) changed; `forceDeploy` always deploys; `neverDeploy` enters Safe Mode instead. A deployment runs `noema-rime-deployer` with a 60-second timeout in `user_data_dir/.deploy-staging.<pid>.<uuid>`, re-validates, and swaps `build/` with two renames; any failure leaves `build/` unchanged (Safe Mode). Crash recovery and refused inputs: [`RimeEngine+Deploy.swift`](../Sources/NoemaEngine/RimeEngine+Deploy.swift) and the process model note.
- **Safe Mode** — any boot failure sets a `SafeModeReason`, releases librime, and answers every key with `handled: false` and `.safeMode`; `recoverFromSafeMode()` clears the sentinel under the lock and boots again.
- **State** — every call drains `RimeCommit` and rebuilds `CompositionState` from `RimeContext` and `RimeStatus`; `UTF8OffsetConverter` turns librime's byte offsets into UTF-16, and `generationID` strictly increases.

Rationale: [process model note](../.agents/notes/proposed/architecture/2026-11-23-process-model-and-permissions.md).

## Input method shell

IMKit creates one `NoemaInputController` per client session; it forwards every IMKit call, on the main thread, to the process-wide `InputSessionCoordinator` with its session token and an `IMKTextInput` adapter. `recognizedEvents` is key-down only, so IMKit keeps committing on a click outside the marked text. The coordinator:

- passes every key through, before the engine sees it, while `IsSecureEventInputEnabled()` is true, and hides the panel; under secure input a commit or ASCII switch drops the composition and inserts nothing;
- gives the composition to one token at a time: a late `deactivate` from a previous owner is ignored, and a new owner clears the old client's marked text with `clearComposition()`, never `resetSession()` (which resets `ascii_mode`);
- returns `false` without an engine, in Safe Mode, and in idle ASCII mode;
- inserts `committedText` first, then shows marked text with UTF-16 caret and selection or clears it, and returns `handled`.

`EngineHost` registers the `IMKServer`, then calls `RimeEngine.start` after launch; until ready and after `shutdown()` (synchronous boot cleanup), every key passes through. The candidate panel plugs in through `CandidatePresenting` (`NoOpCandidatePresenter` today).

`noema-cli install` validates a staged copy of the bundle inside `--dest` (identifiers, executables, librime, `rime-default`, strict signature; ad-hoc anywhere in the bundle or its nested code only with `--allow-adhoc`) and, under a `flock` after recovering interrupted-install leftovers, swaps it in with one signal-masked `renamex_np(RENAME_SWAP)`; for `~/Library/Input Methods` it also registers the bundle and stops the `NoemaIME` processes found before the swap. Processes left running (`--no-reload`, or a 3 s timeout, which exits 1) go to a pending-reload ledger. `reload` stops this user's `NoemaIME` of one bundle plus its ledger; `repl` drives a real engine. Details: [`noema-cli` sources](../Sources/noema-cli/InstallCommand.swift).

## Build pipeline

1. **librime** — `scripts/build/librime.sh` builds `vendor-out/librime/` from the commits and Boost SHA256 pinned in `vendor/librime.lock`. Its self-check gate (`--verify`) requires the `@rpath` install name, an `otool -L` allow-list of `/usr/lib/` and `/System/Library/`, no `LC_RPATH`, and arm64 only; `--check-linkage-stdin` exposes the allow-list to other scripts.
2. **Swift** — `Package.swift` links `CRime` against `vendor-out/librime/lib`. Debug builds carry an rpath into `vendor-out/librime/lib`; release builds carry only `@executable_path/../Frameworks`.
3. **Tests** — `scripts/dev/test.sh` refuses to run unless `vendor-out/librime/.lock-sha256` matches `vendor/librime.lock` and the self-check gate passes, then runs `swift test` with the CommandLineTools `Testing.framework` search paths.
4. **Bundle** — [`scripts/build/bundle.sh`](../scripts/build/bundle.sh) builds the release `NoemaIME` and `noema-rime-deployer` products, assembles `NoemaIME.app` in a staging directory next to the output, signs it, and publishes it atomically to `<out>/NoemaIME.app` under a per-output `flock`. The bundle holds both executables, `librime.1.dylib`, the OpenCC data, `Resources/rime-default`, and icons drawn in code by `Resources/IME/generate-icons.swift` (no image files or asset catalogs). `Contents/Info.plist` is [`Resources/IME/Info.plist.in`](../Resources/IME/Info.plist.in) with version and build injected: IMKit keys, no privacy usage description.
5. **Signing** — `bundle.sh` signs inside-out (`librime.1.dylib`, `noema-rime-deployer`, `NoemaIME`, then the app), never with `--deep`, using the empty [`Resources/IME/NoemaIME.entitlements`](../Resources/IME/NoemaIME.entitlements). A certificate SHA-1 signs with Hardened Runtime and a secure timestamp; `-` signs ad-hoc without the runtime flag, because library validation needs a Team ID to load the bundled dylib.
6. **Bundle verification** — [`scripts/build/verify-bundle.sh`](../scripts/build/verify-bundle.sh) checks the IMKit, zero-TCC, linkage, signing, and signed-entitlement contracts, then launches `noema-rime-deployer --version`, `NoemaIME --version` (the `Info.plist` version), and `NoemaIME --check-rime` (dyld resolves the bundled librime; every module registers). Its header lists the checks.

## Governance gates

`scripts/governance/check.sh` runs four gates and fails if any fails; `--base <ref>` adds merge-base comparisons inside a git work tree and is ignored elsewhere.

| Gate | Enforces |
|---|---|
| `verify-doc-budgets.mjs` | Word ceilings for the documents listed in [`doc-budgets.manifest.json`](../scripts/governance/doc-budgets.manifest.json); with `--base`, no raised ceiling. |
| `verify-agent-notes.mjs` | Note paths `{lifecycle}/{class}/yyyy-mm-dd-topic.md`, the Status line, and the required sections per lifecycle; with `--base`, frozen `archived/` and `rejected/` notes. |
| `verify-md-links.mjs` | Every relative Markdown link and anchor resolves. |
| `check-imports.sh` | Comment-aware scan: `Sources/NoemaIME` and `Sources/NoemaIMEShell` (each must exist) import no networking, audio, speech, AX, event-tap, pasteboard, or screen-capture API; no Xcode-only artifact, `import XCTest`, or `xcodebuild` call; `CLAUDE.md` and `docs/CLAUDE.md` link to their `AGENTS.md`; `.kiln/agent/config.yml` holds only `version` and `review` and no `development` key. |

Only `--base` reads `.git`, so the gates and build scripts run in git-less Kiln workspaces.

## Continuous integration

Kiln runs `.kiln/workflows/ci.yml` on `darwin/arm64` hosts for pushes and pull requests to `master`:

| Job | Needs | Runs |
|---|---|---|
| `governance` | — | `scripts/governance/check.sh` |
| `rime-deps` | — | `scripts/build/librime.sh`; publishes `vendor-out/librime/` as the `librime` output |
| `test` | `rime-deps` | `scripts/dev/test.sh` on the fetched librime and `Resources/rime-default` |
| `bundle` | `rime-deps` | `bundle.sh --sign -` and `verify-bundle.sh` on the fetched librime |

`.kiln/merge.yml` squash-merges once all four jobs and `ai-review` pass. `.kiln/agent/config.yml` enables only pull-request review, guided by `.kiln/agent/review.md`, which trusts only the repository owner. No CI job reads secrets or signing certificates.

## Seams

- **New Swift module** — add a target to `Package.swift`; bundled executables depend on `NoemaEngine` for Rime and inherit the release-only `@executable_path/../Frameworks` rpath from `CRime`.
- **Candidate panel** — implement `CandidatePresenting` in `NoemaIMEShell` and pass it to `InputSessionCoordinator` in `EngineHost`; `check-imports.sh` bounds what the shell may import. `Info.plist.in` and `NoemaPaths` name the controller class and connection together.
- **New bundle content** — `bundle.sh` assembles it before signing; `verify-bundle.sh` gains the matching check.
- **librime inputs** — edit `vendor/librime.lock`; `rime-deps` rebuilds, and `test.sh` and `bundle.sh` refuse a stale `vendor-out/librime`.
- **Governance** — a new gate joins `scripts/governance/check.sh`; a new budgeted document joins `doc-budgets.manifest.json`.
