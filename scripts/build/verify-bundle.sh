#!/usr/bin/env bash
# Verify assembled Noema bundles.
#
#   NoemaIME.app: layout, IMKit Info.plist keys, Mach-O linkage of MacOS/NoemaIME,
#     MacOS/noema-rime-deployer, and Frameworks/librime.1.dylib, code signatures (signing
#     Identifier dev.noema.inputmethod.NoemaIME) and empty signed entitlements, and real launches that report the packaged version, load
#     librime, and start the deployer.
#   Noema.app (the companion agent): layout, Info.plist (LSUIElement, identifiers, no usage
#     descriptions), Contents/Library/LaunchAgents/dev.noema.agent.plist (BundleProgram,
#     MachServices), arm64-only MacOS/NoemaAgent with system-only linkage, no librime, and
#     zero LC_RPATH, signatures (signing Identifier dev.noema.agent) and empty signed
#     entitlements, and real `--version` and
#     `--bogus` (exit 2) launches.
#
# Usage: scripts/build/verify-bundle.sh [--require-signed] [path]
#   path              a NoemaIME.app or Noema.app bundle, or a directory holding both
#                     (default dist, relative to the repository root)
#   --require-signed  also require a Developer ID signature: not ad-hoc, Hardened
#                     Runtime, an Authority chain, and a Team ID on every signed part
#
# Exit 0 when every check passes, 1 when any fails, 2 on usage errors.
# Never reads this repository's .git, so it also works in exported (git-less) trees.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

failures=0
log() { printf '[verify-bundle] %s\n' "$*" >&2; }
bad() { printf '[verify-bundle] FAIL: %s\n' "$*" >&2; failures=$((failures + 1)); }
usage_error() { printf '[verify-bundle] error: %s\n' "$*" >&2; exit 2; }

REQUIRE_SIGNED=0
TARGET=""
TARGET_GIVEN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --require-signed) REQUIRE_SIGNED=1; shift ;;
    -h | --help) sed -n '2,21p' "$0"; exit 0 ;;
    -*) usage_error "unknown option: $1" ;;
    *)
      (( ! TARGET_GIVEN )) || usage_error "only one path is accepted"
      [[ -n "$1" ]] || usage_error "path must not be empty"
      TARGET_GIVEN=1; TARGET="$1"; shift ;;
  esac
done
(( TARGET_GIVEN )) || TARGET="${REPO_ROOT}/dist"
while [[ "${TARGET}" != "/" && "${TARGET}" == */ ]]; do TARGET="${TARGET%/}"; done
[[ "${TARGET}" != "/" ]] || usage_error "path must not be /"

PYTHON3="$(xcrun -f python3 2>/dev/null || command -v python3)" || usage_error "python3 not found (xcode-select --install)"
CLEAN_ENV=(env -u DYLD_LIBRARY_PATH -u DYLD_FALLBACK_LIBRARY_PATH -u DYLD_FRAMEWORK_PATH -u DYLD_INSERT_LIBRARIES)

# ---------------------------------------------------------------------------
# Shared checks
# ---------------------------------------------------------------------------

rpaths_of() {
  otool -l "$1" | awk '/cmd LC_RPATH/ {getline; getline; sub(/^[[:space:]]+path /, ""); sub(/ \(offset [0-9]+\)$/, ""); print}'
}

# Shipped bundles carry no Homebrew paths anywhere, not just in load commands.
check_no_homebrew() {
  local hits
  hits="$(grep -rlF /opt/homebrew "$1" 2>/dev/null || true)"
  [[ -z "${hits}" ]] || bad "bundle contains /opt/homebrew strings in: ${hits//$'\n'/, }"
}

# check_identifier <expected> <signed part>...: each part's signing identifier is exactly
# <expected>, the identifier the peer's IPC policy pins (PeerIdentityPolicy).
check_identifier() {
  local expected="$1"; shift
  local target identifier
  for target in "$@"; do
    identifier="$(codesign -dvv "${target}" 2>&1 | sed -n 's/^Identifier=//p' || true)"
    [[ "${identifier}" == "${expected}" ]] \
      || bad "${target##*/}: signing Identifier is '${identifier:-missing}', expected '${expected}' (IPC peer pinning)"
  done
}

# check_signatures <app> <signed part>...: each part verifies strictly, and its signature
# kind fits --require-signed (or, ad-hoc, carries no runtime flag).
check_signatures() {
  local app="$1"; shift
  local target name details team
  codesign --verify --strict --deep "${app}" || bad "codesign --verify --strict --deep failed for ${app##*/}"
  for target in "$@"; do
    name="${target#"${app}"}"; name="${name#/Contents/}"; name="${name:-${app##*/}}"
    [[ "${target}" == "${app}" ]] || codesign --verify --strict "${target}" || bad "codesign --verify failed for ${name}"
    details="$(codesign -dvv "${target}" 2>&1 || true)"
    if (( REQUIRE_SIGNED )); then
      grep -q '^Signature=adhoc' <<<"${details}" && bad "${name}: ad-hoc signature, but --require-signed needs a certificate"
      grep -Eq '^CodeDirectory .*flags=.*runtime' <<<"${details}" || bad "${name}: Hardened Runtime flag is missing"
      grep -q '^Authority=' <<<"${details}" || bad "${name}: no signing Authority"
      team="$(sed -n 's/^TeamIdentifier=//p' <<<"${details}")"
      [[ -n "${team}" && "${team}" != "not set" ]] || bad "${name}: TeamIdentifier is '${team:-missing}'"
    elif grep -q '^Signature=adhoc' <<<"${details}" && grep -Eq '^CodeDirectory .*flags=.*runtime' <<<"${details}"; then
      # Without a Team ID, library validation makes dyld refuse the bundled librime.
      bad "${name}: ad-hoc signature with Hardened Runtime; sign ad-hoc without --options runtime"
    fi
  done
}

# check_entitlements <app> <signed part>...: the entitlements actually signed in, not the
# repository file: zero network, zero TCC, no library-validation opt-out. Absent or an
# empty dictionary passes; any key fails.
check_entitlements() {
  local app="$1"; shift
  local target name signed
  for target in "$@"; do
    name="${target#"${app}"}"; name="${name#/Contents/}"; name="${name:-${app##*/}}"
    if ! signed="$(codesign -d --entitlements - --xml "${target}" 2>/dev/null)"; then
      bad "${name}: cannot read the signed entitlements"
      continue
    fi
    printf '%s' "${signed}" | "${PYTHON3}" -I -c '
import plistlib, sys
data = sys.stdin.buffer.read()
if not data.strip():
    sys.exit(0)
try:
    entitlements = plistlib.loads(data)
except Exception as error:
    sys.exit(f"[verify-bundle] FAIL: signed entitlements are not a plist: {error}")
if not isinstance(entitlements, dict) or entitlements:
    sys.exit(f"[verify-bundle] FAIL: signed entitlements must be an empty dictionary, got {entitlements!r}")
' || bad "${name}: signed entitlements are not empty (zero network, zero TCC, no disable-library-validation)"
  done
}

check_info_placeholders() {
  plutil -lint -s "$1" || bad "${1##*/Contents/} is not a valid plist"
  if grep -q '\${NOEMA_' "$1"; then
    bad "Contents/Info.plist has unreplaced \${NOEMA_*} placeholders"
  fi
}

# ---------------------------------------------------------------------------
# NoemaIME.app
# ---------------------------------------------------------------------------

verify_ime() {
  local APP="$1"
  local CONTENTS="${APP}/Contents"
  local INFO="${CONTENTS}/Info.plist"
  local EXE="${CONTENTS}/MacOS/NoemaIME"
  local DEPLOYER="${CONTENTS}/MacOS/noema-rime-deployer"
  local DYLIB="${CONTENTS}/Frameworks/librime.1.dylib"
  local ENTITLEMENTS="${REPO_ROOT}/Resources/IME/NoemaIME.entitlements"
  local start_failures=${failures} file macho name archs dylib_id dylib_rpaths exe_rpaths status

  # 1. Layout
  for file in "${INFO}" "${EXE}" "${DEPLOYER}" "${DYLIB}" "${CONTENTS}/Resources/NoemaIME.icns" "${CONTENTS}/Resources/menu-icon.pdf"; do
    [[ -f "${file}" && ! -L "${file}" ]] || bad "missing regular file: ${file#"${APP}/"}"
  done
  [[ -x "${EXE}" ]] || bad "Contents/MacOS/NoemaIME is not executable"
  [[ -x "${DEPLOYER}" ]] || bad "Contents/MacOS/noema-rime-deployer is not executable"
  [[ -x "${DYLIB}" ]] || bad "Contents/Frameworks/librime.1.dylib is not executable"
  if [[ ! -d "${CONTENTS}/Resources/opencc" || -z "$(ls -A "${CONTENTS}/Resources/opencc" 2>/dev/null)" ]]; then
    bad "Contents/Resources/opencc is missing or empty"
  fi
  # The built-in Rime schema that RimeEngine loads as shared_data_dir.
  for file in default.yaml noema_pinyin.schema.yaml noema_pinyin.dict.yaml; do
    [[ -f "${CONTENTS}/Resources/rime-default/${file}" && ! -L "${CONTENTS}/Resources/rime-default/${file}" ]] \
      || bad "missing regular file: Contents/Resources/rime-default/${file}"
  done
  if (( failures > start_failures )); then
    log "${APP}: layout is incomplete, skipping its remaining checks"
    return
  fi

  # 2-3. Info.plist and entitlements
  check_info_placeholders "${INFO}"
  if [[ -f "${ENTITLEMENTS}" ]]; then
    plutil -lint -s "${ENTITLEMENTS}" || bad "Resources/IME/NoemaIME.entitlements is not a valid plist"
  fi

  "${PYTHON3}" -I - "${INFO}" "${CONTENTS}/Resources" <<'PY' || bad "Contents/Info.plist fails the IMKit key checks above"
import os, plistlib, re, sys

info_path, resources = sys.argv[1], sys.argv[2]
with open(info_path, "rb") as handle:
    info = plistlib.load(handle)
problems = []

def expect(condition, message):
    if not condition:
        problems.append(message)

def nonempty_string(value):
    return isinstance(value, str) and value.strip() != ""

bundle_id = info.get("CFBundleIdentifier")
expect(nonempty_string(bundle_id) and ".inputmethod." in bundle_id,
       f"CFBundleIdentifier must contain '.inputmethod.', got {bundle_id!r}")
expect(info.get("CFBundleExecutable") == "NoemaIME", f"CFBundleExecutable must be NoemaIME, got {info.get('CFBundleExecutable')!r}")
expect(info.get("CFBundlePackageType") == "APPL", f"CFBundlePackageType must be APPL, got {info.get('CFBundlePackageType')!r}")
expect(info.get("InputMethodServerControllerClass") == "NoemaInputController",
       f"InputMethodServerControllerClass must be NoemaInputController, got {info.get('InputMethodServerControllerClass')!r}")
expect(nonempty_string(info.get("InputMethodConnectionName")), "InputMethodConnectionName must be a non-empty string")
expect(info.get("LSBackgroundOnly") is True, f"LSBackgroundOnly must be true, got {info.get('LSBackgroundOnly')!r}")
expect(info.get("NSPrincipalClass") == "NSApplication", f"NSPrincipalClass must be NSApplication, got {info.get('NSPrincipalClass')!r}")
expect(info.get("LSMinimumSystemVersion") == "26.0", f"LSMinimumSystemVersion must be '26.0', got {info.get('LSMinimumSystemVersion')!r}")
expect(info.get("TISIconIsTemplate") is True, f"TISIconIsTemplate must be true, got {info.get('TISIconIsTemplate')!r}")
expect(nonempty_string(info.get("CFBundleShortVersionString")), "CFBundleShortVersionString must be non-empty")
expect(nonempty_string(info.get("CFBundleVersion")), "CFBundleVersion must be non-empty")

modes = info.get("ComponentInputModeDict", {}).get("tsInputModeListKey") if isinstance(info.get("ComponentInputModeDict"), dict) else None
expect(isinstance(modes, dict) and len(modes) > 0, "ComponentInputModeDict.tsInputModeListKey must be a non-empty dictionary")

def resource_exists(key, name, default_extension=""):
    if not nonempty_string(name):
        problems.append(f"{key} must name a resource file, got {name!r}")
        return
    if default_extension and not os.path.splitext(name)[1]:
        name += default_extension
    # A bare relative name inside Contents/Resources: no absolute path, no `..`, no escape.
    if os.path.isabs(name) or ".." in name.replace("\\", "/").split("/"):
        problems.append(f"{key} must be a relative path inside Contents/Resources, got {name!r}")
        return
    path = os.path.join(resources, name)
    root = os.path.realpath(resources)
    if os.path.commonpath([root, os.path.realpath(path)]) != root:
        problems.append(f"{key} resolves outside Contents/Resources: {name!r}")
        return
    expect(os.path.isfile(path) and not os.path.islink(path), f"{key} names Contents/Resources/{name}, which does not exist")

resource_exists("tsInputMethodIconFileKey", info.get("tsInputMethodIconFileKey"))
resource_exists("CFBundleIconFile", info.get("CFBundleIconFile"), ".icns")
if isinstance(modes, dict):
    for mode_id, mode in modes.items():
        if isinstance(mode, dict) and "tsInputModeMenuIconFileKey" in mode:
            resource_exists(f"{mode_id}.tsInputModeMenuIconFileKey", mode["tsInputModeMenuIconFileKey"])

# Zero TCC: no privacy usage descriptions, no nib.
usage = sorted(key for key in info if re.fullmatch(r"NS\w*UsageDescription", key))
expect(not usage, f"Info.plist must declare no NS*UsageDescription keys (zero TCC), found {usage}")
expect("NSMainNibFile" not in info, "Info.plist must not declare NSMainNibFile (no .xib/.nib)")

for problem in problems:
    print(f"[verify-bundle] FAIL: {problem}", file=sys.stderr)
sys.exit(1 if problems else 0)
PY

  # 4. Mach-O gates
  for macho in "${EXE}" "${DEPLOYER}" "${DYLIB}"; do
    name="${macho#"${CONTENTS}/"}"
    archs="$(lipo -archs "${macho}" 2>/dev/null || true)"
    [[ "${archs}" == "arm64" ]] || bad "${name}: architectures are '${archs}', expected arm64 only"
    otool -L "${macho}" | "${SCRIPT_DIR}/librime.sh" --check-linkage-stdin || bad "${name}: otool -L linkage gate failed"
  done
  for macho in "${EXE}" "${DEPLOYER}"; do
    otool -L "${macho}" | grep -Fq '@rpath/librime.1.dylib' \
      || bad "${macho#"${CONTENTS}/"} does not link @rpath/librime.1.dylib"
  done
  dylib_id="$(otool -D "${DYLIB}" | sed -n '2p')"
  [[ "${dylib_id}" == "@rpath/librime.1.dylib" ]] || bad "Frameworks/librime.1.dylib install_name is '${dylib_id}', expected @rpath/librime.1.dylib"
  dylib_rpaths="$(rpaths_of "${DYLIB}")"
  [[ -z "${dylib_rpaths}" ]] || bad "Frameworks/librime.1.dylib must carry no LC_RPATH, found: ${dylib_rpaths//$'\n'/, }"
  # Each executable carries exactly one LC_RPATH, the bundle's Frameworks directory.
  for macho in "${EXE}" "${DEPLOYER}"; do
    name="${macho#"${CONTENTS}/"}"
    exe_rpaths="$(rpaths_of "${macho}")"
    [[ "${exe_rpaths}" == "@executable_path/../Frameworks" ]] \
      || bad "${name} LC_RPATH is '${exe_rpaths//$'\n'/, }'; expected exactly @executable_path/../Frameworks"
  done
  check_no_homebrew "${APP}"

  # 5. Signatures (inside-out; the bundle check is --deep only for verification)
  check_signatures "${APP}" "${APP}" "${EXE}" "${DEPLOYER}" "${DYLIB}"
  check_identifier dev.noema.inputmethod.NoemaIME "${APP}" "${EXE}"
  check_entitlements "${APP}" "${APP}" "${EXE}" "${DEPLOYER}"

  # 6. Real launch: --version must report the packaged version, dyld must resolve the
  #    bundled librime for NoemaIME and noema-rime-deployer, and every module must register
  local expected_version version_output probe deployer_output deployer_version_re
  expected_version="$(plutil -extract CFBundleShortVersionString raw -o - "${INFO}" 2>/dev/null || true)"
  if version_output="$("${CLEAN_ENV[@]}" "${EXE}" --version 2>&1)"; then
    [[ -n "${expected_version}" && "${version_output}" == "NoemaIME ${expected_version}" ]] \
      || bad "MacOS/NoemaIME --version printed '${version_output}', expected 'NoemaIME ${expected_version}' from CFBundleShortVersionString"
  else
    status=$?
    bad "MacOS/NoemaIME --version exited ${status}: ${version_output}"
  fi

  if probe="$("${CLEAN_ENV[@]}" "${EXE}" --check-rime 2>&1)"; then
    printf '%s\n' "${probe}" | sed 's/^/[verify-bundle]   /' >&2
  else
    status=$?
    printf '%s\n' "${probe}" | sed 's/^/[verify-bundle]   /' >&2
    bad "MacOS/NoemaIME --check-rime exited ${status}"
  fi

  if deployer_output="$("${CLEAN_ENV[@]}" "${DEPLOYER}" --version 2>&1)"; then
    deployer_version_re='^noema-rime-deployer [0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$'
    [[ "${deployer_output}" != *$'\n'* && "${deployer_output}" =~ ${deployer_version_re} ]] \
      || bad "MacOS/noema-rime-deployer --version printed '${deployer_output}'"
  else
    status=$?
    bad "MacOS/noema-rime-deployer --version exited ${status}: ${deployer_output}"
  fi
}

# ---------------------------------------------------------------------------
# Noema.app
# ---------------------------------------------------------------------------

verify_agent() {
  local APP="$1"
  local CONTENTS="${APP}/Contents"
  local INFO="${CONTENTS}/Info.plist"
  local EXE="${CONTENTS}/MacOS/NoemaAgent"
  local LAUNCH_AGENT="${CONTENTS}/Library/LaunchAgents/dev.noema.agent.plist"
  local ENTITLEMENTS="${REPO_ROOT}/Resources/Agent/NoemaAgent.entitlements"
  local start_failures=${failures} file archs exe_rpaths status

  # 1. Layout: no Frameworks, no librime.
  for file in "${INFO}" "${EXE}" "${LAUNCH_AGENT}" "${CONTENTS}/Resources/Noema.icns" "${CONTENTS}/Resources/menu-icon.pdf"; do
    [[ -f "${file}" && ! -L "${file}" ]] || bad "missing regular file: ${file#"${APP}/"}"
  done
  [[ -x "${EXE}" ]] || bad "Contents/MacOS/NoemaAgent is not executable"
  [[ ! -e "${CONTENTS}/Frameworks" ]] || bad "Noema.app must not contain Contents/Frameworks (no librime in the agent)"
  if (( failures > start_failures )); then
    log "${APP}: layout is incomplete, skipping its remaining checks"
    return
  fi

  # 2-3. Info.plist, LaunchAgent plist, entitlements
  check_info_placeholders "${INFO}"
  plutil -lint -s "${LAUNCH_AGENT}" || bad "Contents/Library/LaunchAgents/dev.noema.agent.plist is not a valid plist"
  if [[ -f "${ENTITLEMENTS}" ]]; then
    plutil -lint -s "${ENTITLEMENTS}" || bad "Resources/Agent/NoemaAgent.entitlements is not a valid plist"
  fi
  "${PYTHON3}" -I - "${INFO}" "${LAUNCH_AGENT}" "${CONTENTS}/Resources" <<'PY' || bad "Noema.app plists fail the agent key checks above"
import os, plistlib, re, sys

info_path, agent_path, resources = sys.argv[1:4]
with open(info_path, "rb") as handle:
    info = plistlib.load(handle)
with open(agent_path, "rb") as handle:
    agent = plistlib.load(handle)
problems = []

def expect(condition, message):
    if not condition:
        problems.append(message)

def nonempty_string(value):
    return isinstance(value, str) and value.strip() != ""

expect(info.get("CFBundleIdentifier") == "dev.noema.agent", f"CFBundleIdentifier must be dev.noema.agent, got {info.get('CFBundleIdentifier')!r}")
expect(info.get("CFBundleExecutable") == "NoemaAgent", f"CFBundleExecutable must be NoemaAgent, got {info.get('CFBundleExecutable')!r}")
expect(info.get("CFBundlePackageType") == "APPL", f"CFBundlePackageType must be APPL, got {info.get('CFBundlePackageType')!r}")
expect(info.get("LSUIElement") is True, f"LSUIElement must be true, got {info.get('LSUIElement')!r}")
expect(info.get("LSMinimumSystemVersion") == "26.0", f"LSMinimumSystemVersion must be '26.0', got {info.get('LSMinimumSystemVersion')!r}")
expect(nonempty_string(info.get("CFBundleShortVersionString")), "CFBundleShortVersionString must be non-empty")
expect(nonempty_string(info.get("CFBundleVersion")), "CFBundleVersion must be non-empty")
icon = info.get("CFBundleIconFile")
expect(nonempty_string(icon) and "/" not in icon and os.path.isfile(os.path.join(resources, icon if icon.endswith(".icns") else icon + ".icns")),
       f"CFBundleIconFile must name an .icns in Contents/Resources, got {icon!r}")
usage = sorted(key for key in info if re.fullmatch(r"NS\w*UsageDescription", key))
expect(not usage, f"Info.plist declares {usage}: the M2 skeleton requests no TCC permission")
expect("NSMainNibFile" not in info, "Info.plist must not declare NSMainNibFile (no .xib/.nib)")

expect(agent.get("Label") == "dev.noema.agent", f"LaunchAgent Label must be dev.noema.agent, got {agent.get('Label')!r}")
expect(agent.get("BundleProgram") == "Contents/MacOS/NoemaAgent",
       f"LaunchAgent BundleProgram must be Contents/MacOS/NoemaAgent, got {agent.get('BundleProgram')!r}")
services = agent.get("MachServices")
expect(isinstance(services, dict) and services.get("dev.noema.agent.ipc") is True,
       f"LaunchAgent MachServices must map dev.noema.agent.ipc to true, got {services!r}")
expect(agent.get("AssociatedBundleIdentifiers") == ["dev.noema.agent"],
       f"LaunchAgent AssociatedBundleIdentifiers must be ['dev.noema.agent'], got {agent.get('AssociatedBundleIdentifiers')!r}")
expect("Program" not in agent and "ProgramArguments" not in agent, "LaunchAgent must use BundleProgram, not Program/ProgramArguments")

for problem in problems:
    print(f"[verify-bundle] FAIL: {problem}", file=sys.stderr)
sys.exit(1 if problems else 0)
PY

  # 4. Mach-O gates: arm64, system-only linkage, no librime, zero LC_RPATH.
  archs="$(lipo -archs "${EXE}" 2>/dev/null || true)"
  [[ "${archs}" == "arm64" ]] || bad "MacOS/NoemaAgent: architectures are '${archs}', expected arm64 only"
  otool -L "${EXE}" | "${SCRIPT_DIR}/librime.sh" --check-linkage-stdin || bad "MacOS/NoemaAgent: otool -L linkage gate failed"
  ! otool -L "${EXE}" | grep -q 'librime' || bad "MacOS/NoemaAgent links librime; the agent must not"
  exe_rpaths="$(rpaths_of "${EXE}")"
  [[ -z "${exe_rpaths}" ]] || bad "MacOS/NoemaAgent must carry no LC_RPATH, found: ${exe_rpaths//$'\n'/, }"
  check_no_homebrew "${APP}"

  # 5. Signatures
  check_signatures "${APP}" "${APP}" "${EXE}"
  check_identifier dev.noema.agent "${APP}" "${EXE}"
  check_entitlements "${APP}" "${APP}" "${EXE}"

  # 6. Real launch: --version is answered before AppKit; an unknown option exits 2.
  local expected_version version_output bogus_output
  expected_version="$(plutil -extract CFBundleShortVersionString raw -o - "${INFO}" 2>/dev/null || true)"
  if version_output="$("${CLEAN_ENV[@]}" "${EXE}" --version 2>&1)"; then
    [[ -n "${expected_version}" && "${version_output}" == "NoemaAgent ${expected_version}" ]] \
      || bad "MacOS/NoemaAgent --version printed '${version_output}', expected 'NoemaAgent ${expected_version}'"
  else
    status=$?
    bad "MacOS/NoemaAgent --version exited ${status}: ${version_output}"
  fi
  status=0
  bogus_output="$("${CLEAN_ENV[@]}" "${EXE}" --bogus 2>&1)" || status=$?
  [[ "${status}" == 2 ]] || bad "MacOS/NoemaAgent --bogus exited ${status}, expected 2: ${bogus_output}"
}

# ---------------------------------------------------------------------------
# Dispatch: one bundle, or both in a directory
# ---------------------------------------------------------------------------

# The kind of a bundle: by name, else by its CFBundleExecutable.
kind_of() {
  case "${1##*/}" in
    NoemaIME.app) printf ime; return ;;
    Noema.app) printf agent; return ;;
  esac
  case "$(plutil -extract CFBundleExecutable raw -o - "$1/Contents/Info.plist" 2>/dev/null || true)" in
    NoemaIME) printf ime ;;
    NoemaAgent) printf agent ;;
    *) printf unknown ;;
  esac
}

verify_one() {
  local app="$1" before=${failures}
  [[ -d "${app}" && ! -L "${app}" ]] || { bad "bundle not found (or a symlink): ${app}"; return; }
  case "$(kind_of "${app}")" in
    ime) verify_ime "${app}" ;;
    agent) verify_agent "${app}" ;;
    *) bad "${app}: neither NoemaIME.app nor Noema.app (by name or CFBundleExecutable)" ;;
  esac
  if (( failures == before )); then
    log "ok: ${app}$( (( REQUIRE_SIGNED )) && printf ' (signed, hardened runtime)' )"
  else
    log "$((failures - before)) check(s) failed for ${app}"
  fi
}

if [[ "${TARGET}" == *.app ]]; then
  verify_one "${TARGET}"
elif [[ -d "${TARGET}" && ! -L "${TARGET}" ]]; then
  verify_one "${TARGET}/NoemaIME.app"
  verify_one "${TARGET}/Noema.app"
else
  bad "not a bundle or a directory (or a symlink): ${TARGET}"
fi

if (( failures > 0 )); then
  log "${failures} check(s) failed"
  exit 1
fi
