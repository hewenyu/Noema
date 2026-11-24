#!/usr/bin/env bash
# Run the Swift Testing suites with CommandLineTools only (no Xcode.app, no XCTest).
# CLT ships Testing.framework outside the default search paths, so pass them explicitly.
# Extra arguments go to `swift test`, e.g. scripts/dev/test.sh --filter CRimeTests
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CLT_DIR="$(xcode-select -p)"
FRAMEWORKS="${CLT_DIR}/Library/Developer/Frameworks"
INTEROP_LIB="${CLT_DIR}/Library/Developer/usr/lib"
LIBRIME_DIR="${REPO_ROOT}/vendor-out/librime"

fail() {
  printf 'test.sh: %s\n' "$1" >&2
  printf '  fix: %s\n' "$2" >&2
  exit 1
}

[[ -d "${FRAMEWORKS}/Testing.framework" ]] \
  || fail "Testing.framework not found under ${FRAMEWORKS}" "xcode-select --install (Swift 6.2+ CommandLineTools)"
[[ -f "${INTEROP_LIB}/lib_TestingInterop.dylib" ]] \
  || fail "lib_TestingInterop.dylib not found under ${INTEROP_LIB}" "softwareupdate --install the latest Command Line Tools for Xcode"
[[ -f "${LIBRIME_DIR}/lib/librime.1.dylib" ]] \
  || fail "librime not built: ${LIBRIME_DIR}/lib/librime.1.dylib is missing" "scripts/build/librime.sh"
# A stale build would let tests pass against the wrong librime inputs.
LOCK_SHA256="$(shasum -a 256 "${REPO_ROOT}/vendor/librime.lock" | awk '{print $1}')"
BUILT_SHA256="$(cat "${LIBRIME_DIR}/.lock-sha256" 2>/dev/null || true)"
[[ "${BUILT_SHA256}" == "${LOCK_SHA256}" ]] \
  || fail "vendor-out/librime was built from a different vendor/librime.lock (built ${BUILT_SHA256:-<none>}, lock ${LOCK_SHA256})" "scripts/build/librime.sh"
"${REPO_ROOT}/scripts/build/librime.sh" --verify --out "${LIBRIME_DIR}" \
  || fail "vendor-out/librime fails the self-check gate" "scripts/build/librime.sh --force"

cd "${REPO_ROOT}"
exec swift test \
  --disable-xctest \
  --enable-swift-testing \
  -Xswiftc -F -Xswiftc "${FRAMEWORKS}" \
  -Xlinker -F -Xlinker "${FRAMEWORKS}" \
  -Xlinker -rpath -Xlinker "${FRAMEWORKS}" \
  -Xlinker -rpath -Xlinker "${INTEROP_LIB}" \
  -Xlinker -rpath -Xlinker "${LIBRIME_DIR}/lib" \
  "$@"
