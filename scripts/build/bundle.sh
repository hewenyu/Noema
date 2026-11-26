#!/usr/bin/env bash
# Assemble and sign NoemaIME.app (the input method) and Noema.app (the companion agent)
# with CommandLineTools only (no Xcode.app, no xcodebuild).
#
# Usage:
#   scripts/build/bundle.sh --sign <identity> [--out <dir>|<dir>/<App>.app] [--target ime|agent|all]
#                           [--version <x.y.z>] [--build <n>]
#
#   --sign <identity>  required (or NOEMA_CODESIGN_IDENTITY): a 40-hex certificate SHA-1,
#                      signed with Hardened Runtime and a secure timestamp, or "-" for an
#                      ad-hoc CI signature (no runtime flag: dyld would refuse to load the
#                      bundled librime without a Team ID). Certificate names are rejected.
#   --out <dir>        output directory (default dist); bundles land at <dir>/NoemaIME.app
#                      and <dir>/Noema.app. A path ending in NoemaIME.app or Noema.app names
#                      that one bundle: its directory is the output and --target follows it.
#   --target <t>       ime (NoemaIME.app), agent (Noema.app), or all (default)
#   --version <ver>    SemVer CFBundleShortVersionString (default ${NOEMA_VERSION:-0.0.0-dev})
#   --build <n>        CFBundleVersion (default ${NOEMA_BUILD:-1})
#
# Each bundle is assembled and signed in staging, then published atomically on its own
# (all: NoemaIME.app first, then Noema.app). Never reads this repository's .git, so it
# also works in exported (git-less) trees. Check the result with scripts/build/verify-bundle.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
LIBRIME_DIR="${REPO_ROOT}/vendor-out/librime"
IME_RESOURCES="${REPO_ROOT}/Resources/IME"
AGENT_RESOURCES="${REPO_ROOT}/Resources/Agent"
RIME_DEFAULT="${REPO_ROOT}/Resources/rime-default"
RIME_DEFAULT_FILES=(default.yaml noema_pinyin.schema.yaml noema_pinyin.dict.yaml)
LEARNED_LUA="${REPO_ROOT}/Resources/rime-lua/noema_learned.lua"
DICTIONARY_LOCKFILE="${REPO_ROOT}/vendor/dictionaries.lock.json"
IME_ENTITLEMENTS="${IME_RESOURCES}/NoemaIME.entitlements"
AGENT_ENTITLEMENTS="${AGENT_RESOURCES}/NoemaAgent.entitlements"
IME_APP="NoemaIME.app"
IME_BUNDLE_ID="dev.noema.inputmethod.NoemaIME"
AGENT_APP="Noema.app"
AGENT_BUNDLE_ID="dev.noema.agent"
AGENT_LAUNCH_AGENT="dev.noema.agent.plist"
# Every bundle this script makes, as name=bundle-id: the only bundles it replaces.
KNOWN_BUNDLES="${IME_APP}=${IME_BUNDLE_ID},${AGENT_APP}=${AGENT_BUNDLE_ID}"

log() { printf '[bundle] %s\n' "$*" >&2; }
die() { printf '[bundle] error: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------

IDENTITY="${NOEMA_CODESIGN_IDENTITY:-}"
OUT_DIR="dist"
TARGET=""
VERSION="${NOEMA_VERSION:-0.0.0-dev}"
BUILD="${NOEMA_BUILD:-1}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --sign) [[ $# -ge 2 ]] || die "--sign needs an identity"; IDENTITY="$2"; shift 2 ;;
    --out) [[ $# -ge 2 ]] || die "--out needs a directory"; OUT_DIR="$2"; shift 2 ;;
    --target) [[ $# -ge 2 ]] || die "--target needs ime, agent, or all"; TARGET="$2"; shift 2 ;;
    --version) [[ $# -ge 2 ]] || die "--version needs a value"; VERSION="$2"; shift 2 ;;
    --build) [[ $# -ge 2 ]] || die "--build needs a value"; BUILD="$2"; shift 2 ;;
    -h | --help) sed -n '2,22p' "$0"; exit 0 ;;
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

# A bundle path names one bundle and its output directory.
case "${OUT_DIR##*/}" in
  "${IME_APP}") NAMED_TARGET=ime ;;
  "${AGENT_APP}") NAMED_TARGET=agent ;;
  *.app) die "--out names an unknown bundle '${OUT_DIR##*/}'; use a directory, or a path ending in ${IME_APP} or ${AGENT_APP}" ;;
  *) NAMED_TARGET="" ;;
esac
if [[ -n "${NAMED_TARGET}" ]]; then
  [[ -z "${TARGET}" || "${TARGET}" == "${NAMED_TARGET}" ]] \
    || die "--out ${OUT_DIR##*/} conflicts with --target ${TARGET}"
  TARGET="${NAMED_TARGET}"
  OUT_DIR="${OUT_DIR%/*}"
  [[ -n "${OUT_DIR}" && "${OUT_DIR}" != "/" ]] || die "refusing to use / as --out"
fi
TARGET="${TARGET:-all}"
case "${TARGET}" in
  ime) APPS=("${IME_APP}") ;;
  agent) APPS=("${AGENT_APP}") ;;
  all) APPS=("${IME_APP}" "${AGENT_APP}") ;;
  *) die "--target must be ime, agent, or all, got '${TARGET}'" ;;
esac
wants() { [[ " ${APPS[*]} " == *" $1 "* ]]; }
bundle_id_of() { if [[ "$1" == "${IME_APP}" ]]; then printf '%s' "${IME_BUNDLE_ID}"; else printf '%s' "${AGENT_BUNDLE_ID}"; fi; }

if [[ -L "${OUT_DIR}" || ( -e "${OUT_DIR}" && ! -d "${OUT_DIR}" ) ]]; then
  die "--out exists and is not a directory: ${OUT_DIR}"
fi

# A previous output of this script: a real directory whose Info.plist names its bundle id.
is_previous_bundle() {
  [[ -d "$1" && ! -L "$1" && -f "$1/Contents/Info.plist" ]] \
    && [[ "$(plutil -extract CFBundleIdentifier raw -o - "$1/Contents/Info.plist" 2>/dev/null)" == "$2" ]]
}
# Publishing replaces each target bundle, so refuse to clobber anything this script did
# not make; a directory holding none of its bundles may hold only its leftovers
# (.NoemaIME.app.*, .Noema.app.*: staging and .old.<pid> from an interrupted run).
holds_previous=0
for app in "${IME_APP}" "${AGENT_APP}"; do
  if [[ -e "${OUT_DIR}/${app}" || -L "${OUT_DIR}/${app}" ]]; then
    if is_previous_bundle "${OUT_DIR}/${app}" "$(bundle_id_of "${app}")"; then
      holds_previous=1
    elif wants "${app}"; then
      die "refusing to replace ${OUT_DIR}/${app}: it is not a previous ${app} output"
    fi
  fi
done
if (( ! holds_previous )) && [[ -d "${OUT_DIR}" ]] \
  && [[ -n "$(find "${OUT_DIR}" -mindepth 1 -maxdepth 1 ! -name ".${IME_APP}.*" ! -name ".${AGENT_APP}.*" -print -quit)" ]]; then
  die "refusing to use ${OUT_DIR}: it is not empty and holds no previous ${IME_APP} or ${AGENT_APP}"
fi

for tool in swift codesign plutil xattr ditto otool lipo shasum /usr/bin/iconutil /usr/bin/python3; do
  command -v "${tool}" >/dev/null || die "required tool not found: ${tool}"
done
[[ -f "${IME_RESOURCES}/generate-icons.swift" ]] || die "Resources/IME/generate-icons.swift is missing"
if wants "${IME_APP}"; then
  [[ -f "${IME_RESOURCES}/Info.plist.in" && -f "${IME_ENTITLEMENTS}" ]] \
    || die "Resources/IME is incomplete (Info.plist.in, NoemaIME.entitlements, generate-icons.swift)"
  plutil -lint -s "${IME_ENTITLEMENTS}" || die "invalid entitlements plist: ${IME_ENTITLEMENTS}"
  for file in "${RIME_DEFAULT_FILES[@]}"; do
    [[ -f "${RIME_DEFAULT}/${file}" && ! -L "${RIME_DEFAULT}/${file}" ]] || die "Resources/rime-default is incomplete: missing ${file}"
  done
  [[ -f "${LEARNED_LUA}" && ! -L "${LEARNED_LUA}" ]] || die "Resources/rime-lua/noema_learned.lua is missing"
fi
if wants "${AGENT_APP}"; then
  [[ -f "${AGENT_RESOURCES}/Info.plist.in" && -f "${AGENT_ENTITLEMENTS}" && -f "${AGENT_RESOURCES}/${AGENT_LAUNCH_AGENT}" ]] \
    || die "Resources/Agent is incomplete (Info.plist.in, NoemaAgent.entitlements, ${AGENT_LAUNCH_AGENT})"
  plutil -lint -s "${AGENT_ENTITLEMENTS}" || die "invalid entitlements plist: ${AGENT_ENTITLEMENTS}"
  plutil -lint -s "${AGENT_RESOURCES}/${AGENT_LAUNCH_AGENT}" || die "invalid LaunchAgent plist: ${AGENT_LAUNCH_AGENT}"
  [[ -f "${DICTIONARY_LOCKFILE}" && ! -L "${DICTIONARY_LOCKFILE}" ]] || die "vendor/dictionaries.lock.json is missing"
  /usr/bin/python3 -I -c 'import json, sys; json.load(open(sys.argv[1], encoding="utf-8"))' "${DICTIONARY_LOCKFILE}" \
    || die "vendor/dictionaries.lock.json is not valid JSON"
fi

# ---------------------------------------------------------------------------
# Inputs: a current librime and release NoemaIME + noema-rime-deployer (ime), and a
# release NoemaAgent (agent), which links no librime
# ---------------------------------------------------------------------------

if wants "${IME_APP}"; then
  LOCK_SHA256="$(shasum -a 256 "${REPO_ROOT}/vendor/librime.lock" | awk '{print $1}')"
  [[ "$(cat "${LIBRIME_DIR}/.lock-sha256" 2>/dev/null || true)" == "${LOCK_SHA256}" ]] \
    || die "vendor-out/librime is missing or was built from a different vendor/librime.lock; run scripts/build/librime.sh"
  "${SCRIPT_DIR}/librime.sh" --verify --out "${LIBRIME_DIR}" || die "vendor-out/librime fails the self-check gate"
fi

cd "${REPO_ROOT}"
# --disable-local-rpath drops SwiftPM's default @loader_path rpath, leaving only the
# release @executable_path/../Frameworks rpath from Package.swift (none for NoemaAgent).
SWIFT_BUILD=(swift build -c release --arch arm64 --disable-local-rpath)
# noema-rime-deployer is the isolated Rime deployment subprocess RimeEngine runs from
# Contents/MacOS; librime's deployer never runs inside NoemaIME.
IME_EXECUTABLES=(NoemaIME noema-rime-deployer)
PRODUCTS=()
wants "${IME_APP}" && PRODUCTS+=("${IME_EXECUTABLES[@]}")
wants "${AGENT_APP}" && PRODUCTS+=(NoemaAgent)
for product in "${PRODUCTS[@]}"; do
  log "${SWIFT_BUILD[*]} --product ${product}"
  "${SWIFT_BUILD[@]}" --product "${product}" >&2
done
BIN_DIR="$("${SWIFT_BUILD[@]}" --show-bin-path)"
for product in "${PRODUCTS[@]}"; do
  [[ -f "${BIN_DIR}/${product}" ]] || die "release build produced no ${BIN_DIR}/${product}"
done

# ---------------------------------------------------------------------------
# Locked publish. Every run that publishes into the same --out holds one flock(2)
# on ${TMPDIR:-/tmp}/noema-bundle-publish-<sha256 of the real --out path>.lock, so
# concurrent runs publish one after another. The kernel drops the lock when the
# holder dies (even on SIGKILL), so a lock is never stale, and nothing extra lands
# in --out. Under the lock it re-checks --out and the target, moves a previous
# bundle aside to .<App>.app.old.<pid>, and os.rename()s the stage in: unlike mv,
# rename(2) fails on an existing non-empty directory instead of nesting
# <App>.app/<App>.app inside it. A failed rename restores the previous bundle.
#   publish_locked publish   move ${stage_app} to ${OUT_DIR}/${PUBLISH_APP}
#   publish_locked recover   after an interruption, put OLD_APP back (or drop it)
# ---------------------------------------------------------------------------

publish_locked() {
  /usr/bin/python3 -I - "$1" "${OUT_DIR}" "${PUBLISH_APP}" "${KNOWN_BUNDLES}" "${stage_app:-}" "${OLD_APP}" <<'PY'
import fcntl, hashlib, os, plistlib, shutil, signal, sys

mode, out_dir, app_name, known, stage_app, old = sys.argv[1:7]
bundles = dict(entry.split("=", 1) for entry in known.split(","))
bundle_id = bundles[app_name]
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

def is_previous_bundle(path, expected_id):
    info = os.path.join(path, "Contents", "Info.plist")
    if os.path.islink(path) or not os.path.isdir(path) or os.path.islink(info) or not os.path.isfile(info):
        return False
    try:
        with open(info, "rb") as handle:
            return plistlib.load(handle).get("CFBundleIdentifier") == expected_id
    except Exception:
        return False

def check_out_dir():
    if os.path.islink(out_dir) or not os.path.isdir(out_dir):
        die(f"--out is no longer a directory: {out_dir}")
    if exists(target) and not is_previous_bundle(target, bundle_id):
        die(f"refusing to replace {target}: it is not a previous {app_name} output")
    if any(is_previous_bundle(os.path.join(out_dir, name), known_id) for name, known_id in bundles.items()):
        return
    # Only leftovers of this script (.<App>.app.staging.*, .<App>.app.old.<pid>) may sit beside it.
    ours = tuple(f".{name}." for name in bundles)
    foreign = sorted(name for name in os.listdir(out_dir) if not name.startswith(ours))
    if foreign:
        die(f"refusing to use {out_dir}: it is not empty and holds no previous {' or '.join(bundles)} ({', '.join(foreign[:3])})")

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
STAGE_DIRS=()
OLD_APP=""
PUBLISH_APP=""
on_exit() {
  local status=$?
  if [[ -n "${OLD_APP}" ]] && [[ -e "${OLD_APP}" || -L "${OLD_APP}" ]]; then
    publish_locked recover || true
  fi
  local dir
  for dir in ${STAGE_DIRS[@]+"${STAGE_DIRS[@]}"}; do rm -rf "${dir}" || true; done
  if [[ -n "${ICON_DIR}" ]]; then rm -rf "${ICON_DIR}" || true; fi
  exit "${status}"
}
trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

ICON_DIR="$(mktemp -d "${TMPDIR:-/tmp}/noema-icons.XXXXXX")"
swift "${IME_RESOURCES}/generate-icons.swift" "${ICON_DIR}" >&2 || die "icon generation failed"

# Stage next to the target so the final rename stays on one filesystem. Sets stage_app
# (not a command substitution, so STAGE_DIRS keeps the directory for on_exit).
new_stage() {
  local dir
  dir="$(mktemp -d "${OUT_DIR}/.$1.staging.XXXXXX")"
  STAGE_DIRS+=("${dir}")
  stage_app="${dir}/$1"
}

# Info.plist from a template with version and build injected; no placeholder may survive.
write_info_plist() {
  local template="$1" info="$2"
  sed -e "s/\${NOEMA_VERSION}/${VERSION}/g" -e "s/\${NOEMA_BUILD}/${BUILD}/g" "${template}" > "${info}"
  if grep -q '\${NOEMA_' "${info}"; then
    die "Info.plist still has unreplaced placeholders: $(grep -o '\${NOEMA_[A-Z_]*}' "${info}" | sort -u | tr '\n' ' ')"
  fi
  plutil -lint -s "${info}" || die "generated Info.plist is invalid: ${info}"
}

icns() {
  /usr/bin/iconutil -c icns -o "$2" "${ICON_DIR}/$1.iconset" || die "iconutil -c icns failed for $1"
}

sign_args=(--force --sign "${IDENTITY}")
if [[ "${SIGN_MODE}" == identity ]]; then
  sign_args+=(--options runtime --timestamp)
  log "signing with ${IDENTITY} (hardened runtime, secure timestamp)"
else
  log "signing ad-hoc (no hardened runtime: CI only, not distributable)"
fi
# Inside-out; never --deep (it would sign nested code with the wrong options).
sign() {
  local output
  output="$(codesign "${sign_args[@]}" "$@" 2>&1)" || die "codesign $* failed: ${output}"
}

# ---------------------------------------------------------------------------
# NoemaIME.app: the IMKit shell, its deployer, librime, the built-in schema, and the
# learned-phrase Lua translator
# ---------------------------------------------------------------------------

assemble_ime() {
  local stage_app="$1" contents="$1/Contents" product
  log "assembling ${IME_APP}"
  mkdir -p "${contents}/MacOS" "${contents}/Frameworks" "${contents}/Resources"
  for product in "${IME_EXECUTABLES[@]}"; do
    cp "${BIN_DIR}/${product}" "${contents}/MacOS/${product}"
    chmod 0755 "${contents}/MacOS/${product}"
  done
  cp "${LIBRIME_DIR}/lib/librime.1.dylib" "${contents}/Frameworks/librime.1.dylib"
  chmod 0755 "${contents}/Frameworks/librime.1.dylib"
  ditto "${LIBRIME_DIR}/share/opencc" "${contents}/Resources/opencc"
  # Built-in Rime schema sources (shared_data_dir); the engine deploys them into the
  # user data directory, so the signed bundle stays read-only.
  ditto "${RIME_DEFAULT}" "${contents}/Resources/rime-default"
  # The learned-phrase translator RimeEngine copies into each schema set's lua/ directory.
  mkdir -p "${contents}/Resources/rime-lua"
  cp "${LEARNED_LUA}" "${contents}/Resources/rime-lua/noema_learned.lua"
  icns NoemaIME "${contents}/Resources/NoemaIME.icns"
  cp "${ICON_DIR}/menu-icon.pdf" "${contents}/Resources/menu-icon.pdf"
  write_info_plist "${IME_RESOURCES}/Info.plist.in" "${contents}/Info.plist"
  printf 'APPL????' > "${contents}/PkgInfo"

  xattr -cr "${stage_app}"
  sign "${contents}/Frameworks/librime.1.dylib"
  sign --entitlements "${IME_ENTITLEMENTS}" "${contents}/MacOS/noema-rime-deployer"
  sign --entitlements "${IME_ENTITLEMENTS}" "${contents}/MacOS/NoemaIME"
  sign --entitlements "${IME_ENTITLEMENTS}" "${stage_app}"
  codesign --verify --strict "${stage_app}" || die "codesign --verify failed for the staged ${IME_APP}"
}

# ---------------------------------------------------------------------------
# Noema.app: the companion agent, its LaunchAgent plist, and the dictionary lockfile;
# no librime, no rpath
# ---------------------------------------------------------------------------

assemble_agent() {
  local stage_app="$1" contents="$1/Contents" rpaths
  log "assembling ${AGENT_APP}"
  rpaths="$(otool -l "${BIN_DIR}/NoemaAgent" | grep -c 'cmd LC_RPATH' || true)"
  [[ "${rpaths}" == 0 ]] || die "release NoemaAgent carries ${rpaths} LC_RPATH entries; it must carry none"
  mkdir -p "${contents}/MacOS" "${contents}/Resources" "${contents}/Library/LaunchAgents"
  cp "${BIN_DIR}/NoemaAgent" "${contents}/MacOS/NoemaAgent"
  chmod 0755 "${contents}/MacOS/NoemaAgent"
  icns Noema "${contents}/Resources/Noema.icns"
  cp "${ICON_DIR}/menu-icon.pdf" "${contents}/Resources/menu-icon.pdf"
  # The pinned dictionary downloads Settings › 词库 installs from (SHA-256 per entry).
  cp "${DICTIONARY_LOCKFILE}" "${contents}/Resources/dictionaries.lock.json"
  # SMAppService.agent(plistName:) registers Contents/Library/LaunchAgents/<plist>.
  cp "${AGENT_RESOURCES}/${AGENT_LAUNCH_AGENT}" "${contents}/Library/LaunchAgents/${AGENT_LAUNCH_AGENT}"
  write_info_plist "${AGENT_RESOURCES}/Info.plist.in" "${contents}/Info.plist"
  printf 'APPL????' > "${contents}/PkgInfo"

  xattr -cr "${stage_app}"
  sign --entitlements "${AGENT_ENTITLEMENTS}" "${contents}/MacOS/NoemaAgent"
  sign --entitlements "${AGENT_ENTITLEMENTS}" "${stage_app}"
  codesign --verify --strict "${stage_app}" || die "codesign --verify failed for the staged ${AGENT_APP}"
}

# ---------------------------------------------------------------------------
# Assemble and sign every target, then publish each under the --out lock (see
# publish_locked); on_exit recovers OLD_APP if this run is interrupted between moving
# the old bundle aside and the stage in.
# ---------------------------------------------------------------------------

declare -a STAGED=()
for app in "${APPS[@]}"; do
  new_stage "${app}"
  if [[ "${app}" == "${IME_APP}" ]]; then assemble_ime "${stage_app}"; else assemble_agent "${stage_app}"; fi
  STAGED+=("${stage_app}")
done

for index in "${!APPS[@]}"; do
  PUBLISH_APP="${APPS[${index}]}"
  stage_app="${STAGED[${index}]}"
  # The PID keeps concurrent runs publishing into one --out from sharing an aside path.
  OLD_APP="${OUT_DIR}/.${PUBLISH_APP}.old.$$"
  publish_locked publish || die "publishing ${OUT_DIR}/${PUBLISH_APP} failed"
  OLD_APP=""
  log "done: ${OUT_DIR}/${PUBLISH_APP} (version ${VERSION}, build ${BUILD}, ${SIGN_MODE} signature)"
done
