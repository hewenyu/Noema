# M1 smoke checklist

Run on a real Mac (macOS 26, Apple Silicon) before tagging a release that touches `NoemaIME`, `NoemaIMEShell`, or `NoemaUI`. CI cannot see a window server, IMKit clients, or TCC; this list can. Record failures as issues with the app, its version, and the step number.

## 1. Build, sign, install

- [ ] `scripts/build/librime.sh && scripts/dev/test.sh` passes.
- [ ] `scripts/build/bundle.sh --sign <SHA-1>` with a Developer ID certificate (`security find-identity -v -p codesigning`).
- [ ] `scripts/build/verify-bundle.sh --require-signed` passes.
- [ ] `swift build && .build/debug/noema-cli install` exits 0 and reloads the running `NoemaIME`.

## 2. Enable, zero TCC

- [ ] System Settings > Keyboard > Input Sources: add Noema; select it in a text field.
- [ ] No permission prompt appears while enabling, typing, or clicking the panel.
- [ ] System Settings > Privacy & Security: `NoemaIME` is absent from Accessibility, Input Monitoring, Screen & System Audio Recording, Microphone, and Full Disk Access.

## 3. Target apps

Type `nihao`, then select with Space, a number key, and a mouse click, in each app:

- [ ] **Terminal** — panel below the caret; commit inserts 你好.
- [ ] **VS Code** — panel follows the editor caret; two editor windows each keep their own panel position (cache keyed by `uniqueClientIdentifier`).
- [ ] **Chrome** — address bar and a page `<textarea>`; if Chrome reports no caret, the panel stays at the last valid position, never at the screen's bottom-left corner.
- [ ] **Safari** — address bar and a page text field.
- [ ] **Spotlight**, **Raycast**, or **Alfred** — the panel draws above the launcher window, and clicking a candidate does not dismiss the launcher.
- [ ] **Password field** (Safari login form, `sudo` in Terminal) — keys pass through, the panel is hidden, and no preedit or stale composition appears after leaving the field.

## 4. Appearance and interaction

- [ ] Light ↔ Dark (Control Center) while the panel is visible: text, highlight capsule, and chevron switch at once.
- [ ] Type `nihaoshijie` continuously: no flicker, the width only grows in 32 pt steps, and the panel never jumps from the screen origin.
- [ ] Emoji candidates (if the schema has them) sit vertically centered beside Han candidates.
- [ ] The chevron expands the page into a list (14 pt corners) and collapses it back to a capsule.
- [ ] Click a candidate: full selection commits; clicking the first candidate of a partial segment (`nihao`, ← ← →) leaves `你hao` composing with fresh candidates.
- [ ] Scroll on the panel pages forward and backward.
- [ ] Caret near the screen bottom or Dock: the panel flips above the caret.
- [ ] A second display left of or below the main one (negative coordinates): the panel stays on the caret's display.
- [ ] `defaults write dev.noema.inputmethod.NoemaIME InlinePreeditDisabledBundleIDs -array com.apple.Terminal`, then `noema-cli reload`: Terminal shows no marked text; the panel draws the preedit with its caret above a hairline. `defaults delete` the key afterwards.
- [ ] `NSGlassEffectView` backdrop by default; the `.visualEffect` fallback (set `backdropMode` in a debug build) shows a shadowed HUD backdrop with the same layout.
