#!/usr/bin/env bash
# Run every governance gate: doc word budgets, Agent Note format, Markdown links,
# and the NoemaIME / CLT-only / Kiln boundary checks. CI runs this as ci/governance.
#
# Usage: scripts/governance/check.sh [--base <git-ref>]
#   --base <ref>  also reject raised doc ceilings and edits to frozen notes relative to
#                 the merge-base with <ref>; ignored outside a git work tree (Kiln
#                 workspaces carry no .git).
#
# Runs every gate even after a failure, then exits 1 if any failed (2 on usage errors).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GOV="${REPO_ROOT}/scripts/governance"
cd "${REPO_ROOT}"

BASE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --base)
      [[ $# -ge 2 && -n "$2" && "$2" != -* ]] || { echo "check.sh: --base needs a git ref" >&2; exit 2; }
      BASE="$2"; shift 2 ;;
    -h | --help) sed -n '2,10p' "$0"; exit 0 ;;
    *) echo "check.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done

command -v node >/dev/null || { echo "check.sh: node (>= 18) is required for the governance verifiers" >&2; exit 2; }
node_major="$(node -p 'process.versions.node.split(".")[0]')"
(( node_major >= 18 )) || { echo "check.sh: node ${node_major} is older than 18" >&2; exit 2; }

base_args=()
if [[ -n "${BASE}" ]]; then
  if git -C "${REPO_ROOT}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    base_args=(--base "${BASE}")
  else
    echo "check.sh: not a git work tree; ignoring --base ${BASE}" >&2
  fi
fi

failed=()
run() {
  local name="$1"; shift
  printf '==> %s\n' "${name}"
  if ! "$@"; then failed+=("${name}"); fi
}

# ${arr[@]+...} keeps bash 3.2 (macOS /bin/bash) from treating an empty array as unbound.
run verify-doc-budgets node "${GOV}/verify-doc-budgets.mjs" --root "${REPO_ROOT}" ${base_args[@]+"${base_args[@]}"}
run verify-agent-notes node "${GOV}/verify-agent-notes.mjs" --root "${REPO_ROOT}" ${base_args[@]+"${base_args[@]}"}
run verify-md-links node "${GOV}/verify-md-links.mjs" --root "${REPO_ROOT}" \
  --exclude '.build/**' --exclude '.swiftpm/**' --exclude 'vendor-out/**' --exclude 'dist/**'
run check-imports "${GOV}/check-imports.sh"

if (( ${#failed[@]} > 0 )); then
  printf 'governance: FAILED: %s\n' "${failed[*]}" >&2
  exit 1
fi
echo "governance: ok"
