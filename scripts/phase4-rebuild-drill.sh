#!/usr/bin/env bash
# Recreate the local cluster, restore approved runtime-only state, then prove
# ArgoCD reconciles the committed Git source rather than a host path.
set -euo pipefail

context="kind-ln-ssdf-phase0"
state_dir=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --state-dir) state_dir="$2"; shift 2 ;;
    --context) context="$2"; shift 2 ;;
    *) echo "usage: $0 --state-dir ABSOLUTE_PATH [--context kind-ln-ssdf-phase0]" >&2; exit 2 ;;
  esac
done
[[ "$context" == "kind-ln-ssdf-phase0" && "$state_dir" = /* ]] || {
  echo "explicit Phase 0 context and absolute state-dir are required" >&2
  exit 2
}

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
"$repo_root/scripts/phase3-rebuild-drill.sh" --context "$context" --state-dir "$state_dir"
"$repo_root/scripts/phase4-bootstrap.sh" --context "$context"
echo "Phase 4 destructive rebuild drill passed."
