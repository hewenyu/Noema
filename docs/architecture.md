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
4. **Bundle** — `scripts/build/bundle.sh --sign <identity>` builds the release `NoemaIME` product (`--disable-local-rpath`), assembles the bundle in a staging directory, signs it, and publishes it atomically to `<out>/NoemaIME.app`:

```
NoemaIME.app/Contents/
  Info.plist                 Resources/IME/Info.plist.in with version and build injected
  MacOS/NoemaIME
  Frameworks/librime.1.dylib
  Resources/NoemaIME.icns    Resources/IME/generate-icons.swift + iconutil
  Resources/menu-icon.pdf    template image for the input menu
  Resources/opencc/          from vendor-out/librime/share/opencc
```

The icons are drawn in code with CoreGraphics and ImageIO; the repository holds no image files and no asset catalogs. `Info.plist.in` declares the IMKit keys (`InputMethodConnectionName`, `InputMethodServerControllerClass`, `ComponentInputModeDict`) and no `NS*UsageDescription` key.

5. **Signing** — `bundle.sh` signs inside-out, never with `--deep`: `Frameworks/librime.1.dylib`, then `MacOS/NoemaIME` with `Resources/IME/NoemaIME.entitlements` (an empty dictionary), then the bundle with the same entitlements. A 40-hex certificate SHA-1 signs with `--options runtime --timestamp`. `-` signs ad-hoc without the runtime flag, because Hardened Runtime library validation needs a Team ID to load the bundled dylib. Certificate names are rejected.
6. **Bundle verification** — `scripts/build/verify-bundle.sh [--require-signed] [bundle]` checks the layout, every required Info.plist key and the resources it names, arm64-only Mach-O files that pass the librime linkage allow-list, the dylib's `@rpath` install name and absence of `LC_RPATH`, an executable rpath of exactly `@executable_path/../Frameworks`, no `/opt/homebrew` string anywhere in the bundle, and `codesign --verify --strict` on each signed part. `--require-signed` additionally demands a certificate signature with Hardened Runtime, an Authority chain, and a Team ID. The last check launches `Contents/MacOS/NoemaIME --check-rime`, proving that dyld resolves the bundled librime and that every required module registers.

## Governance gates

`scripts/governance/check.sh` runs four gates and fails if any fails; `--base <ref>` adds merge-base comparisons inside a git work tree and is ignored elsewhere.

| Gate | Enforces |
|---|---|
| `verify-doc-budgets.mjs` | Word ceilings from `doc-budgets.manifest.json` for `AGENTS.md`, `.agents/notes/README.md`, `docs/AGENTS.md`, and this page; with `--base`, no raised ceiling. |
| `verify-agent-notes.mjs` | Note paths `{lifecycle}/{class}/yyyy-mm-dd-topic.md`, the Status line, and the required sections per lifecycle; with `--base`, frozen `archived/` and `rejected/` notes. |
| `verify-md-links.mjs` | Every relative Markdown link and anchor resolves. |
| `check-imports.sh` | `Sources/NoemaIME` imports no networking, audio, speech, AX, event-tap, pasteboard, or screen-capture API; no Xcode-only artifact, `import XCTest`, or `xcodebuild` call; `CLAUDE.md` and `docs/CLAUDE.md` link to their `AGENTS.md`; `.kiln/agent/config.yml` has no `development:` key. |

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
