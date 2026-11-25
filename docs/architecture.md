# Noema architecture

Noema is a Chinese input method for macOS 26+ on Apple Silicon (arm64), built from a SwiftPM package with CommandLineTools only. This page maps the components, the build and packaging pipeline, the governance gates, and the seams where new parts attach. Rationale lives in the [Agent Notes](../.agents/notes/README.md); standing rules live in [AGENTS.md](../AGENTS.md).

## Components

| Component | Kind | Role |
|---|---|---|
| `librime.1.dylib` | Vendored C++ library | Rime engine with the `lua` and `octagram` plugins merged in; Boost, leveldb, marisa, OpenCC, yaml-cpp, and spdlog are linked statically. `install_name` is `@rpath/librime.1.dylib`. |
| `CRime` | C target | Bridge to `rime_api.h`. `noema_rime_get_api()` wraps `rime_get_api()` in `pthread_once`, so concurrent cold starts read one fully built API table; `noema_rime_engine_api_available()` checks every member `RimeEngine` calls. |
| `NoemaCore` | Swift library | Dependency-free domain types: `NoemaVersion`, `KeyEvent`, `VirtualKeyCode`, `NoemaError`, `UTF8OffsetConverter`, and the `TypingEngine` protocol with `CompositionState` and `KeyHandlingResult`. |
| `NoemaText` | Swift library | Text normalization. |
| `NoemaIPC` | Swift library | IPC envelope types. |
| `NoemaEngine` | Swift library | `RimeEngine`, the `TypingEngine` over in-process librime (see [Typing engine](#typing-engine)); `RimeKeyMapper`; `BootGuard`; `DeployManifest`, the hashed input and output inventory of a deployed `build/`; and the read-only `RimeRuntime` facade reporting the librime version and registration state of the required modules (`core`, `dict`, `gears`, `levers`, `lua`, `octagram`, `grammar`). |
| `Resources/rime-default` | Rime data | The built-in minimal pinyin schema `noema_pinyin` (`default.yaml`, `noema_pinyin.schema.yaml`, `noema_pinyin.dict.yaml`), plain UTF-8 YAML used as `shared_data_dir`. |
| `noema-cli` | Executable | Developer command line: `version`, `check-rime`. |
| `noema-rime-deployer` | Executable | The only process that runs librime's deployer. Given `--shared-dir`, `--user-dir`, `--staging-dir` (an empty real directory, not a symlink, distinct from the other two), `--log-dir`, and `--schema` (a plain name: no `/`, `..`, or NUL), it copies the user's top-level `*.custom.yaml` (each a regular file, read `O_NOFOLLOW` with a 16 MiB cap) into the staging directory, deploys there, requires non-empty `default.yaml`, schema, and `.table.bin`/`.prism.bin` of every dictionary the schema names (`translator`, `reverse_lookup`, and each `script_translator@<tag>`/`table_translator@<tag>`), loads the schema in a session, and writes `build/.noema-deploy-manifest.json`; any failure exits non-zero. Ships as `NoemaIME.app/Contents/MacOS/noema-rime-deployer`. |
| `NoemaIME` | Executable | The process inside `NoemaIME.app`. It links `NoemaCore` and `NoemaEngine` only, and answers `--version` (the packaged `CFBundleShortVersionString`, else `NoemaVersion.current`) and `--check-rime`; it contains no `InputMethodKit` controller. |

Module graph (arrows point at dependencies):

```
noema-cli ───────────┐
NoemaIME ────────────┼─> NoemaEngine ─> CRime ─> librime.1.dylib
noema-rime-deployer ─┤        │
                     └────────┴─> NoemaCore
NoemaText, NoemaIPC: standalone libraries
```

Tests use Swift Testing only. `NoemaCoreTests` cover `NoemaCore`, `NoemaIPC`, and `NoemaText`; `NoemaEngineTests` cover `RimeKeyMapper`, `BootGuard`, `DeployManifest` validation, and candidate-label resolution without librime. `CRimeTests` holds every test that initializes librime, nested under the one serialized suite `LibrimeSerializedTests`: the raw bridge (Lua and table translators on an inline schema) and `RimeEngine` end to end on `Resources/rime-default`, including every Safe Mode reason, failed and incomplete deployments, and a single-key latency benchmark (P95 under 2 ms). `CRimeTests` depends on `noema-rime-deployer`, so any `swift test` builds the deployer the engine spawns.

## Typing engine

`TypingEngine` is the synchronous, `@MainActor` boundary between the IMKit shell and an engine: `processKey(_:)` returns a `KeyHandlingResult`. The shell inserts its `committedText` first, then passes the key through when `handled` is false; both can happen for one key (without a punctuator, `,` after `nihao` commits "你好" and is still unhandled). `RimeEngine` implements it:

- **Key mapping** — `RimeKeyMapper` turns a `KeyEvent` into an X11 keysym and mask or `.passthrough`; its header lists the pass-through rules.
- **Boot** — claim the process-wide librime (one live `RimeEngine` per process; `RimeApi.setup` runs once), take the `user_data_dir` lock and arm the sentinel through `BootGuard`, prepare `build/` per `DeployPolicy`, initialize, open a session on `schemaID`, then disarm.
- **Deployment** — `build/` is trusted only when `DeployManifest.validated` passes: the manifest (at most 16 MiB) names `schemaID`, lists the required outputs with non-zero sizes, and equals a fresh inventory of `build/` exactly, so every output is a regular file with the recorded size and SHA-256 and nothing unlisted (no extra file, no symlink) is present. `deployIfNeeded` deploys when that fails or the recorded inputs (every file under `sharedDataDir`, recursively, and each top-level `*.custom.yaml`, with SHA-256) differ from the current ones, so edits, deletions, and renames all count; `forceDeploy` always deploys; `neverDeploy` enters Safe Mode instead. A deployment runs `noema-rime-deployer` (from `deployerURL`, else beside the main executable or the test bundle) with a 60-second timeout against `user_data_dir/.deploy-staging.<pid>.<uuid>`, re-validates the staged build and its inputs, then renames the old `build/` to `.build-old.<pid>.<uuid>`, the staged build to `build/`, and removes the old one, renaming it back if the second step fails. Any failure leaves `build/` unchanged (Safe Mode). An input the inventory cannot cover is a failure too: a `*.custom.yaml` that is not a regular file itself, or a symlink under `sharedDataDir` to anything but a regular file. When `build/` is missing, the next boot restores the `.build-old.*` that validates (else the newest), syncs `user_data_dir`, then removes the other leftovers; a failed restore keeps them all (Safe Mode).
- **Safe Mode** — any refusal or failure on the boot path sets `SafeModeReason` (`bootCrashLoop`, `bootGuardCorrupted`, `userDataDirLocked`, `userDataDirUnwritable`, `engineInitFailed`), releases librime, and answers every key with `handled: false` and `.safeMode`. `recoverFromSafeMode()` clears the sentinel under the lock and boots again.
- **State** — after every call the engine drains `RimeCommit` and rebuilds `CompositionState` from `RimeContext` and `RimeStatus`, freeing each; caret and selection are converted from librime's UTF-8 byte offsets to UTF-16 by `UTF8OffsetConverter`, and `generationID` strictly increases.

Rationale: [process model note](../.agents/notes/proposed/architecture/2026-11-23-process-model-and-permissions.md).

## Build pipeline

1. **librime** — `scripts/build/librime.sh` builds `vendor-out/librime/` (`lib/librime.1.dylib`, `include/`, `share/opencc/`, `.lock-sha256`) from the exact commits and Boost SHA256 pinned in `vendor/librime.lock`. Its self-check gate (`--verify`) requires the `@rpath` install name, an `otool -L` allow-list of `/usr/lib/` and `/System/Library/`, no `LC_RPATH`, and arm64 only. `--check-linkage-stdin` exposes the same allow-list to other scripts.
2. **Swift** — `Package.swift` links `CRime` against `vendor-out/librime/lib`. Debug builds carry an rpath into `vendor-out/librime/lib`; release builds carry only `@executable_path/../Frameworks`.
3. **Tests** — `scripts/dev/test.sh` refuses to run unless `vendor-out/librime/.lock-sha256` matches `vendor/librime.lock` and the self-check gate passes, then runs `swift test` with the CommandLineTools `Testing.framework` search paths.
4. **Bundle** — [`scripts/build/bundle.sh`](../scripts/build/bundle.sh) builds the release `NoemaIME` and `noema-rime-deployer` products, assembles `NoemaIME.app` in a staging directory next to the output, signs it, and publishes it atomically to `<out>/NoemaIME.app` under a per-output `flock` held outside `<out>`, so concurrent runs into one output publish one after another. The bundle holds both executables in `Contents/MacOS`, the bundled `librime.1.dylib` under `Contents/Frameworks`, the OpenCC data, `Resources/rime-default` under `Contents/Resources/rime-default`, and icons drawn in code by `Resources/IME/generate-icons.swift`; the repository holds no image files and no asset catalogs. `Contents/Info.plist` is [`Resources/IME/Info.plist.in`](../Resources/IME/Info.plist.in) with version and build injected; it declares the IMKit keys and no privacy usage description. `bundle.sh` owns the exact file inventory.
5. **Signing** — `bundle.sh` signs inside-out (`librime.1.dylib`, `noema-rime-deployer`, `NoemaIME`, then the app), never with `--deep`, using the empty [`Resources/IME/NoemaIME.entitlements`](../Resources/IME/NoemaIME.entitlements). A certificate SHA-1 signs with Hardened Runtime and a secure timestamp; `-` signs ad-hoc without the runtime flag, because library validation needs a Team ID to load the bundled dylib.
6. **Bundle verification** — [`scripts/build/verify-bundle.sh`](../scripts/build/verify-bundle.sh) checks the assembled bundle against the IMKit, zero-TCC, linkage, and signing contracts for both executables (arm64 only, one `LC_RPATH` of `@executable_path/../Frameworks`, `@rpath/librime.1.dylib`), including the entitlements actually signed in, launches `noema-rime-deployer --version`, and finishes by launching `Contents/MacOS/NoemaIME --version` (it must print the `Info.plist` version) and `--check-rime` to prove that dyld resolves the bundled librime and every required module registers. Its header lists the checks.

## Governance gates

`scripts/governance/check.sh` runs four gates and fails if any fails; `--base <ref>` adds merge-base comparisons inside a git work tree and is ignored elsewhere.

| Gate | Enforces |
|---|---|
| `verify-doc-budgets.mjs` | Word ceilings for the documents listed in [`doc-budgets.manifest.json`](../scripts/governance/doc-budgets.manifest.json); with `--base`, no raised ceiling. |
| `verify-agent-notes.mjs` | Note paths `{lifecycle}/{class}/yyyy-mm-dd-topic.md`, the Status line, and the required sections per lifecycle; with `--base`, frozen `archived/` and `rejected/` notes. |
| `verify-md-links.mjs` | Every relative Markdown link and anchor resolves. |
| `check-imports.sh` | Comment-aware scan: `Sources/NoemaIME` imports no networking, audio, speech, AX, event-tap, pasteboard, or screen-capture API; no Xcode-only artifact, `import XCTest`, or `xcodebuild` call; `CLAUDE.md` and `docs/CLAUDE.md` link to their `AGENTS.md`; `.kiln/agent/config.yml` holds only `version` and `review` and no `development` key. |

None of the gates or build scripts read `.git` except for the optional `--base` comparison, so they run in git-less Kiln workspaces.

## Continuous integration

Kiln runs `.kiln/workflows/ci.yml` on `darwin/arm64` hosts for pushes and pull requests to `master`:

| Job | Needs | Runs |
|---|---|---|
| `governance` | — | `scripts/governance/check.sh` |
| `rime-deps` | — | `scripts/build/librime.sh`; publishes `vendor-out/librime/` as the `librime` output |
| `test` | `rime-deps` | `scripts/dev/test.sh` on the fetched librime and `Resources/rime-default` |
| `bundle` | `rime-deps` | `bundle.sh --sign -` and `verify-bundle.sh` on the fetched librime |

`.kiln/merge.yml` squash-merges automatically once all four jobs and `ai-review` pass. `.kiln/agent/config.yml` enables only pull-request review, guided by `.kiln/agent/review.md`, which trusts instructions from the repository owner alone. No CI job reads secrets or signing certificates.

## Seams

- **New Swift module** — add a target to `Package.swift`; executables that ship inside a bundle (as `NoemaIME` and `noema-rime-deployer` do) depend on `NoemaEngine` for Rime access and inherit the release-only `@executable_path/../Frameworks` rpath from `CRime`.
- **Input method controller** — `Info.plist.in` names `NoemaInputController` as `InputMethodServerControllerClass` and `dev.noema.inputmethod.NoemaIME_Connection` as the connection; an IMKit controller in `Sources/NoemaIME` registers under those names and drives a `TypingEngine`. `check-imports.sh` bounds what that target may import.
- **New bundle content** — `bundle.sh` assembles it before signing; `verify-bundle.sh` gains the matching check.
- **librime inputs** — edit `vendor/librime.lock`; `rime-deps` rebuilds, and `test.sh` and `bundle.sh` refuse a stale `vendor-out/librime`.
- **Governance** — a new gate joins `scripts/governance/check.sh`; a new budgeted document joins `doc-budgets.manifest.json`.
