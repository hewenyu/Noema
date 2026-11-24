# Noema architecture

Noema is a Chinese input method for macOS 26+ on Apple Silicon (arm64), built from a SwiftPM package with CommandLineTools only. This page maps the components, the build and packaging pipeline, the governance gates, and the seams where new parts attach. Rationale lives in the [Agent Notes](../.agents/notes/README.md); standing rules live in [AGENTS.md](../AGENTS.md).

## Components

| Component | Kind | Role |
|---|---|---|
| `librime.1.dylib` | Vendored C++ library | Rime engine with the `lua` and `octagram` plugins merged in; Boost, leveldb, marisa, OpenCC, yaml-cpp, and spdlog are linked statically. `install_name` is `@rpath/librime.1.dylib`. |
| `CRime` | C target | Bridge to `rime_api.h`. `noema_rime_get_api()` wraps `rime_get_api()` in `pthread_once`, so concurrent cold starts read one fully built API table. |
| `NoemaCore` | Swift library | Dependency-free domain types: `NoemaVersion`, `KeyEvent`, `NoemaError`. |
| `NoemaText` | Swift library | Text normalization. |
| `NoemaIPC` | Swift library | IPC envelope types. |
| `NoemaEngine` | Swift library | Read-only `RimeRuntime` facade over `CRime`: librime version and registration state of the required modules (`core`, `dict`, `gears`, `levers`, `lua`, `octagram`, `grammar`). |
| `noema-cli` | Executable | Developer command line: `version`, `check-rime`. |
| `NoemaIME` | Executable | The process inside `NoemaIME.app`. It links `NoemaCore` and `NoemaEngine` only, and answers `--version` and `--check-rime`; it contains no `InputMethodKit` controller. |

Module graph (arrows point at dependencies):

```
noema-cli ──┐
            ├─> NoemaEngine ─> CRime ─> librime.1.dylib
NoemaIME ───┤        │
            └────────┴─> NoemaCore
NoemaText, NoemaIPC: standalone libraries
```

Tests use Swift Testing only. `NoemaCoreTests` cover `NoemaCore`, `NoemaIPC`, and `NoemaText`; `CRimeTests` drive the real librime through `CRime` and `NoemaEngine`, including Lua and table translators on an inline schema.

## Build pipeline

1. **librime** — `scripts/build/librime.sh` builds `vendor-out/librime/` (`lib/librime.1.dylib`, `include/`, `share/opencc/`, `.lock-sha256`) from the exact commits and Boost SHA256 pinned in `vendor/librime.lock`. Its self-check gate (`--verify`) requires the `@rpath` install name, an `otool -L` allow-list of `/usr/lib/` and `/System/Library/`, no `LC_RPATH`, and arm64 only. `--check-linkage-stdin` exposes the same allow-list to other scripts.
2. **Swift** — `Package.swift` links `CRime` against `vendor-out/librime/lib`. Debug builds carry an rpath into `vendor-out/librime/lib`; release builds carry only `@executable_path/../Frameworks`.
3. **Tests** — `scripts/dev/test.sh` refuses to run unless `vendor-out/librime/.lock-sha256` matches `vendor/librime.lock` and the self-check gate passes, then runs `swift test` with the CommandLineTools `Testing.framework` search paths.
4. **Bundle** — [`scripts/build/bundle.sh`](../scripts/build/bundle.sh) builds the release `NoemaIME` product, assembles `NoemaIME.app` in a staging directory next to the output, signs it, and publishes it atomically to `<out>/NoemaIME.app`. The bundle holds the executable, the bundled `librime.1.dylib` under `Contents/Frameworks`, the OpenCC data, and icons drawn in code by `Resources/IME/generate-icons.swift`; the repository holds no image files and no asset catalogs. `Contents/Info.plist` is [`Resources/IME/Info.plist.in`](../Resources/IME/Info.plist.in) with version and build injected; it declares the IMKit keys and no privacy usage description. `bundle.sh` owns the exact file inventory.
5. **Signing** — `bundle.sh` signs inside-out, never with `--deep`, using the empty [`Resources/IME/NoemaIME.entitlements`](../Resources/IME/NoemaIME.entitlements). A certificate SHA-1 signs with Hardened Runtime and a secure timestamp; `-` signs ad-hoc without the runtime flag, because library validation needs a Team ID to load the bundled dylib.
6. **Bundle verification** — [`scripts/build/verify-bundle.sh`](../scripts/build/verify-bundle.sh) checks the assembled bundle against the IMKit, zero-TCC, linkage, and signing contracts, including the entitlements actually signed in, and finishes by launching `Contents/MacOS/NoemaIME --check-rime` to prove that dyld resolves the bundled librime and every required module registers. Its header lists the checks.

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
| `test` | `rime-deps` | `scripts/dev/test.sh` on the fetched librime |
| `bundle` | `rime-deps` | `bundle.sh --sign -` and `verify-bundle.sh` on the fetched librime |

`.kiln/merge.yml` squash-merges automatically once all four jobs and `ai-review` pass. `.kiln/agent/config.yml` enables only pull-request review, guided by `.kiln/agent/review.md`, which trusts instructions from the repository owner alone. No CI job reads secrets or signing certificates.

## Seams

- **New Swift module** — add a target to `Package.swift`; executables that ship inside a bundle depend on `NoemaEngine` for Rime access and inherit the release-only `@executable_path/../Frameworks` rpath from `CRime`.
- **Input method controller** — `Info.plist.in` names `NoemaInputController` as `InputMethodServerControllerClass` and `dev.noema.inputmethod.NoemaIME_Connection` as the connection; an IMKit controller in `Sources/NoemaIME` registers under those names. `check-imports.sh` bounds what that target may import.
- **New bundle content** — `bundle.sh` assembles it before signing; `verify-bundle.sh` gains the matching check.
- **librime inputs** — edit `vendor/librime.lock`; `rime-deps` rebuilds, and `test.sh` and `bundle.sh` refuse a stale `vendor-out/librime`.
- **Governance** — a new gate joins `scripts/governance/check.sh`; a new budgeted document joins `doc-budgets.manifest.json`.
