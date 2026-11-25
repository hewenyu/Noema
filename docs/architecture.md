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
| `NoemaIMEShell` | Swift library | IMKit shell logic, engine-independent: `InputSessionCoordinator` (see [Input method shell](#input-method-shell)), `NSEventKeyBridge`, and the `TextInputClient` and `CandidatePresenting` seams. Zero TCC. |
| `NoemaUI` | Swift library | The candidate panel (see [Candidate panel](#candidate-panel)): `CandidateLayoutEngine` (CoreText), `WidthHysteresis`, `CaretPositionResolver`, `CandidatePanelView`, and `CandidatePanelController`. Zero TCC. |
| `noema-cli` | Executable | Developer command line: `version`, `check-rime`, `install`, `reload`, `repl` (each takes `--help`). |
| `noema-rime-deployer` | Executable | The only process that runs librime's deployer, into an empty staging directory; writes `build/.noema-deploy-manifest.json` and exits non-zero on any failure ([header](../Sources/noema-rime-deployer/main.swift)). Ships in `NoemaIME.app/Contents/MacOS`. |
| `NoemaIME` | Executable | The process inside `NoemaIME.app`: `NoemaInputController`, `EngineHost` (the one `RimeEngine`), and the `IMKServer`. `--version`, `--check-rime`, and `--help` answer before AppKit starts; an unknown `--` option exits 2. |

Module graph (arrows point at dependencies):

```
NoemaIME ────────────┬─> NoemaUI ─> NoemaIMEShell ───┐
noema-cli ───────────┼─> NoemaEngine ─> CRime ─> librime.1.dylib
noema-rime-deployer ─┘        │                      │
                              └─> NoemaCore <────────┘
NoemaText, NoemaIPC: standalone libraries
```

Tests use Swift Testing only. `NoemaCoreTests` cover `NoemaCore`, `NoemaIPC`, and `NoemaText`; `NoemaEngineTests` cover `RimeKeyMapper`, `BootGuard`, `DeployManifest`, and candidate labels without librime; `NoemaIMEShellTests` feed real `NSEvent`s to `NSEventKeyBridge` and check `DocumentCaretRange`; `NoemaUITests` cover panel layout with real CoreText fonts, width hysteresis, and caret placement headlessly. `CRimeTests` holds every test that initializes librime, under the serialized suite `LibrimeSerializedTests`: the raw bridge, `RimeEngine` on `Resources/rime-default` (every Safe Mode reason, failed and cancelled deployments, P95 latency under 2 ms), `InputSessionCoordinator` on the real engine, and the real `noema-cli` and `NoemaIME` executables, which `swift test` therefore builds.

## Typing engine

`TypingEngine` is the synchronous, `@MainActor` boundary between the IMKit shell and an engine: `processKey(_:)` returns a `KeyHandlingResult`. `committedText` and `handled` are independent: without a punctuator, `,` after `nihao` commits "你好" and is still unhandled. `RimeEngine` implements it:

- **Key mapping** — `RimeKeyMapper` turns a `KeyEvent` into an X11 keysym and mask or `.passthrough`; its header lists the pass-through rules.
- **Boot** — claim the process-wide librime, take the `user_data_dir` lock and arm the `BootGuard` sentinel, prepare `build/` (off the main actor in `RimeEngine.start`), initialize, open a session on `schemaID`, then disarm. Cancelling stops the deployer, disarms, and unlocks.
- **Deployment** — `build/` is trusted only when `DeployManifest.validated` passes (the manifest names `schemaID` and equals a fresh SHA-256 inventory of `build/`). `deployIfNeeded` deploys when that fails or the recorded inputs changed; `forceDeploy` always deploys; `neverDeploy` enters Safe Mode instead. A deployment runs `noema-rime-deployer` with a 60-second timeout in a staging directory, re-validates, and swaps `build/` with two renames; any failure leaves `build/` unchanged (Safe Mode). Details: [`RimeEngine+Deploy.swift`](../Sources/NoemaEngine/RimeEngine+Deploy.swift).
- **Safe Mode** — any boot failure sets a `SafeModeReason`, releases librime, and answers every key with `handled: false` and `.safeMode`; `recoverFromSafeMode()` clears the sentinel under the lock and boots again.
- **State** — every call drains `RimeCommit` and rebuilds `CompositionState` from `RimeContext` and `RimeStatus`; `UTF8OffsetConverter` turns librime's byte offsets into UTF-16, and `generationID` strictly increases.

Rationale: [process model note](../.agents/notes/proposed/architecture/2026-11-23-process-model-and-permissions.md).

## Input method shell

IMKit creates one `NoemaInputController` per client session; it forwards every IMKit call, on the main thread, to the process-wide `InputSessionCoordinator` with its session token and an `IMKTextInput` adapter. `recognizedEvents` is key-down only, so IMKit keeps committing on a click outside the marked text. The coordinator:

- passes every key through, before the engine sees it, while `IsSecureEventInputEnabled()` is true, and hides the panel; under secure input a commit or ASCII switch drops the composition and inserts nothing;
- gives the composition to one token at a time: a late `deactivate` from a previous owner is ignored, and a new owner clears the old client's marked text with `clearComposition()`, never `resetSession()` (which resets `ascii_mode`);
- returns `false` without an engine, in Safe Mode, and in idle ASCII mode;
- inserts `committedText` first, then shows marked text with UTF-16 caret and selection or clears it, and returns `handled`; clients in the IME's `InlinePreeditDisabledBundleIDs` default get no marked text, and the panel draws the preedit;
- applies panel clicks (`selectCandidate`, `changePage`) like keys, ignoring stale generations and secure input.

`EngineHost` registers the `IMKServer`, then calls `RimeEngine.start` after launch; until ready and after `shutdown()`, every key passes through. It creates the candidate panel lazily with the coordinator.

`noema-cli install` validates a staged copy of the bundle (identifiers, executables, librime, strict signature; ad-hoc only with `--allow-adhoc`) and swaps it in with one `renamex_np(RENAME_SWAP)` under a `flock`; for `~/Library/Input Methods` it registers the bundle and stops running `NoemaIME` processes, recording survivors for `reload`. `repl` drives a real engine. Details: [`InstallCommand.swift`](../Sources/noema-cli/InstallCommand.swift).

## Candidate panel

`CandidatePanelController` implements `CandidatePresenting` with one reused non-activating `NSPanel` above the client's window level. `CaretPositionResolver` places it below the client's caret (above near the screen bottom), falling back to the last valid caret of the same `uniqueClientIdentifier`, then the mouse. `CandidateLayoutEngine` lays out with CoreText and scrolls an overflowing floating preedit to keep its caret visible; `WidthHysteresis` keeps widths on 32 pt tiers that never shrink within a composition. The backdrop is `NSGlassEffectView` or, in `.visualEffect` mode, `NSVisualEffectView`. Manual checks: [smoke checklist](runbooks/smoke-checklist.md). Rationale: [candidate panel note](../.agents/notes/implemented/architecture/2026-11-25-candidate-panel-coretext-glass.md).

## Build pipeline

1. **librime** — `scripts/build/librime.sh` builds `vendor-out/librime/` from the inputs pinned in `vendor/librime.lock`; its self-check gate (`--verify`) requires an `@rpath` install name, system-only linkage, and arm64 only.
2. **Swift** — `Package.swift` links `CRime` against `vendor-out/librime/lib`. Debug builds carry an rpath into `vendor-out/librime/lib`; release builds carry only `@executable_path/../Frameworks`.
3. **Tests** — `scripts/dev/test.sh` refuses to run unless `vendor-out/librime/.lock-sha256` matches `vendor/librime.lock` and the self-check gate passes, then runs `swift test` with the CommandLineTools `Testing.framework` search paths.
4. **Bundle** — [`scripts/build/bundle.sh`](../scripts/build/bundle.sh) builds the release executables, assembles and signs `NoemaIME.app` in staging, and publishes it atomically to `<out>/NoemaIME.app`. Icons are drawn in code by `Resources/IME/generate-icons.swift`. `Contents/Info.plist` is [`Resources/IME/Info.plist.in`](../Resources/IME/Info.plist.in) with version and build injected: IMKit keys, no privacy usage description.
5. **Signing** — `bundle.sh` signs inside-out (`librime.1.dylib`, `noema-rime-deployer`, `NoemaIME`, then the app), never with `--deep`, using the empty [`Resources/IME/NoemaIME.entitlements`](../Resources/IME/NoemaIME.entitlements). A certificate SHA-1 signs with Hardened Runtime and a secure timestamp; `-` signs ad-hoc without the runtime flag.
6. **Bundle verification** — [`scripts/build/verify-bundle.sh`](../scripts/build/verify-bundle.sh) checks the IMKit, zero-TCC, linkage, signing, and signed-entitlement contracts, then launches `noema-rime-deployer --version`, `NoemaIME --version`, and `NoemaIME --check-rime` (dyld resolves the bundled librime). Its header lists the checks.

## Governance gates

`scripts/governance/check.sh` runs four gates and fails if any fails; `--base <ref>` adds merge-base comparisons inside a git work tree and is ignored elsewhere.

| Gate | Enforces |
|---|---|
| `verify-doc-budgets.mjs` | Word ceilings for the documents listed in [`doc-budgets.manifest.json`](../scripts/governance/doc-budgets.manifest.json); with `--base`, no raised ceiling. |
| `verify-agent-notes.mjs` | Note paths `{lifecycle}/{class}/yyyy-mm-dd-topic.md`, the Status line, and the required sections per lifecycle; with `--base`, frozen `archived/` and `rejected/` notes. |
| `verify-md-links.mjs` | Every relative Markdown link and anchor resolves. |
| `check-imports.sh` | `Sources/NoemaIME`, `Sources/NoemaIMEShell`, and `Sources/NoemaUI` (each must exist) use no networking, audio, AX, event-tap, pasteboard, or screen-capture API; no Xcode-only artifact, XCTest, or `xcodebuild`; `CLAUDE.md` aliases; `.kiln/agent/config.yml` holds only `version` and `review`. |

Only `--base` reads `.git`, so the gates and build scripts run in git-less Kiln workspaces.

## Continuous integration

Kiln runs `.kiln/workflows/ci.yml` on `darwin/arm64` hosts for pushes and pull requests to `master`:

| Job | Needs | Runs |
|---|---|---|
| `governance` | — | `scripts/governance/check.sh` |
| `rime-deps` | — | `scripts/build/librime.sh`; publishes `vendor-out/librime/` as the `librime` output |
| `test` | `rime-deps` | `scripts/dev/test.sh` on the fetched librime and `Resources/rime-default` |
| `bundle` | `rime-deps` | `bundle.sh --sign -` and `verify-bundle.sh` on the fetched librime |

`.kiln/merge.yml` squash-merges once all four jobs and `ai-review` pass. `.kiln/agent/config.yml` enables only pull-request review (`.kiln/agent/review.md`). No CI job reads secrets or signing certificates.

## Seams

- **New Swift module** — add a target to `Package.swift`; bundled executables inherit the release-only `@executable_path/../Frameworks` rpath from `CRime`.
- **Candidate presentation** — implement `CandidatePresenting` and pass it to `InputSessionCoordinator` in `EngineHost`; `check-imports.sh` bounds what `NoemaUI` and the shell may import. `Info.plist.in` and `NoemaPaths` name the controller class and connection together.
- **New bundle content** — `bundle.sh` assembles it before signing; `verify-bundle.sh` gains the matching check.
- **librime inputs** — edit `vendor/librime.lock`; `rime-deps` rebuilds, and `test.sh` and `bundle.sh` refuse a stale `vendor-out/librime`.
- **Governance** — a new gate joins `scripts/governance/check.sh`; a new budgeted document joins `doc-budgets.manifest.json`.
