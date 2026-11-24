#!/usr/bin/env bash
# Check that this machine can build and test Noema with CommandLineTools only.
# Exit 0 when every required check passes; warnings never fail the run.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
failures=0
warnings=0

ok() { printf '  ok    %s\n' "$1"; }
warn() { printf '  warn  %s\n' "$1"; warnings=$((warnings + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; [[ -n "${2:-}" ]] && printf '        fix: %s\n' "$2"; failures=$((failures + 1)); }

echo "Toolchain"
CLT_DIR="$(xcode-select -p 2>/dev/null || true)"
if [[ -z "${CLT_DIR}" ]]; then
  bad "xcode-select -p: no developer directory" "xcode-select --install"
elif [[ "${CLT_DIR}" == *Xcode*.app* ]]; then
  bad "developer directory is ${CLT_DIR}; Noema builds with CommandLineTools only" \
    "sudo xcode-select -s /Library/Developer/CommandLineTools"
else
  ok "developer directory ${CLT_DIR}"
fi

swift_version="$(swift --version 2>/dev/null | sed -n 's/.*Swift version \([0-9][0-9]*\.[0-9][0-9]*\).*/\1/p' | head -n 1)"
if [[ -z "${swift_version}" ]]; then
  bad "swift not found" "xcode-select --install"
elif [[ "$(printf '%s\n6.2\n' "${swift_version}" | sort -t. -k1,1n -k2,2n | head -n 1)" != "6.2" ]]; then
  bad "Swift ${swift_version} is older than 6.2" "softwareupdate --install the latest Command Line Tools"
else
  ok "Swift ${swift_version}"
fi

sdk_version="$(xcrun --sdk macosx --show-sdk-version 2>/dev/null || true)"
if [[ "${sdk_version%%.*}" =~ ^[0-9]+$ ]] && (( ${sdk_version%%.*} >= 26 )); then
  ok "macOS SDK ${sdk_version} ($(xcrun --sdk macosx --show-sdk-path))"
else
  bad "macOS 26 SDK not found (got '${sdk_version}')" "softwareupdate --install the latest Command Line Tools"
fi

for item in \
  "Library/Developer/Frameworks/Testing.framework" \
  "Library/Developer/usr/lib/lib_TestingInterop.dylib" \
  "usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"; do
  if [[ -e "${CLT_DIR}/${item}" ]]; then
    ok "${item##*/}"
  else
    bad "${CLT_DIR}/${item} missing (Swift Testing under CLT)" "softwareupdate --install the latest Command Line Tools"
  fi
done

for tool in cmake make git curl codesign otool install_name_tool lipo; do
  if path="$(command -v "${tool}")"; then
    ok "${tool} (${path})"
  else
    hint="xcode-select --install"
    [[ "${tool}" == cmake ]] && hint="install CMake 3.12+ (e.g. https://cmake.org/download/)"
    bad "${tool} not found" "${hint}"
  fi
done
if python3_path="$(xcrun -f python3 2>/dev/null)"; then
  ok "python3 (${python3_path})"
else
  bad "xcrun -f python3 failed (needed to build OpenCC data)" "xcode-select --install"
fi

echo "librime"
LIBRIME_DIR="${REPO_ROOT}/vendor-out/librime"
if [[ ! -f "${LIBRIME_DIR}/lib/librime.1.dylib" ]]; then
  warn "vendor-out/librime not built yet; run scripts/build/librime.sh"
elif verify_output="$("${REPO_ROOT}/scripts/build/librime.sh" --verify 2>&1)"; then
  lock_sha="$(shasum -a 256 "${REPO_ROOT}/vendor/librime.lock" | awk '{print $1}')"
  if [[ "$(cat "${LIBRIME_DIR}/.lock-sha256" 2>/dev/null)" == "${lock_sha}" ]]; then
    ok "vendor-out/librime matches vendor/librime.lock and passes the self-check gate"
  else
    warn "vendor-out/librime was built from a different vendor/librime.lock; run scripts/build/librime.sh"
  fi
else
  printf '%s\n' "${verify_output}" | sed 's/^/        /'
  bad "vendor-out/librime fails the self-check gate" "scripts/build/librime.sh --force"
fi

echo "Code signing (informational)"
identities="$(security find-identity -v -p codesigning 2>/dev/null | grep -E '^[[:space:]]+[0-9]+\)' || true)"
if [[ -z "${identities}" ]]; then
  warn "no valid codesigning identity; building and testing work, signed bundles need one"
else
  printf '%s\n' "${identities}" | sed 's/^[[:space:]]*/        /'
  duplicate_sha="$(printf '%s\n' "${identities}" | awk '{print $2}' | sort | uniq -d)"
  duplicate_cn="$(printf '%s\n' "${identities}" | awk '{print $2, $0}' | sort -u -k1,1 \
    | sed -n 's/.*"\(.*\)".*/\1/p' | sort | uniq -d)"
  if [[ -n "${duplicate_sha}" ]]; then
    warn "the same certificate appears more than once in the keychain search list (SHA-1 ${duplicate_sha//$'\n'/, }); sign with the SHA-1, never the name, or delete the duplicate keychain entry"
  fi
  if [[ -n "${duplicate_cn}" ]]; then
    warn "different certificates share the name '${duplicate_cn//$'\n'/, }'; codesign -s <name> is ambiguous, sign with the SHA-1"
  fi
  [[ -z "${duplicate_sha}${duplicate_cn}" ]] && ok "no duplicate identities"
fi

echo
if (( failures > 0 )); then
  echo "doctor: ${failures} failed, ${warnings} warning(s)"
  exit 1
fi
echo "doctor: ok, ${warnings} warning(s)"
