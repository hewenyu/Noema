#!/usr/bin/env bash
# Build a self-contained librime.1.dylib (librime + librime-lua + librime-octagram,
# with boost/leveldb/marisa/opencc/yaml-cpp/spdlog statically merged in) from the
# pinned inputs in vendor/librime.lock, using CommandLineTools only.
#
# Usage:
#   scripts/build/librime.sh [--out <dir>] [--force]
#   scripts/build/librime.sh --verify [--out <dir>]     # run the self-check gate only
#   otool -L <macho> | scripts/build/librime.sh --check-linkage-stdin
#
# Output (default vendor-out/librime):
#   lib/librime.1.dylib  (install_name @rpath/librime.1.dylib), lib/librime.dylib -> librime.1.dylib
#   include/rime_api.h (+ the other public librime headers)
#   share/opencc/
#   .lock-sha256         sha256 of vendor/librime.lock the output was built from
#
# Never reads this repository's .git, so it also works in exported (git-less) trees.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
LOCK_FILE="${REPO_ROOT}/vendor/librime.lock"
OUT_DIR="${REPO_ROOT}/vendor-out/librime"
WORK_DIR="${REPO_ROOT}/.build/librime"
SRC_DIR="${REPO_ROOT}/.build/librime-src"
INSTALL_ID="@rpath/librime.1.dylib"

log() { printf '[librime] %s\n' "$*" >&2; }
die() { printf '[librime] error: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Self-check gate
# ---------------------------------------------------------------------------

# Reads `otool -L` output on stdin. Fails if any load command points outside
# @rpath/librime.1.dylib, /usr/lib/, or /System/Library/.
check_linkage_stream() {
  local line dep bad=0 seen=0
  while IFS= read -r line; do
    # Dependency lines are indented; the first, unindented line names the file.
    [[ "${line}" =~ ^[[:space:]]+([^[:space:]].*)\ \(compatibility ]] || continue
    dep="${BASH_REMATCH[1]}"
    seen=1
    case "${dep}" in
      /opt/homebrew/* | /usr/local/*)
        printf '[librime] linkage: forbidden Homebrew/local dependency: %s\n' "${dep}" >&2
        bad=1 ;;
      "${INSTALL_ID}" | /usr/lib/* | /System/Library/*) ;;
      *)
        printf '[librime] linkage: dependency outside the allow-list: %s\n' "${dep}" >&2
        bad=1 ;;
    esac
  done
  if [[ "${seen}" -eq 0 ]]; then
    printf '[librime] linkage: no dependencies parsed from otool -L output\n' >&2
    return 1
  fi
  return "${bad}"
}

verify_output() {
  local out="$1" dylib="$1/lib/librime.1.dylib" id
  [[ -f "${dylib}" && ! -L "${dylib}" ]] || { log "verify: missing ${dylib}"; return 1; }
  [[ "$(readlink "${out}/lib/librime.dylib" 2>/dev/null)" == "librime.1.dylib" ]] \
    || { log "verify: lib/librime.dylib must be a symlink to librime.1.dylib"; return 1; }
  id="$(otool -D "${dylib}" | sed -n '2p')"
  [[ "${id}" == "${INSTALL_ID}" ]] || { log "verify: install_name is '${id}', expected ${INSTALL_ID}"; return 1; }
  otool -L "${dylib}" | check_linkage_stream || { log "verify: otool -L gate failed for ${dylib}"; return 1; }
  if otool -l "${dylib}" | grep -A2 LC_RPATH | grep -q ' path '; then
    log "verify: ${dylib} must not carry LC_RPATH entries"; return 1
  fi
  lipo -archs "${dylib}" | grep -qx arm64 || { log "verify: ${dylib} is not arm64-only"; return 1; }
  codesign --verify "${dylib}" 2>/dev/null || { log "verify: ${dylib} has no valid code signature"; return 1; }
  [[ -s "${out}/include/rime_api.h" ]] || { log "verify: missing include/rime_api.h"; return 1; }
  [[ -d "${out}/share/opencc" && -n "$(ls -A "${out}/share/opencc")" ]] \
    || { log "verify: share/opencc is missing or empty"; return 1; }
  log "verify: ok (${dylib})"
}

# ---------------------------------------------------------------------------
# Arguments and lock
# ---------------------------------------------------------------------------

FORCE=0
MODE=build
while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) [[ $# -ge 2 ]] || die "--out needs a directory"; OUT_DIR="$2"; shift 2 ;;
    --force) FORCE=1; shift ;;
    --verify) MODE=verify; shift ;;
    --check-linkage-stdin) MODE=linkage; shift ;;
    -h | --help) sed -n '2,17p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done
[[ "${OUT_DIR}" == /* ]] || OUT_DIR="$(pwd)/${OUT_DIR}"

if [[ "${MODE}" == linkage ]]; then
  check_linkage_stream
  exit $?
fi
if [[ "${MODE}" == verify ]]; then
  verify_output "${OUT_DIR}"
  exit $?
fi

[[ -f "${LOCK_FILE}" ]] || die "missing ${LOCK_FILE}"
lock_get() {
  local value
  value="$(grep -E "^$1=" "${LOCK_FILE}" | tail -n 1 | cut -d= -f2-)"
  [[ -n "${value}" ]] || die "vendor/librime.lock has no $1"
  printf '%s' "${value}"
}
LIBRIME_REPO="$(lock_get LIBRIME_REPO)"
LIBRIME_COMMIT="$(lock_get LIBRIME_COMMIT)"
LIBRIME_LUA_REPO="$(lock_get LIBRIME_LUA_REPO)"
LIBRIME_LUA_COMMIT="$(lock_get LIBRIME_LUA_COMMIT)"
LIBRIME_LUA_THIRDPARTY_COMMIT="$(lock_get LIBRIME_LUA_THIRDPARTY_COMMIT)"
LIBRIME_OCTAGRAM_REPO="$(lock_get LIBRIME_OCTAGRAM_REPO)"
LIBRIME_OCTAGRAM_COMMIT="$(lock_get LIBRIME_OCTAGRAM_COMMIT)"
BOOST_VERSION="$(lock_get BOOST_VERSION)"
BOOST_URL="$(lock_get BOOST_URL)"
BOOST_SHA256="$(lock_get BOOST_SHA256)"
LOCK_SHA256="$(shasum -a 256 "${LOCK_FILE}" | awk '{print $1}')"

if [[ "${FORCE}" -eq 0 && -f "${OUT_DIR}/.lock-sha256" ]] \
  && [[ "$(cat "${OUT_DIR}/.lock-sha256")" == "${LOCK_SHA256}" ]]; then
  if verify_output "${OUT_DIR}"; then
    log "up to date with vendor/librime.lock (${LOCK_SHA256}); skipping build (use --force to rebuild)"
    exit 0
  fi
  log "existing output failed verification; rebuilding"
fi

# ---------------------------------------------------------------------------
# Toolchain: CommandLineTools only, nothing from /opt/homebrew or /usr/local
# ---------------------------------------------------------------------------

for tool in cmake make git curl shasum tar xcrun otool install_name_tool codesign lipo; do
  command -v "${tool}" >/dev/null || die "required tool not found: ${tool}"
done
export SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
export CC="$(xcrun -f clang)"
export CXX="$(xcrun -f clang++)"
export MACOSX_DEPLOYMENT_TARGET=26.0
unset CPATH LIBRARY_PATH C_INCLUDE_PATH CPLUS_INCLUDE_PATH PKG_CONFIG_PATH CMAKE_PREFIX_PATH
JOBS="$(sysctl -n hw.ncpu)"
PYTHON3="$(xcrun -f python3)"

PREFIX="${WORK_DIR}/deps-prefix"
BOOST_DIR="${WORK_DIR}/boost_${BOOST_VERSION//./_}"
CMAKE_COMMON=(
  -G "Unix Makefiles"
  -DCMAKE_BUILD_TYPE=Release
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5
  "-DCMAKE_IGNORE_PREFIX_PATH=/opt/homebrew;/usr/local"
  -DCMAKE_FIND_USE_PACKAGE_REGISTRY=OFF
  -DCMAKE_OSX_ARCHITECTURES=arm64
  -DCMAKE_OSX_DEPLOYMENT_TARGET=26.0
  "-DCMAKE_OSX_SYSROOT=${SDKROOT}"
  "-DCMAKE_C_COMPILER=${CC}"
  "-DCMAKE_CXX_COMPILER=${CXX}"
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON
  "-DCMAKE_PREFIX_PATH=${PREFIX}"
  "-DCMAKE_INSTALL_PREFIX=${PREFIX}"
)

if [[ "${FORCE}" -eq 1 ]]; then
  log "--force: discarding previous build trees"
  rm -rf "${WORK_DIR}/build" "${PREFIX}"
fi
mkdir -p "${WORK_DIR}/downloads" "${WORK_DIR}/build" "${PREFIX}"

# ---------------------------------------------------------------------------
# Boost (header-only)
# ---------------------------------------------------------------------------

boost_tarball="${WORK_DIR}/downloads/$(basename "${BOOST_URL}")"
if [[ ! -f "${boost_tarball}" ]]; then
  log "downloading ${BOOST_URL}"
  curl -fsSL --retry 3 -o "${boost_tarball}.part" "${BOOST_URL}"
  mv "${boost_tarball}.part" "${boost_tarball}"
fi
actual_sha="$(shasum -a 256 "${boost_tarball}" | awk '{print $1}')"
if [[ "${actual_sha}" != "${BOOST_SHA256}" ]]; then
  die "Boost SHA256 mismatch for ${boost_tarball}: expected ${BOOST_SHA256}, got ${actual_sha}"
fi
log "Boost SHA256 verified (${actual_sha})"
if [[ "$(cat "${BOOST_DIR}/.noema-headers" 2>/dev/null)" != "${BOOST_SHA256}" ]]; then
  rm -rf "${BOOST_DIR}"
  tar -xzf "${boost_tarball}" -C "${WORK_DIR}"
  [[ -f "${BOOST_DIR}/bootstrap.sh" ]] || die "unexpected Boost archive layout"
  (cd "${BOOST_DIR}" && ./bootstrap.sh >/dev/null && ./b2 headers >/dev/null)
  printf '%s\n' "${BOOST_SHA256}" > "${BOOST_DIR}/.noema-headers"
fi

# ---------------------------------------------------------------------------
# Sources at exact commits
# ---------------------------------------------------------------------------

checkout_at() {
  local dir="$1" url="$2" commit="$3"
  if [[ -d "${dir}/.git" ]] && [[ "$(git -C "${dir}" rev-parse HEAD 2>/dev/null)" == "${commit}" ]]; then
    return 0
  fi
  log "fetching ${url} @ ${commit}"
  rm -rf "${dir}"
  mkdir -p "${dir}"
  git -C "${dir}" init -q
  git -C "${dir}" remote add origin "${url}"
  git -C "${dir}" fetch -q --depth 1 origin "${commit}"
  git -C "${dir}" checkout -q --detach FETCH_HEAD
  [[ "$(git -C "${dir}" rev-parse HEAD)" == "${commit}" ]] || die "${dir} is not at ${commit}"
}

checkout_at "${SRC_DIR}" "${LIBRIME_REPO}" "${LIBRIME_COMMIT}"
for dep in leveldb marisa-trie opencc yaml-cpp spdlog; do
  sub="deps/${dep}"
  sub_commit="$(git -C "${SRC_DIR}" ls-tree HEAD "${sub}" | awk '{print $3}')"
  sub_key="$(git -C "${SRC_DIR}" config -f .gitmodules --get-regexp '\.path$' | awk -v p="${sub}" '$2 == p {print $1}')"
  sub_url="$(git -C "${SRC_DIR}" config -f .gitmodules --get "${sub_key%.path}.url")"
  [[ -n "${sub_commit}" && -n "${sub_url}" ]] || die "cannot resolve submodule ${sub}"
  checkout_at "${SRC_DIR}/${sub}" "${sub_url}" "${sub_commit}"
done
checkout_at "${SRC_DIR}/plugins/lua" "${LIBRIME_LUA_REPO}" "${LIBRIME_LUA_COMMIT}"
checkout_at "${SRC_DIR}/plugins/lua/thirdparty" "${LIBRIME_LUA_REPO}" "${LIBRIME_LUA_THIRDPARTY_COMMIT}"
[[ -f "${SRC_DIR}/plugins/lua/thirdparty/lua5.4/lua.h" ]] || die "librime-lua thirdparty has no in-tree Lua 5.4"
checkout_at "${SRC_DIR}/plugins/octagram" "${LIBRIME_OCTAGRAM_REPO}" "${LIBRIME_OCTAGRAM_COMMIT}"

# ---------------------------------------------------------------------------
# Static dependencies
# ---------------------------------------------------------------------------

build_dep() {
  local name="$1"; shift
  local build="${WORK_DIR}/build/${name}"
  log "building ${name}"
  cmake -S "${SRC_DIR}/deps/${name}" -B "${build}" "${CMAKE_COMMON[@]}" -DBUILD_SHARED_LIBS=OFF "$@" >"${build}.log" 2>&1 \
    || { tail -n 40 "${build}.log" >&2; die "configure ${name} failed (log: ${build}.log)"; }
  { cmake --build "${build}" --parallel "${JOBS}" && cmake --install "${build}"; } >>"${build}.log" 2>&1 \
    || { tail -n 40 "${build}.log" >&2; die "build ${name} failed (log: ${build}.log)"; }
}

build_dep leveldb \
  -DHAVE_CRC32C=0 -DHAVE_SNAPPY=0 -DHAVE_ZSTD=0 -DHAVE_TCMALLOC=0 \
  -DLEVELDB_BUILD_TESTS=OFF -DLEVELDB_BUILD_BENCHMARKS=OFF -DLEVELDB_INSTALL=ON
build_dep marisa-trie -DBUILD_TESTING=OFF -DENABLE_TOOLS=OFF
build_dep yaml-cpp -DYAML_CPP_BUILD_CONTRIB=OFF -DYAML_CPP_BUILD_TESTS=OFF -DYAML_CPP_BUILD_TOOLS=OFF
build_dep opencc \
  "-DPython3_EXECUTABLE=${PYTHON3}" -DBUILD_DOCUMENTATION=OFF -DENABLE_GTEST=OFF -DENABLE_BENCHMARK=OFF

# ---------------------------------------------------------------------------
# librime with merged plugins
# ---------------------------------------------------------------------------

rime_build="${WORK_DIR}/build/librime"
log "building librime (merged plugins: lua, octagram)"
cmake -S "${SRC_DIR}" -B "${rime_build}" "${CMAKE_COMMON[@]}" \
  -DBUILD_SHARED_LIBS=ON -DBUILD_STATIC=ON -DBUILD_MERGED_PLUGINS=ON \
  -DENABLE_EXTERNAL_PLUGINS=OFF -DBUILD_SEPARATE_LIBS=OFF \
  -DBUILD_TEST=OFF -DBUILD_SAMPLE=OFF -DBUILD_DATA=OFF -DBUILD_TOOLS=OFF \
  -DCMAKE_INSTALL_NAME_DIR=@rpath -DCMAKE_MACOSX_RPATH=ON \
  -DBoost_NO_BOOST_CMAKE=TRUE "-DBOOST_ROOT=${BOOST_DIR}" \
  >"${rime_build}.log" 2>&1 \
  || { tail -n 40 "${rime_build}.log" >&2; die "configure librime failed (log: ${rime_build}.log)"; }
grep -q 'rime_plugins_modules: lua;octagram\|rime_plugins_modules: octagram;lua' "${rime_build}.log" \
  || { grep 'rime_plugins_modules' "${rime_build}.log" >&2 || true; die "librime did not pick up both lua and octagram plugins"; }
cmake --build "${rime_build}" --target rime --parallel "${JOBS}" >>"${rime_build}.log" 2>&1 \
  || { tail -n 60 "${rime_build}.log" >&2; die "build librime failed (log: ${rime_build}.log)"; }

# ---------------------------------------------------------------------------
# Assemble, fix install_name, verify, publish
# ---------------------------------------------------------------------------

built_dylib="$(find "${rime_build}/lib" -maxdepth 1 -type f -name 'librime.*.dylib' | head -n 1)"
[[ -n "${built_dylib}" ]] || die "no librime dylib under ${rime_build}/lib"
opencc_share="${PREFIX}/share/opencc"
[[ -d "${opencc_share}" ]] || die "opencc data not installed at ${opencc_share}"

stage="${OUT_DIR}.staging"
rm -rf "${stage}"
mkdir -p "${stage}/lib" "${stage}/include" "${stage}/share"
cp "${built_dylib}" "${stage}/lib/librime.1.dylib"
chmod u+w "${stage}/lib/librime.1.dylib"
ln -s librime.1.dylib "${stage}/lib/librime.dylib"
for header in "${SRC_DIR}"/src/*.h; do
  [[ "${header}" == *_impl.h ]] || cp "${header}" "${stage}/include/"
done
cp -R "${opencc_share}" "${stage}/share/opencc"

dylib="${stage}/lib/librime.1.dylib"
install_name_tool -id "${INSTALL_ID}" "${dylib}" 2>/dev/null
while read -r rpath; do
  install_name_tool -delete_rpath "${rpath}" "${dylib}" 2>/dev/null
done < <(otool -l "${dylib}" | awk '/cmd LC_RPATH/ {getline; getline; print $2}')
# install_name_tool invalidates the linker signature; restore a loadable one.
# Distribution signing by certificate SHA-1 happens when the dylib is bundled.
codesign --force --sign - "${dylib}" 2>/dev/null

verify_output "${stage}" || die "self-check gate failed; output left in ${stage}"
printf '%s\n' "${LOCK_SHA256}" > "${stage}/.lock-sha256"
rm -rf "${OUT_DIR}"
mkdir -p "$(dirname "${OUT_DIR}")"
mv "${stage}" "${OUT_DIR}"
log "done: ${OUT_DIR} ($(lipo -archs "${OUT_DIR}/lib/librime.1.dylib"), $(du -h "${OUT_DIR}/lib/librime.1.dylib" | awk '{print $1}'))"
