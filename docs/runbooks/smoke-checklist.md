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

## 5. v-mode and emoji

In TextEdit unless noted:

- [ ] `v`: marked `v` and a 2-column menu of nine cells beside the caret; 语音输入, 翻译, 改写 dimmed; the candidate panel never shows at the same time.
- [ ] `v1+2` Space inserts `3`; `v=2+3` ↓ Return inserts `2+3=5`; `v8` `1` inserts today's date; `v3` `xx` `1` inserts 谢谢！; `v5` Tab switches symbol category.
- [ ] Arrow keys move through the grid (↓ from 7 or 8 lands on 9); clicking a cell or row selects it.
- [ ] `vv` inserts `v`; `vim` Return inserts `vim`; `lv` Space inserts 绿; `nv` Space inserts 女.
- [ ] `v` then Esc, a click elsewhere in the document, or ⌘-Tab away: the `v` disappears and nothing is inserted.
- [ ] `v4`: a HUD 语音输入将在 M3 推出 appears near the top of the screen for about two seconds without taking focus from TextEdit; `v2` opens the clipboard panel; `v9` opens Settings.
- [ ] Password field: `v` passes through as a plain character, no panel.
- [ ] `nihao`: 你好 first, 👋 second; Settings › 快速操作 › Emoji off removes 👋 on the next keystroke; on again restores it.

## 6. Clipboard history

With the launchd-managed `Noema.app` running, in TextEdit unless noted:

- [ ] Copy text: ⇧⌘V (or the menu bar 剪贴板历史…, or `v2`) shows the glass panel centered on the pointer's screen; TextEdit stays the active app and the search field has focus.
- [ ] Type `你好` and a Latin prefix; the list narrows; ↑/↓ move, Esc closes and TextEdit has focus again; a click outside closes the panel.
- [ ] Return pastes into TextEdit once Accessibility is granted (Settings › 快速操作 › 剪贴板历史 › 打开辅助功能设置…); without it a HUD 已复制到剪贴板，请按 ⌘V 粘贴 appears and nothing is typed.
- [ ] A pasted entry is not recorded again; ⌘K 固定 moves it to 已固定; 删除 removes it.
- [ ] Copy in a password field, from 1Password or Passwords, or a `sk-…` key: the first two never appear; the key appears masked until 显示内容.
- [ ] Copy a screenshot (⇧⌃⌘4): an image row with a thumbnail and its size in the inspector.
- [ ] `strings ~/Library/Application\ Support/Noema/clipboard/clipboard.sqlite* | grep <copied word>` finds nothing.
- [ ] Lock and unlock the screen: recording resumes; quit Noema from the menu and relaunch it: the history is intact.
