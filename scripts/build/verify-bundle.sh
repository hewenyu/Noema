#!/usr/bin/env bash
# Verify an assembled NoemaIME.app: layout, IMKit Info.plist keys, Mach-O linkage,
# code signatures, and a real launch that loads the bundled librime.
#
# Usage: scripts/build/verify-bundle.sh [--require-signed] [bundle_path]
#   bundle_path       default dist/NoemaIME.app (relative to the repository root)
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
APP=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --require-signed) REQUIRE_SIGNED=1; shift ;;
    -h | --help) sed -n '2,11p' "$0"; exit 0 ;;
    -*) usage_error "unknown option: $1" ;;
    *) [[ -z "${APP}" ]] || usage_error "only one bundle path is accepted"; APP="$1"; shift ;;
  esac
done
APP="${APP:-${REPO_ROOT}/dist/NoemaIME.app}"
APP="${APP%/}"
[[ -d "${APP}" && ! -L "${APP}" ]] || { bad "bundle not found (or a symlink): ${APP}"; exit 1; }

CONTENTS="${APP}/Contents"
INFO="${CONTENTS}/Info.plist"
EXE="${CONTENTS}/MacOS/NoemaIME"
DYLIB="${CONTENTS}/Frameworks/librime.1.dylib"
ENTITLEMENTS="${REPO_ROOT}/Resources/IME/NoemaIME.entitlements"
PYTHON3="$(xcrun -f python3 2>/dev/null || command -v python3)" || usage_error "python3 not found (xcode-select --install)"

# ---------------------------------------------------------------------------
# 1. Layout
# ---------------------------------------------------------------------------

for file in "${INFO}" "${EXE}" "${DYLIB}" "${CONTENTS}/Resources/NoemaIME.icns" "${CONTENTS}/Resources/menu-icon.pdf"; do
  [[ -f "${file}" && ! -L "${file}" ]] || bad "missing regular file: ${file#"${APP}/"}"
done
[[ -x "${EXE}" ]] || bad "Contents/MacOS/NoemaIME is not executable"
[[ -x "${DYLIB}" ]] || bad "Contents/Frameworks/librime.1.dylib is not executable"
if [[ ! -d "${CONTENTS}/Resources/opencc" || -z "$(ls -A "${CONTENTS}/Resources/opencc" 2>/dev/null)" ]]; then
  bad "Contents/Resources/opencc is missing or empty"
fi
if (( failures > 0 )); then
  log "${failures} check(s) failed; layout is incomplete, skipping the remaining checks"
  exit 1
fi

# ---------------------------------------------------------------------------
# 2-3. Info.plist and entitlements
# ---------------------------------------------------------------------------

plutil -lint -s "${INFO}" || bad "Contents/Info.plist is not a valid plist"
if [[ -f "${ENTITLEMENTS}" ]]; then
  plutil -lint -s "${ENTITLEMENTS}" || bad "Resources/IME/NoemaIME.entitlements is not a valid plist"
fi
if grep -q '\${NOEMA_' "${INFO}"; then
  bad "Contents/Info.plist has unreplaced \${NOEMA_*} placeholders"
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
    path = os.path.join(resources, name)
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

# ---------------------------------------------------------------------------
# 4. Mach-O gates
# ---------------------------------------------------------------------------

rpaths_of() {
  otool -l "$1" | awk '/cmd LC_RPATH/ {getline; getline; sub(/^[[:space:]]+path /, ""); sub(/ \(offset [0-9]+\)$/, ""); print}'
}
for macho in "${EXE}" "${DYLIB}"; do
  name="${macho#"${CONTENTS}/"}"
  archs="$(lipo -archs "${macho}" 2>/dev/null || true)"
  [[ "${archs}" == "arm64" ]] || bad "${name}: architectures are '${archs}', expected arm64 only"
  otool -L "${macho}" | "${SCRIPT_DIR}/librime.sh" --check-linkage-stdin || bad "${name}: otool -L linkage gate failed"
done
dylib_id="$(otool -D "${DYLIB}" | sed -n '2p')"
[[ "${dylib_id}" == "@rpath/librime.1.dylib" ]] || bad "Frameworks/librime.1.dylib install_name is '${dylib_id}', expected @rpath/librime.1.dylib"
dylib_rpaths="$(rpaths_of "${DYLIB}")"
[[ -z "${dylib_rpaths}" ]] || bad "Frameworks/librime.1.dylib must carry no LC_RPATH, found: ${dylib_rpaths//$'\n'/, }"
exe_rpaths="$(rpaths_of "${EXE}")"
[[ -n "${exe_rpaths}" ]] || bad "MacOS/NoemaIME has no LC_RPATH; it cannot find Frameworks/librime.1.dylib"
while IFS= read -r rpath; do
  [[ -n "${rpath}" ]] || continue
  [[ "${rpath}" == "@executable_path/../Frameworks" ]] \
    || bad "MacOS/NoemaIME LC_RPATH '${rpath}' is not allowed; only @executable_path/../Frameworks"
done <<<"${exe_rpaths}"
# Shipped bundles carry no Homebrew paths anywhere, not just in load commands.
homebrew_hits="$(grep -rlF /opt/homebrew "${APP}" 2>/dev/null || true)"
[[ -z "${homebrew_hits}" ]] || bad "bundle contains /opt/homebrew strings in: ${homebrew_hits//$'\n'/, }"

# ---------------------------------------------------------------------------
# 5. Signatures (inside-out; the bundle check is --deep only for verification)
# ---------------------------------------------------------------------------

codesign --verify --strict --deep "${APP}" || bad "codesign --verify --strict --deep failed for the bundle"
codesign --verify --strict "${DYLIB}" || bad "codesign --verify failed for Frameworks/librime.1.dylib"
codesign --verify --strict "${EXE}" || bad "codesign --verify failed for MacOS/NoemaIME"
for target in "${APP}" "${EXE}" "${DYLIB}"; do
  name="${target#"${APP}"}"; name="${name#/Contents/}"; name="${name:-NoemaIME.app}"
  details="$(codesign -dvv "${target}" 2>&1 || true)"
  if (( REQUIRE_SIGNED )); then
    grep -q '^Signature=adhoc' <<<"${details}" && bad "${name}: ad-hoc signature, but --require-signed needs a certificate"
    grep -Eq '^CodeDirectory .*flags=.*runtime' <<<"${details}" || bad "${name}: Hardened Runtime flag is missing"
    grep -q '^Authority=' <<<"${details}" || bad "${name}: no signing Authority"
    team="$(sed -n 's/^TeamIdentifier=//p' <<<"${details}")"
    [[ -n "${team}" && "${team}" != "not set" ]] || bad "${name}: TeamIdentifier is '${team:-missing}'"
  elif grep -q '^Signature=adhoc' <<<"${details}" && grep -Eq '^CodeDirectory .*flags=.*runtime' <<<"${details}"; then
    # Without a Team ID, library validation makes dyld refuse the bundled librime.
    bad "${name}: ad-hoc signature with Hardened Runtime cannot load Frameworks/librime.1.dylib; sign ad-hoc without --options runtime"
  fi
done

# ---------------------------------------------------------------------------
# 6. Real launch: dyld must resolve the bundled librime and every module must register
# ---------------------------------------------------------------------------

if probe="$(env -u DYLD_LIBRARY_PATH -u DYLD_FALLBACK_LIBRARY_PATH -u DYLD_FRAMEWORK_PATH -u DYLD_INSERT_LIBRARIES \
  "${EXE}" --check-rime 2>&1)"; then
  printf '%s\n' "${probe}" | sed 's/^/[verify-bundle]   /' >&2
else
  status=$?
  printf '%s\n' "${probe}" | sed 's/^/[verify-bundle]   /' >&2
  bad "MacOS/NoemaIME --check-rime exited ${status}"
fi

if (( failures > 0 )); then
  log "${failures} check(s) failed for ${APP}"
  exit 1
fi
log "ok: ${APP}$( (( REQUIRE_SIGNED )) && printf ' (signed, hardened runtime)' )"
