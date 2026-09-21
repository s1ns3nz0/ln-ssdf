#!/usr/bin/env bash
set -euo pipefail

[[ "${1:-}" == "--context" && "${2:-}" == "kind-ln-ssdf-phase0" ]] || {
  echo "usage: $0 --context kind-ln-ssdf-phase0" >&2
  exit 2
}
context="$2"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

kubectl --context "$context" apply -f "$root/manifests/phase7/diagnostic-enforce-policy.yaml"
kubectl --context "$context" apply --dry-run=server -f "$root/experiments/phase7-diagnostic/lnd-admission-pod.yaml" >/dev/null
echo "Phase 7 diagnostic Enforce admission proof passed."
