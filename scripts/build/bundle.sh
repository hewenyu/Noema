#!/usr/bin/env bash
# Assemble and sign NoemaIME.app with CommandLineTools only (no Xcode.app, no xcodebuild).
#
# Usage:
#   scripts/build/bundle.sh --sign <identity> [--out <dir>] [--version <x.y.z>] [--build <n>]
#
#   --sign <identity>  required (or NOEMA_CODESIGN_IDENTITY): a 40-hex certificate SHA-1,
#                      signed with Hardened Runtime and a secure timestamp, or "-" for an
#                      ad-hoc CI signature (no runtime flag: dyld would refuse to load the
#                      bundled librime without a Team ID). Certificate names are rejected.
#   --out <dir>        output directory (default dist); the bundle lands at <dir>/NoemaIME.app
#   --version <ver>    SemVer CFBundleShortVersionString (default ${NOEMA_VERSION:-0.0.0-dev})
#   --build <n>        CFBundleVersion (default ${NOEMA_BUILD:-1})
#
# Never reads this repository's .git, so it also works in exported (git-less) trees.
# Check the result with scripts/build/verify-bundle.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
LIBRIME_DIR="${REPO_ROOT}/vendor-out/librime"
IME_RESOURCES="${REPO_ROOT}/Resources/IME"
ENTITLEMENTS="${IME_RESOURCES}/NoemaIME.entitlements"
APP_NAME="NoemaIME.app"
BUNDLE_ID="dev.noema.inputmethod.NoemaIME"

log() { printf '[bundle] %s\n' "$*" >&2; }
die() { printf '[bundle] error: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------

IDENTITY="${NOEMA_CODESIGN_IDENTITY:-}"
OUT_DIR="dist"
VERSION="${NOEMA_VERSION:-0.0.0-dev}"
BUILD="${NOEMA_BUILD:-1}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --sign) [[ $# -ge 2 ]] || die "--sign needs an identity"; IDENTITY="$2"; shift 2 ;;
    --out) [[ $# -ge 2 ]] || die "--out needs a directory"; OUT_DIR="$2"; shift 2 ;;
    --version) [[ $# -ge 2 ]] || die "--version needs a value"; VERSION="$2"; shift 2 ;;
    --build) [[ $# -ge 2 ]] || die "--build needs a value"; BUILD="$2"; shift 2 ;;
    -h | --help) sed -n '2,16p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ -n "${IDENTITY}" ]] || die "--sign <identity> (or NOEMA_CODESIGN_IDENTITY) is required; use - for ad-hoc or a 40-hex certificate SHA-1"
if [[ "${IDENTITY}" == "-" ]]; then
  SIGN_MODE=adhoc
elif [[ "${IDENTITY}" =~ ^[0-9A-Fa-f]{40}$ ]]; then
  SIGN_MODE=identity
else
  die "--sign accepts only - or a 40-hex certificate SHA-1, not '${IDENTITY}' (names are ambiguous; see security find-identity -v -p codesigning)"
fi
[[ "${VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$ ]] \
  || die "--version must be SemVer like 1.2.3, 1.2.3-rc.1, or 1.2.3-rc.1+meta, got '${VERSION}'"
[[ "${BUILD}" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || die "--build must be numeric like 42 or 1.2.3, got '${BUILD}'"

[[ -n "${OUT_DIR}" ]] || die "--out needs a non-empty directory"
[[ "${OUT_DIR}" == /* ]] || OUT_DIR="$(pwd)/${OUT_DIR}"
# Canonicalize textually (the directory may not exist yet): drop ./ and repeated /.
slash=/
while [[ "${OUT_DIR}" == */./* || "${OUT_DIR}" == *//* ]]; do
  OUT_DIR="${OUT_DIR//\/.\//${slash}}"
  OUT_DIR="${OUT_DIR//\/\//${slash}}"
done
while [[ "${OUT_DIR}" != "/" && "${OUT_DIR}" == */ ]]; do OUT_DIR="${OUT_DIR%/}"; done
[[ "${OUT_DIR}" != "/" ]] || die "refusing to use / as --out"
case "${OUT_DIR}/" in
  */../* | */./*) die "--out must not contain . or .. components: ${OUT_DIR}" ;;
esac
if [[ -L "${OUT_DIR}" || ( -e "${OUT_DIR}" && ! -d "${OUT_DIR}" ) ]]; then
  die "--out exists and is not a directory: ${OUT_DIR}"
fi
TARGET_APP="${OUT_DIR}/${APP_NAME}"

# A previous output of this script: a real directory whose Info.plist names our bundle id.
is_previous_bundle() {
  [[ -d "$1" && ! -L "$1" && -f "$1/Contents/Info.plist" ]] \
    && [[ "$(plutil -extract CFBundleIdentifier raw -o - "$1/Contents/Info.plist" 2>/dev/null)" == "${BUNDLE_ID}" ]]
}
# Publishing replaces TARGET_APP, so refuse to clobber anything this script did not make.
if [[ -e "${TARGET_APP}" || -L "${TARGET_APP}" ]]; then
  is_previous_bundle "${TARGET_APP}" || die "refusing to replace ${TARGET_APP}: it is not a previous ${APP_NAME} output"
elif [[ -d "${OUT_DIR}" ]] \
  && [[ -n "$(find "${OUT_DIR}" -mindepth 1 -maxdepth 1 ! -name ".${APP_NAME}.*" -print -quit)" ]]; then
  # Only leftovers of an interrupted run (.NoemaIME.app.staging.*, .NoemaIME.app.old.<pid>) are ours.
  die "refusing to use ${OUT_DIR}: it is not empty and holds no previous ${APP_NAME}"
fi

for tool in swift codesign plutil xattr ditto otool lipo shasum /usr/bin/iconutil; do
  command -v "${tool}" >/dev/null || die "required tool not found: ${tool}"
done
[[ -f "${IME_RESOURCES}/Info.plist.in" && -f "${ENTITLEMENTS}" && -f "${IME_RESOURCES}/generate-icons.swift" ]] \
  || die "Resources/IME is incomplete (Info.plist.in, NoemaIME.entitlements, generate-icons.swift)"
plutil -lint -s "${ENTITLEMENTS}" || die "invalid entitlements plist: ${ENTITLEMENTS}"

# ---------------------------------------------------------------------------
# Inputs: a current librime and a release NoemaIME
# ---------------------------------------------------------------------------

LOCK_SHA256="$(shasum -a 256 "${REPO_ROOT}/vendor/librime.lock" | awk '{print $1}')"
[[ "$(cat "${LIBRIME_DIR}/.lock-sha256" 2>/dev/null || true)" == "${LOCK_SHA256}" ]] \
  || die "vendor-out/librime is missing or was built from a different vendor/librime.lock; run scripts/build/librime.sh"
"${SCRIPT_DIR}/librime.sh" --verify --out "${LIBRIME_DIR}" || die "vendor-out/librime fails the self-check gate"

cd "${REPO_ROOT}"
# --disable-local-rpath drops SwiftPM's default @loader_path rpath, leaving only the
# release @executable_path/../Frameworks rpath from Package.swift.
SWIFT_BUILD=(swift build -c release --arch arm64 --disable-local-rpath)
log "${SWIFT_BUILD[*]} --product NoemaIME"
"${SWIFT_BUILD[@]}" --product NoemaIME >&2
BIN_DIR="$("${SWIFT_BUILD[@]}" --show-bin-path)"
[[ -f "${BIN_DIR}/NoemaIME" ]] || die "release build produced no ${BIN_DIR}/NoemaIME"

# ---------------------------------------------------------------------------
# Temporary paths owned by this run; on_exit removes them and restores the
# previous bundle if a publish was interrupted.
# ---------------------------------------------------------------------------

mkdir -p "${OUT_DIR}"
ICON_DIR=""
STAGE_DIR=""
OLD_APP=""
on_exit() {
  local status=$?
  if [[ -n "${OLD_APP}" && -d "${OLD_APP}" ]]; then
    if [[ ! -e "${TARGET_APP}" ]]; then
      mv "${OLD_APP}" "${TARGET_APP}" && log "restored previous bundle at ${TARGET_APP}" || true
    else
      rm -rf "${OLD_APP}" || true
    fi
  fi
  if [[ -n "${STAGE_DIR}" ]]; then rm -rf "${STAGE_DIR}" || true; fi
  if [[ -n "${ICON_DIR}" ]]; then rm -rf "${ICON_DIR}" || true; fi
  exit "${status}"
}
trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

ICON_DIR="$(mktemp -d "${TMPDIR:-/tmp}/noema-icons.XXXXXX")"
# Stage next to the target so the final rename stays on one filesystem.
STAGE_DIR="$(mktemp -d "${OUT_DIR}/.${APP_NAME}.staging.XXXXXX")"
stage_app="${STAGE_DIR}/${APP_NAME}"
contents="${stage_app}/Contents"

# ---------------------------------------------------------------------------
# Assemble
# ---------------------------------------------------------------------------

log "assembling ${APP_NAME}"
mkdir -p "${contents}/MacOS" "${contents}/Frameworks" "${contents}/Resources"
cp "${BIN_DIR}/NoemaIME" "${contents}/MacOS/NoemaIME"
cp "${LIBRIME_DIR}/lib/librime.1.dylib" "${contents}/Frameworks/librime.1.dylib"
chmod 0755 "${contents}/MacOS/NoemaIME" "${contents}/Frameworks/librime.1.dylib"
ditto "${LIBRIME_DIR}/share/opencc" "${contents}/Resources/opencc"

swift "${IME_RESOURCES}/generate-icons.swift" "${ICON_DIR}" >&2 || die "icon generation failed"
/usr/bin/iconutil -c icns -o "${contents}/Resources/NoemaIME.icns" "${ICON_DIR}/NoemaIME.iconset" \
  || die "iconutil -c icns failed"
cp "${ICON_DIR}/menu-icon.pdf" "${contents}/Resources/menu-icon.pdf"

info="${contents}/Info.plist"
sed -e "s/\${NOEMA_VERSION}/${VERSION}/g" -e "s/\${NOEMA_BUILD}/${BUILD}/g" \
  "${IME_RESOURCES}/Info.plist.in" > "${info}"
if grep -q '\${NOEMA_' "${info}"; then
  die "Info.plist still has unreplaced placeholders: $(grep -o '\${NOEMA_[A-Z_]*}' "${info}" | sort -u | tr '\n' ' ')"
fi
plutil -lint -s "${info}" || die "generated Info.plist is invalid"
printf 'APPL????' > "${contents}/PkgInfo"

# ---------------------------------------------------------------------------
# Sign inside-out; never --deep (it would sign nested code with the wrong options)
# ---------------------------------------------------------------------------

xattr -cr "${stage_app}"
sign_args=(--force --sign "${IDENTITY}")
if [[ "${SIGN_MODE}" == identity ]]; then
  sign_args+=(--options runtime --timestamp)
fi
sign() {
  local output
  output="$(codesign "${sign_args[@]}" "$@" 2>&1)" || die "codesign $* failed: ${output}"
}
if [[ "${SIGN_MODE}" == identity ]]; then
  log "signing with ${IDENTITY} (hardened runtime, secure timestamp)"
else
  log "signing ad-hoc (no hardened runtime: CI only, not distributable)"
fi
sign "${contents}/Frameworks/librime.1.dylib"
sign --entitlements "${ENTITLEMENTS}" "${contents}/MacOS/NoemaIME"
sign --entitlements "${ENTITLEMENTS}" "${stage_app}"
codesign --verify --strict "${stage_app}" || die "codesign --verify failed for the staged bundle"

# ---------------------------------------------------------------------------
# Publish: move any previous bundle aside, move the stage in, then drop the old
# copy. A failed second step rolls back (on_exit also restores after a signal).
# ---------------------------------------------------------------------------

# The PID keeps concurrent runs publishing into one --out from sharing an aside path.
old="${OUT_DIR}/.${APP_NAME}.old.$$"
rm -rf "${old}"
if [[ -e "${TARGET_APP}" ]]; then
  OLD_APP="${old}"
  mv "${TARGET_APP}" "${old}" || die "cannot move previous bundle ${TARGET_APP} aside"
fi
if ! mv "${stage_app}" "${TARGET_APP}"; then
  if [[ -n "${OLD_APP}" ]]; then
    mv "${old}" "${TARGET_APP}" && OLD_APP="" || true
  fi
  die "cannot move the staged bundle to ${TARGET_APP}; previous bundle kept"
fi
rm -rf "${old}"
OLD_APP=""
log "done: ${TARGET_APP} (version ${VERSION}, build ${BUILD}, ${SIGN_MODE} signature)"
