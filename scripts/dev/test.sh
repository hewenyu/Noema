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
