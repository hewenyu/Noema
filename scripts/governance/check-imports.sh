#!/usr/bin/env bash
# Mechanical boundary checks for AGENTS.md standing rules 1, 5, and 6.
#
#   1. Sources/NoemaIME, Sources/NoemaIMEShell, and Sources/NoemaUI (the IMKit shell, its
#      library, and the candidate panel) import no networking, audio/speech, AX, event-tap,
#      pasteboard, or screen-capture frameworks and call none of those APIs (thin shell,
#      zero TCC). Each directory must exist and
#      hold source files. Carbon/HIToolbox and InputMethodKit stay allowed:
#      IsSecureEventInputEnabled() lives in Carbon.
#   2. No .xcassets/.xib/.storyboard/.xcodeproj/.xcworkspace anywhere, no `import XCTest`,
#      and no xcodebuild invocation in Sources, Tests, Resources, scripts, .kiln, or
#      Package.swift (Markdown prose is skipped). Pure CommandLineTools build.
#   3. CLAUDE.md and docs/CLAUDE.md are symlinks to their sibling AGENTS.md.
#   4. .kiln/agent/config.yml is a regular file holding exactly one YAML document whose
#      root mapping has exactly the keys `version` (= 1) and `review` (a non-empty mapping),
#      with no duplicate keys, aliases, merge keys, or custom tags, and no `development`
#      key or value at any depth (issue auto-development). A real YAML parser (Psych/libyaml
#      in /usr/bin/ruby) reads it, so quoting, escapes, indentation, flow style, `? ` keys,
#      and extra `---` documents cannot hide a key.
#
# Matching runs on a lexed copy of each file: comments become spaces (Swift block comments
# nest; string literals are kept), so Swift 6 access-level imports, attributes, `;`-joined
# statements, line breaks, and backquoted module names cannot hide an import.
# Swift `#/.../#` regex literals are skipped too, so a `/*` inside one opens no comment.
# Requires node >= 18 and macOS /usr/bin/ruby; uses find, never git, so it also runs in
# git-less Kiln workspaces. Exit 0 when clean, 1 on any violation, 2 when a tool is missing.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SELF="scripts/governance/check-imports.sh"
cd "${REPO_ROOT}"
command -v node >/dev/null || { echo "check-imports.sh: node (>= 18) is required" >&2; exit 2; }
# The system Ruby, never a PATH or Homebrew one: its bundled Psych is the YAML parser of record.
RUBY=/usr/bin/ruby
[[ -x "${RUBY}" ]] || { echo "check-imports.sh: ${RUBY} is required for the Kiln config check" >&2; exit 2; }

failures=0
bad() { printf '[check-imports] FAIL: %s\n' "$*" >&2; failures=$((failures + 1)); }

# Usage: node -e "${LEXER}" -- <ime|xcode>; reads NUL-separated paths from stdin.
# Prints one "path:line: text" hit per line; exits non-zero only on an internal error.
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
  /(?:^|[;&|(`$"'\s/=])xcodebuild(?=["';&|)`\s]|$)/gm,
];

function blankRange(out, from, to) {
  for (let k = from; k < to; k++) if (out[k] !== '\n' && out[k] !== '\r') out[k] = ' ';
}

// Swift: `//` and nested `/* */` comments become spaces; string literals (including
// multi-line, raw `#"..."#`, and `\(...)` interpolation) and extended regex literals
// (`#/.../#`, `##/.../##`, multi-line when `#/` ends its line) are skipped and kept verbatim.
function lexSwift(src) {
  const out = src.split('');
  const n = src.length;
  let i = 0;
  const rawStart = /#+"/y;
  const regexStart = /(#+)\/([ \t]*\r?\n)?/y;
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
      regexStart.lastIndex = i;
      const regex = c === '#' ? regexStart.exec(src) : null;
      if (regex) { i += regex[0].length; regexLiteral('/' + regex[1], regex[2] !== undefined); continue; }
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
  // Swift lexes a regex literal up to its closing delimiter, skipping `\x` escapes.
  function regexLiteral(close, multi) {
    while (i < n) {
      if (src[i] === '\\') { i += 2; continue; }
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

const [mode] = process.argv.slice(1);
if (mode === 'ime') for (const file of readPaths()) scan(file, IME_PATTERNS);
else if (mode === 'xcode') for (const file of readPaths()) scan(file, XCODE_PATTERNS);
else { console.error(`unknown mode: ${mode}`); process.exit(2); }
JS

# Usage: "${RUBY}" --disable-gems -e "${KILN_CHECK}" -- <config.yml>. Prints one
# "path:line: problem" hit per line; exits non-zero only on an internal error.
IFS= read -r -d '' KILN_CHECK <<'RUBY' || true
require 'yaml'

file = ARGV.fetch(0)
hits = []
hit = ->(line, problem) { hits << "#{file}:#{line}: #{problem}" }
ALLOWED = %w[version review].freeze

# Reject duplicate and non-scalar keys in every mapping; Psych keeps the last duplicate.
check_keys = lambda do |node, top|
  case node
  when Psych::Nodes::Mapping
    seen = {}
    node.children.each_slice(2) do |key, value|
      unless key.is_a?(Psych::Nodes::Scalar)
        hit.call(key.start_line + 1, 'mapping keys must be plain scalars')
        next
      end
      resolved = key.to_ruby
      hit.call(key.start_line + 1, "duplicate key #{resolved.inspect}") if seen.key?(resolved)
      seen[resolved] = true
      if top && !(resolved.is_a?(String) && ALLOWED.include?(resolved))
        hit.call(key.start_line + 1, "top-level key #{resolved.inspect} is not version or review")
      end
      check_keys.call(value, false)
    end
  when Psych::Nodes::Sequence
    node.children.each { |child| check_keys.call(child, false) }
  end
end

# Any key or value that mentions development, at any depth.
find_development = lambda do |value, where|
  case value
  when Hash then value.each { |k, v| find_development.call(k, where); find_development.call(v, "#{where}.#{k}") }
  when Array then value.each_with_index { |v, k| find_development.call(v, "#{where}[#{k}]") }
  else hit.call(1, "development in #{where}: #{value.inspect}") if value.to_s =~ /development/i
  end
end

begin
  src = File.binread(file).force_encoding(Encoding::UTF_8)
  raise ArgumentError, 'not valid UTF-8' unless src.valid_encoding?
  src = src.sub(/\A\uFEFF/, '')
  docs = Psych.parse_stream(src, filename: file).children
  if docs.size != 1
    hit.call(1, "must hold exactly one YAML document, found #{docs.size}")
  else
    # safe_load rejects aliases, custom tags, symbols, and other non-plain objects first,
    # so to_ruby on the AST below only ever builds plain scalars.
    config = Psych.safe_load(src, permitted_classes: [], permitted_symbols: [], aliases: false, filename: file)
    root = docs[0].root
    if !root.is_a?(Psych::Nodes::Mapping) || !config.is_a?(Hash)
      hit.call(1, 'the root must be a mapping')
    else
      check_keys.call(root, true)
      unless config.keys.all? { |k| k.is_a?(String) && ALLOWED.include?(k) }
        hit.call(1, "resolved top-level keys #{config.keys.inspect} are not exactly version and review")
      end
      v = config['version']
      hit.call(1, "version must be the integer 1, got #{v.inspect}") unless v.is_a?(Integer) && v == 1
      r = config['review']
      hit.call(1, 'review must be a non-empty mapping') unless r.is_a?(Hash) && !r.empty?
      find_development.call(config, 'root')
    end
  end
rescue Psych::SyntaxError, Psych::DisallowedClass, Psych::BadAlias, ArgumentError => e
  hit.call(e.respond_to?(:line) && e.line.to_i.positive? ? e.line : 1, "not a plain YAML config (#{e.class}: #{e.message.lines.first.to_s.strip})")
end
puts hits
RUBY

# Run "$@" (stdin passes through) and report each output line with the message in $1.
report_hits() {
  local message="$1" output hit
  shift
  if ! output="$("$@")"; then
    bad "checker failed: ${message}"
    return
  fi
  while IFS= read -r hit; do
    if [[ -n "${hit}" ]]; then bad "${message}: ${hit#./}"; fi
  done <<<"${output}"
}

# ---------------------------------------------------------------------------
# 1. NoemaIME, NoemaIMEShell, and NoemaUI stay a thin IMKit shell
# ---------------------------------------------------------------------------

IME_SOURCE_DIRS=(Sources/NoemaIME Sources/NoemaIMEShell Sources/NoemaUI)
for dir in "${IME_SOURCE_DIRS[@]}"; do
  if [[ ! -d "${dir}" || -L "${dir}" ]]; then
    bad "${dir} is missing or a symlink"
  elif [[ -z "$(find "${dir}" -type f \( -name '*.swift' -o -name '*.h' -o -name '*.c' -o -name '*.m' -o -name '*.mm' \) -print -quit)" ]]; then
    bad "${dir} has no source files to scan"
  else
    report_hits "${dir} must not use networking/audio/AX/pasteboard APIs (AGENTS.md rule 1)" \
      node -e "${LEXER}" -- ime < <(find "${dir}" -type f \( -name '*.swift' -o -name '*.h' -o -name '*.c' -o -name '*.m' -o -name '*.mm' \) -print0)
  fi
done

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
report_hits "XCTest/xcodebuild is not allowed (AGENTS.md rule 5)" \
  node -e "${LEXER}" -- xcode < <(find "${roots[@]}" -type f ! -name '*.md' ! -path "./${SELF}" -print0)

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
  report_hits "${KILN_CONFIG} must enable only CI and PR review (AGENTS.md rule 6)" \
    env -u RUBYOPT -u RUBYLIB "${RUBY}" --disable-gems -e "${KILN_CHECK}" -- "${KILN_CONFIG}"
fi

if (( failures > 0 )); then
  printf '[check-imports] %d violation(s)\n' "${failures}" >&2
  exit 1
fi
printf '[check-imports] ok: NoemaIME/NoemaIMEShell/NoemaUI imports, CLT-only artifacts, CLAUDE.md aliases, Kiln boundary\n'
