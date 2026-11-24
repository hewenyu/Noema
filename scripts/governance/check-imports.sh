#!/usr/bin/env bash
# Mechanical boundary checks for AGENTS.md standing rules 1, 5, and 6.
#
#   1. Sources/NoemaIME imports no networking, audio/speech, AX, event-tap, pasteboard,
#      or screen-capture frameworks and calls none of those APIs (thin shell, zero TCC).
#      Carbon/HIToolbox stay allowed: IsSecureEventInputEnabled() lives there.
#   2. No .xcassets/.xib/.storyboard/.xcodeproj/.xcworkspace anywhere, no `import XCTest`,
#      and no xcodebuild invocation (pure CommandLineTools build).
#   3. CLAUDE.md and docs/CLAUDE.md are symlinks to their sibling AGENTS.md.
#   4. .kiln/agent/config.yml exists and enables no issue auto-development (`development:`).
#
# Uses only find and grep, never git, so it also runs in git-less Kiln workspaces.
# Exit 0 when clean, 1 on any violation.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SELF="scripts/governance/check-imports.sh"
cd "${REPO_ROOT}"

failures=0
bad() { printf '[check-imports] FAIL: %s\n' "$*" >&2; failures=$((failures + 1)); }

# Print "file:line:text" for lines of $1 matching ERE $2, skipping pure comment lines:
# `//` lines, and `#` lines other than C #import/#include directives.
scan() {
  local file="$1" pattern="$2"
  # Blank comment lines instead of dropping them, so grep -n keeps the real line numbers
  # and anchored patterns see the raw line text.
  awk '/^[[:space:]]*\/\// { print ""; next }
       /^[[:space:]]*#/ && !/^[[:space:]]*#[[:space:]]*(import|include)([[:space:]<"]|$)/ { print ""; next }
       { print }' "${file}" \
    | grep -nE -- "${pattern}" | awk -v prefix="${file}:" '{ print prefix $0 }' || true
}

# ---------------------------------------------------------------------------
# 1. NoemaIME stays a thin IMKit shell
# ---------------------------------------------------------------------------

BANNED_MODULES='AVFoundation|AVFAudio|Speech|SoundAnalysis|CoreAudio|AudioToolbox|Network|CFNetwork|WebKit|ApplicationServices|HIServices|ScreenCaptureKit|Contacts|CoreLocation|EventKit|Photos'
BANNED_SYMBOLS='(NS)?URLSession|NSURLConnection|AXUIElement[A-Za-z]*|CGEvent\.tapCreate|CGEventTap[A-Za-z]*|NSPasteboard[A-Za-z]*'
IME_PATTERNS=(
  # Swift: import M, import M.Sub, @_exported/@preconcurrency import M, import struct M.T
  "^[[:space:]]*(@[A-Za-z_]+[[:space:]]+)*import[[:space:]]+((typealias|struct|class|enum|protocol|let|var|func)[[:space:]]+)?(${BANNED_MODULES})([.;[:space:]]|$)"
  # C/Objective-C: #import <M/...>, #include "M/...", @import M;
  "^[[:space:]]*#[[:space:]]*(import|include)[[:space:]]*[<\"](${BANNED_MODULES})/"
  "^[[:space:]]*@import[[:space:]]+(${BANNED_MODULES})([.;[:space:]]|$)"
  # Direct API use, which AppKit and CoreGraphics can reach without an import above.
  "(^|[^A-Za-z0-9_])(${BANNED_SYMBOLS})([^A-Za-z0-9_]|$)"
)
if [[ ! -d Sources/NoemaIME ]]; then
  bad "Sources/NoemaIME is missing"
else
  ime_files=0
  while IFS= read -r -d '' file; do
    ime_files=$((ime_files + 1))
    for pattern in "${IME_PATTERNS[@]}"; do
      while IFS= read -r hit; do
        [[ -n "${hit}" ]] && bad "NoemaIME must not use networking/audio/AX/pasteboard APIs (AGENTS.md rule 1): ${hit}"
      done < <(scan "${file}" "${pattern}")
    done
  done < <(find Sources/NoemaIME -type f \( -name '*.swift' -o -name '*.h' -o -name '*.c' -o -name '*.m' -o -name '*.mm' \) -print0)
  (( ime_files > 0 )) || bad "Sources/NoemaIME has no source files to scan"
fi

# ---------------------------------------------------------------------------
# 2. Pure CommandLineTools: no Xcode-only artifacts, XCTest, or xcodebuild
# ---------------------------------------------------------------------------

while IFS= read -r -d '' path; do
  bad "Xcode-only artifact is not allowed (AGENTS.md rule 5): ${path#./}"
done < <(find . \( -name .git -o -name .build -o -name .swiftpm -o -name vendor-out -o -name dist -o -name node_modules \) -prune \
  -o \( -name '*.xcassets' -o -name '*.xib' -o -name '*.storyboard' -o -name '*.xcodeproj' -o -name '*.xcworkspace' \) -print0)

XCODE_PATTERNS=(
  "^[[:space:]]*(@[A-Za-z_]+[[:space:]]+)*import[[:space:]]+((typealias|struct|class|enum|protocol|let|var|func)[[:space:]]+)?XCTest([.;[:space:]]|$)"
  "^[[:space:]]*(#[[:space:]]*(import|include)[[:space:]]*[<\"]|@import[[:space:]]+)XCTest"
  "(^|[;&|(\`\$\"'[:space:]])xcodebuild([\"';&|)[:space:]]|$)"
)
while IFS= read -r -d '' file; do
  [[ "${file#./}" == "${SELF}" ]] && continue
  for pattern in "${XCODE_PATTERNS[@]}"; do
    while IFS= read -r hit; do
      [[ -n "${hit}" ]] && bad "XCTest/xcodebuild is not allowed (AGENTS.md rule 5): ${hit#./}"
    done < <(scan "${file}" "${pattern}")
  done
done < <(find ./Sources ./Tests ./scripts ./.kiln ./Package.swift -type f -print0 2>/dev/null)

# ---------------------------------------------------------------------------
# 3. Agent instruction aliases
# ---------------------------------------------------------------------------

for alias in CLAUDE.md docs/CLAUDE.md; do
  if [[ ! -L "${alias}" || "$(readlink "${alias}")" != "AGENTS.md" ]]; then
    bad "${alias} must be a symlink to AGENTS.md (ln -s AGENTS.md ${alias})"
  elif [[ ! -f "$(dirname "${alias}")/AGENTS.md" ]]; then
    bad "${alias} points at a missing $(dirname "${alias}")/AGENTS.md"
  fi
done

# ---------------------------------------------------------------------------
# 4. Public-repo Kiln boundary: no issue auto-development
# ---------------------------------------------------------------------------

KILN_CONFIG=.kiln/agent/config.yml
if [[ ! -f "${KILN_CONFIG}" ]]; then
  bad "${KILN_CONFIG} is missing (AGENTS.md rule 6)"
else
  while IFS= read -r hit; do
    [[ -n "${hit}" ]] && bad "${KILN_CONFIG} must not enable issue auto-development (AGENTS.md rule 6): line ${hit}"
  done < <(grep -nE '^["'"'"']?development["'"'"']?[[:space:]]*:' "${KILN_CONFIG}" || true)
fi

if (( failures > 0 )); then
  printf '[check-imports] %d violation(s)\n' "${failures}" >&2
  exit 1
fi
printf '[check-imports] ok: NoemaIME imports, CLT-only artifacts, CLAUDE.md aliases, Kiln boundary\n'
