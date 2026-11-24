#!/usr/bin/env bash
# Mechanical boundary checks for AGENTS.md standing rules 1, 5, and 6.
#
#   1. Sources/NoemaIME imports no networking, audio/speech, AX, event-tap, pasteboard,
#      or screen-capture frameworks and calls none of those APIs (thin shell, zero TCC).
#      Carbon/HIToolbox and InputMethodKit stay allowed: IsSecureEventInputEnabled()
#      lives in Carbon.
#   2. No .xcassets/.xib/.storyboard/.xcodeproj/.xcworkspace anywhere, no `import XCTest`,
#      and no xcodebuild invocation in Sources, Tests, Resources, scripts, .kiln, or
#      Package.swift (Markdown prose is skipped). Pure CommandLineTools build.
#   3. CLAUDE.md and docs/CLAUDE.md are symlinks to their sibling AGENTS.md.
#   4. .kiln/agent/config.yml exists, has only the top-level keys `version` and `review`,
#      and contains no `development` key in any form (issue auto-development).
#
# Matching runs on a lexed copy of each file: comments become spaces (Swift block comments
# nest; string literals are kept), so Swift 6 access-level imports, attributes, `;`-joined
# statements, line breaks, and backquoted module names cannot hide an import.
# Requires node >= 18; uses find, never git, so it also runs in git-less Kiln workspaces.
# Exit 0 when clean, 1 on any violation, 2 when node is missing.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SELF="scripts/governance/check-imports.sh"
cd "${REPO_ROOT}"
command -v node >/dev/null || { echo "check-imports.sh: node (>= 18) is required" >&2; exit 2; }

failures=0
bad() { printf '[check-imports] FAIL: %s\n' "$*" >&2; failures=$((failures + 1)); }

# Usage: node -e "${LEXER}" -- <ime|xcode|kiln> [file]; ime/xcode read NUL-separated paths
# from stdin. Prints one "path:line: text" hit per line; exits non-zero only on an
# internal error.
IFS= read -r -d '' LEXER <<'JS' || true
'use strict';
const fs = require('fs');
const path = require('path');

const BANNED_MODULES = 'AVFoundation|AVFAudio|Speech|SoundAnalysis|CoreAudio|AudioToolbox|Network|CFNetwork|WebKit|ApplicationServices|HIServices|ScreenCaptureKit|Contacts|CoreLocation|EventKit|Photos';
const BANNED_SYMBOLS = '(?:NS)?URLSession|NSURLConnection|AXUIElement[A-Za-z]*|CGEvent\\.tapCreate|CGEventTap[A-Za-z]*|NSPasteboard[A-Za-z]*';
const ATTR = '@[A-Za-z_][A-Za-z0-9_]*(?:\\s*\\([^)]*\\))?\\s*';
const ACCESS = '(?:public|package|internal|fileprivate|private)\\s+';
const KIND = '(?:(?:typealias|struct|class|actor|enum|protocol|let|var|func)\\s+)?';
// A Swift import statement starts a line or follows `;`; attributes, access levels,
// the import kind, and the module may be split across lines.
const swiftImport = (mods) => new RegExp(
  `(?:^|;)[ \\t]*(?:${ATTR}|${ACCESS})*import\\s+${KIND}\`?(?:${mods})\`?(?![A-Za-z0-9_])`, 'gm');
const cImport = (mods) => new RegExp(`^[ \\t]*#[ \\t]*(?:import|include)[ \\t]*[<"](?:${mods})/`, 'gm');
const objcImport = (mods) => new RegExp(`^[ \\t]*@import\\s+(?:${mods})(?![A-Za-z0-9_])`, 'gm');

const IME_PATTERNS = [
  swiftImport(BANNED_MODULES), cImport(BANNED_MODULES), objcImport(BANNED_MODULES),
  new RegExp(`(?:^|[^A-Za-z0-9_])(?:${BANNED_SYMBOLS})(?![A-Za-z0-9_])`, 'gm'),
];
const XCODE_PATTERNS = [
  swiftImport('XCTest'),
  /^[ \t]*(?:#[ \t]*(?:import|include)[ \t]*[<"]|@import\s+)XCTest/gm,
  /(?:^|[;&|(`$"'\s/])xcodebuild(?=["';&|)`\s]|$)/gm,
];

function blankRange(out, from, to) {
  for (let k = from; k < to; k++) if (out[k] !== '\n' && out[k] !== '\r') out[k] = ' ';
}

// Swift: `//` and nested `/* */` comments become spaces; string literals (including
// multi-line, raw `#"..."#`, and `\(...)` interpolation) are skipped and kept verbatim.
function lexSwift(src) {
  const out = src.split('');
  const n = src.length;
  let i = 0;
  const rawStart = /#+"/y;
  function code(inInterpolation) {
    let depth = 0;
    while (i < n) {
      const c = src[i];
      if (c === '/' && src[i + 1] === '/') {
        const s = i; while (i < n && src[i] !== '\n') i++; blankRange(out, s, i); continue;
      }
      if (c === '/' && src[i + 1] === '*') {
        const s = i; let d = 0;
        while (i < n) {
          if (src[i] === '/' && src[i + 1] === '*') { d++; i += 2; }
          else if (src[i] === '*' && src[i + 1] === '/') { d--; i += 2; if (d === 0) break; }
          else i++;
        }
        blankRange(out, s, i); continue;
      }
      rawStart.lastIndex = i;
      if (c === '"' || (c === '#' && rawStart.test(src))) { string(); continue; }
      if (inInterpolation) {
        if (c === '(') depth++;
        else if (c === ')') { if (depth === 0) { i++; return; } depth--; }
      }
      i++;
    }
  }
  function string() {
    let hashes = 0;
    while (src[i] === '#') { hashes++; i++; }
    const multi = src.startsWith('"""', i);
    i += multi ? 3 : 1;
    const close = (multi ? '"""' : '"') + '#'.repeat(hashes);
    const escape = '\\' + '#'.repeat(hashes);
    while (i < n) {
      if (src.startsWith(escape, i)) {
        const j = i + escape.length;
        if (src[j] === '(') { i = j + 1; code(true); } else i = j + 1;
        continue;
      }
      if (src.startsWith(close, i)) { i += close.length; return; }
      if (!multi && src[i] === '\n') return;
      i++;
    }
  }
  code(false);
  return out.join('');
}

// C, Objective-C, and JavaScript: `//` and non-nesting `/* */` comments become spaces;
// '...', "...", and `...` literals are skipped and kept verbatim.
function lexC(src) {
  const out = src.split('');
  const n = src.length;
  let i = 0;
  while (i < n) {
    const c = src[i];
    if (c === '/' && src[i + 1] === '/') {
      const s = i; while (i < n && src[i] !== '\n') i++; blankRange(out, s, i); continue;
    }
    if (c === '/' && src[i + 1] === '*') {
      const s = i; const e = src.indexOf('*/', i + 2);
      i = e < 0 ? n : e + 2; blankRange(out, s, i); continue;
    }
    if (c === '"' || c === "'" || c === '`') {
      i++;
      while (i < n && src[i] !== c && (c === '`' || src[i] !== '\n')) i += src[i] === '\\' ? 2 : 1;
      i++; continue;
    }
    i++;
  }
  return out.join('');
}

// Shell, YAML, and other `#`-comment files: full-line comments become blank lines
// (C #import/#include directives stay).
function lexHash(src) {
  return src.split('\n').map((line) =>
    /^\s*#/.test(line) && !/^\s*#\s*(?:import|include)(?:[\s<"]|$)/.test(line) ? '' : line).join('\n');
}

function lex(file, src) {
  const ext = path.extname(file).toLowerCase();
  if (ext === '.swift') return lexSwift(src);
  if (['.c', '.h', '.m', '.mm', '.js', '.mjs', '.cjs', '.ts'].includes(ext)) return lexC(src);
  if (['.json', '.plist', '.in', '.entitlements', '.lock', '.xml'].includes(ext)) return src;
  return lexHash(src);
}

function scan(file, patterns) {
  const buffer = fs.readFileSync(file);
  if (buffer.includes(0)) return;
  const src = buffer.toString('utf8');
  const text = lex(file, src);
  const lines = src.split('\n');
  for (const pattern of patterns) {
    pattern.lastIndex = 0;
    for (const match of text.matchAll(pattern)) {
      // Report the line of the first non-separator character of the match.
      const offset = match[0].search(/[^\s;]/);
      const at = match.index + Math.max(offset, 0);
      const line = text.slice(0, at).split('\n').length;
      console.log(`${file}:${line}: ${lines[line - 1].trim()}`);
    }
  }
}

function readPaths() {
  return fs.readFileSync(0, 'utf8').split('\0').filter(Boolean);
}

// YAML: drop the BOM and `#` comments outside quoted scalars; keep line structure.
function stripYaml(src) {
  return src.replace(/^\uFEFF/, '').split(/\r?\n/).map((line) => {
    let quote = null;
    for (let k = 0; k < line.length; k++) {
      const c = line[k];
      if (quote) {
        if (quote === '"' && c === '\\') k++;
        else if (c === quote) quote = null;
      } else if (c === '"' || c === "'") quote = c;
      else if (c === '#' && (k === 0 || /\s/.test(line[k - 1]))) return line.slice(0, k);
    }
    return line;
  });
}

function checkKiln(file) {
  const allowed = new Set(['version', 'review']);
  const seen = new Set();
  stripYaml(fs.readFileSync(file, 'utf8')).forEach((line, index) => {
    const where = `${file}:${index + 1}: ${line.trim()}`;
    if (/development/i.test(line)) console.log(`${where} (a development key or value in any form)`);
    if (line.trim() === '' || /^[ \t]/.test(line) || line === '---' || line === '...') return;
    const key = /^(["']?)([A-Za-z_][A-Za-z0-9_-]*)\1[ \t]*:(?:[ \t]|$)/.exec(line);
    if (!key) console.log(`${where} (top level must be a block mapping of plain keys)`);
    else if (!allowed.has(key[2])) console.log(`${where} (top-level key '${key[2]}' is not version or review)`);
    else if (seen.has(key[2])) console.log(`${where} (duplicate top-level key '${key[2]}')`);
    else seen.add(key[2]);
  });
}

const [mode, arg] = process.argv.slice(1);
if (mode === 'ime') for (const file of readPaths()) scan(file, IME_PATTERNS);
else if (mode === 'xcode') for (const file of readPaths()) scan(file, XCODE_PATTERNS);
else if (mode === 'kiln') checkKiln(arg);
else { console.error(`unknown mode: ${mode}`); process.exit(2); }
JS

# Run the lexer in mode $1 (extra arguments follow; stdin passes through) and report
# each hit with the message in $2.
lexer_hits() {
  local mode="$1" message="$2" output hit
  shift 2
  if ! output="$(node -e "${LEXER}" -- "${mode}" "$@")"; then
    bad "check-imports lexer failed in ${mode} mode"
    return
  fi
  while IFS= read -r hit; do
    if [[ -n "${hit}" ]]; then bad "${message}: ${hit#./}"; fi
  done <<<"${output}"
}

# ---------------------------------------------------------------------------
# 1. NoemaIME stays a thin IMKit shell
# ---------------------------------------------------------------------------

if [[ ! -d Sources/NoemaIME ]]; then
  bad "Sources/NoemaIME is missing"
elif [[ -z "$(find Sources/NoemaIME -type f \( -name '*.swift' -o -name '*.h' -o -name '*.c' -o -name '*.m' -o -name '*.mm' \) -print -quit)" ]]; then
  bad "Sources/NoemaIME has no source files to scan"
else
  lexer_hits ime "NoemaIME must not use networking/audio/AX/pasteboard APIs (AGENTS.md rule 1)" \
    < <(find Sources/NoemaIME -type f \( -name '*.swift' -o -name '*.h' -o -name '*.c' -o -name '*.m' -o -name '*.mm' \) -print0)
fi

# ---------------------------------------------------------------------------
# 2. Pure CommandLineTools: no Xcode-only artifacts, XCTest, or xcodebuild
# ---------------------------------------------------------------------------

while IFS= read -r -d '' path; do
  bad "Xcode-only artifact is not allowed (AGENTS.md rule 5): ${path#./}"
done < <(find . \( -name .git -o -name .build -o -name .swiftpm -o -name vendor-out -o -name dist -o -name node_modules \) -prune \
  -o \( -name '*.xcassets' -o -name '*.xib' -o -name '*.storyboard' -o -name '*.xcodeproj' -o -name '*.xcworkspace' \) -print0)

roots=()
for root in ./Sources ./Tests ./Resources ./scripts ./.kiln ./Package.swift; do
  [[ -e "${root}" ]] && roots+=("${root}")
done
lexer_hits xcode "XCTest/xcodebuild is not allowed (AGENTS.md rule 5)" \
  < <(find "${roots[@]}" -type f ! -name '*.md' ! -path "./${SELF}" -print0)

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
if [[ ! -f "${KILN_CONFIG}" || -L "${KILN_CONFIG}" ]]; then
  bad "${KILN_CONFIG} is missing or a symlink (AGENTS.md rule 6)"
else
  lexer_hits kiln "${KILN_CONFIG} must enable only CI and PR review (AGENTS.md rule 6)" "${KILN_CONFIG}"
fi

if (( failures > 0 )); then
  printf '[check-imports] %d violation(s)\n' "${failures}" >&2
  exit 1
fi
printf '[check-imports] ok: NoemaIME imports, CLT-only artifacts, CLAUDE.md aliases, Kiln boundary\n'
