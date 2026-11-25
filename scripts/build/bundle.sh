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
RIME_DEFAULT="${REPO_ROOT}/Resources/rime-default"
RIME_DEFAULT_FILES=(default.yaml noema_pinyin.schema.yaml noema_pinyin.dict.yaml)
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

for tool in swift codesign plutil xattr ditto otool lipo shasum /usr/bin/iconutil /usr/bin/python3; do
  command -v "${tool}" >/dev/null || die "required tool not found: ${tool}"
done
[[ -f "${IME_RESOURCES}/Info.plist.in" && -f "${ENTITLEMENTS}" && -f "${IME_RESOURCES}/generate-icons.swift" ]] \
  || die "Resources/IME is incomplete (Info.plist.in, NoemaIME.entitlements, generate-icons.swift)"
plutil -lint -s "${ENTITLEMENTS}" || die "invalid entitlements plist: ${ENTITLEMENTS}"
for file in "${RIME_DEFAULT_FILES[@]}"; do
  [[ -f "${RIME_DEFAULT}/${file}" && ! -L "${RIME_DEFAULT}/${file}" ]] || die "Resources/rime-default is incomplete: missing ${file}"
done

# ---------------------------------------------------------------------------
# Inputs: a current librime, a release NoemaIME, and a release noema-rime-deployer
# ---------------------------------------------------------------------------

LOCK_SHA256="$(shasum -a 256 "${REPO_ROOT}/vendor/librime.lock" | awk '{print $1}')"
[[ "$(cat "${LIBRIME_DIR}/.lock-sha256" 2>/dev/null || true)" == "${LOCK_SHA256}" ]] \
  || die "vendor-out/librime is missing or was built from a different vendor/librime.lock; run scripts/build/librime.sh"
"${SCRIPT_DIR}/librime.sh" --verify --out "${LIBRIME_DIR}" || die "vendor-out/librime fails the self-check gate"

cd "${REPO_ROOT}"
# --disable-local-rpath drops SwiftPM's default @loader_path rpath, leaving only the
# release @executable_path/../Frameworks rpath from Package.swift.
SWIFT_BUILD=(swift build -c release --arch arm64 --disable-local-rpath)
# noema-rime-deployer is the isolated Rime deployment subprocess RimeEngine runs from
# Contents/MacOS; librime's deployer never runs inside NoemaIME.
EXECUTABLES=(NoemaIME noema-rime-deployer)
for product in "${EXECUTABLES[@]}"; do
  log "${SWIFT_BUILD[*]} --product ${product}"
  "${SWIFT_BUILD[@]}" --product "${product}" >&2
done
BIN_DIR="$("${SWIFT_BUILD[@]}" --show-bin-path)"
for product in "${EXECUTABLES[@]}"; do
  [[ -f "${BIN_DIR}/${product}" ]] || die "release build produced no ${BIN_DIR}/${product}"
done

# ---------------------------------------------------------------------------
# Locked publish. Every run that publishes into the same --out holds one flock(2)
# on ${TMPDIR:-/tmp}/noema-bundle-publish-<sha256 of the real --out path>.lock, so
# concurrent runs publish one after another. The kernel drops the lock when the
# holder dies (even on SIGKILL), so a lock is never stale, and nothing extra lands
# in --out. Under the lock it re-checks --out and TARGET_APP, moves a previous
# bundle aside to .NoemaIME.app.old.<pid>, and os.rename()s the stage in: unlike
# mv, rename(2) fails on an existing non-empty directory instead of nesting
# NoemaIME.app/NoemaIME.app inside it. A failed rename restores the previous bundle.
#   publish_locked publish   move ${stage_app} to TARGET_APP
#   publish_locked recover   after an interruption, put OLD_APP back (or drop it)
# ---------------------------------------------------------------------------

publish_locked() {
  /usr/bin/python3 -I - "$1" "${OUT_DIR}" "${APP_NAME}" "${BUNDLE_ID}" "${stage_app:-}" "${OLD_APP}" <<'PY'
import fcntl, hashlib, os, plistlib, shutil, signal, sys

mode, out_dir, app_name, bundle_id, stage_app, old = sys.argv[1:7]
target = os.path.join(out_dir, app_name)

def log(message):
    print(f"[bundle] {message}", file=sys.stderr)

def die(message):
    print(f"[bundle] error: {message}", file=sys.stderr)
    sys.exit(1)

def exists(path):
    return os.path.lexists(path)

def remove(path):
    if os.path.isdir(path) and not os.path.islink(path):
        shutil.rmtree(path)
    elif exists(path):
        os.unlink(path)

def is_previous_bundle(path):
    info = os.path.join(path, "Contents", "Info.plist")
    if os.path.islink(path) or not os.path.isdir(path) or os.path.islink(info) or not os.path.isfile(info):
        return False
    try:
        with open(info, "rb") as handle:
            return plistlib.load(handle).get("CFBundleIdentifier") == bundle_id
    except Exception:
        return False

def check_out_dir():
    if os.path.islink(out_dir) or not os.path.isdir(out_dir):
        die(f"--out is no longer a directory: {out_dir}")
    if exists(target):
        if not is_previous_bundle(target):
            die(f"refusing to replace {target}: it is not a previous {app_name} output")
        return
    # Only leftovers of this script (.NoemaIME.app.staging.*, .NoemaIME.app.old.<pid>) may sit beside it.
    foreign = sorted(name for name in os.listdir(out_dir) if not name.startswith(f".{app_name}."))
    if foreign:
        die(f"refusing to use {out_dir}: it is not empty and holds no previous {app_name} ({', '.join(foreign[:3])})")

# A signal must not split the two renames; the caller's trap runs once this returns.
for number in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
    signal.signal(number, signal.SIG_IGN)

if os.path.islink(out_dir) or not os.path.isdir(out_dir):
    die(f"--out is not a directory: {out_dir}")
digest = hashlib.sha256(os.path.realpath(out_dir).encode()).hexdigest()
lock_path = os.path.join(os.environ.get("TMPDIR") or "/tmp", f"noema-bundle-publish-{digest}.lock")
lock_fd = os.open(lock_path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
try:
    fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
except BlockingIOError:
    log(f"waiting for another bundle.sh publishing into {out_dir}")
    fcntl.flock(lock_fd, fcntl.LOCK_EX)

if mode == "recover":
    if exists(old):
        if exists(target):
            remove(old)
        else:
            os.rename(old, target)
            log(f"restored previous bundle at {target}")
    sys.exit(0)

check_out_dir()
if os.path.islink(stage_app) or not os.path.isdir(stage_app):
    die(f"staged bundle is missing: {stage_app}")
if exists(old):
    remove(old)
moved_aside = False
if exists(target):
    try:
        os.rename(target, old)
    except OSError as error:
        die(f"cannot move previous bundle {target} aside: {error}")
    moved_aside = True
if exists(target):
    die(f"{target} reappeared while the publish lock was held")
try:
    os.rename(stage_app, target)
except OSError as error:
    if moved_aside:
        try:
            os.rename(old, target)
        except OSError as restore_error:
            die(f"cannot move the staged bundle to {target} ({error}) nor restore the previous one ({restore_error})")
        die(f"cannot move the staged bundle to {target} ({error}); previous bundle kept")
    die(f"cannot move the staged bundle to {target}: {error}")
if moved_aside:
    try:
        remove(old)
    except OSError as error:
        die(f"published {target} but cannot remove {old}: {error}")
PY
}

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
  if [[ -n "${OLD_APP}" ]] && [[ -e "${OLD_APP}" || -L "${OLD_APP}" ]]; then
    publish_locked recover || true
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
for product in "${EXECUTABLES[@]}"; do
  cp "${BIN_DIR}/${product}" "${contents}/MacOS/${product}"
  chmod 0755 "${contents}/MacOS/${product}"
done
cp "${LIBRIME_DIR}/lib/librime.1.dylib" "${contents}/Frameworks/librime.1.dylib"
chmod 0755 "${contents}/Frameworks/librime.1.dylib"
ditto "${LIBRIME_DIR}/share/opencc" "${contents}/Resources/opencc"
# Built-in Rime schema sources (shared_data_dir); the engine deploys them into the
# user data directory, so the signed bundle stays read-only.
ditto "${RIME_DEFAULT}" "${contents}/Resources/rime-default"

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
sign --entitlements "${ENTITLEMENTS}" "${contents}/MacOS/noema-rime-deployer"
sign --entitlements "${ENTITLEMENTS}" "${contents}/MacOS/NoemaIME"
sign --entitlements "${ENTITLEMENTS}" "${stage_app}"
codesign --verify --strict "${stage_app}" || die "codesign --verify failed for the staged bundle"

# ---------------------------------------------------------------------------
# Publish under the --out lock (see publish_locked); on_exit recovers OLD_APP
# if this run is interrupted between moving the old bundle aside and the stage in.
# ---------------------------------------------------------------------------

# The PID keeps concurrent runs publishing into one --out from sharing an aside path.
OLD_APP="${OUT_DIR}/.${APP_NAME}.old.$$"
publish_locked publish || die "publishing ${TARGET_APP} failed"
OLD_APP=""
log "done: ${TARGET_APP} (version ${VERSION}, build ${BUILD}, ${SIGN_MODE} signature)"
