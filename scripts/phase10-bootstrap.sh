#!/usr/bin/env bash
set -euo pipefail

[[ "${1:-}" == "--context" && "${2:-}" == "kind-ln-ssdf-phase0" ]] || {
  echo "usage: $0 --context kind-ln-ssdf-phase0" >&2
  exit 2
}
context="$2"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
env_file="$repo_root/.env"
[[ -r "$env_file" ]] || { echo "Phase 10 requires a readable root .env." >&2; exit 1; }

# Create the namespace and Secret before Deployments can reference it.
kubectl --context "$context" apply -f - <<'YAML' >/dev/null
apiVersion: v1
kind: Namespace
metadata:
  name: phase10-system
YAML
# Deliberately load only the declared runtime variable; never print it or write it to Git.
LLM_MODEL_API="$(env -i sh -c '. "$1"; printf %s "$LLM_MODEL_API"' sh "$env_file")"
[[ -n "$LLM_MODEL_API" ]] || { echo "Phase 10 requires LLM_MODEL_API in .env." >&2; exit 1; }
kubectl --context "$context" -n phase10-system create secret generic phase10-openrouter \
  --from-literal=LLM_MODEL_API="$LLM_MODEL_API" --dry-run=client -o yaml | \
  kubectl --context "$context" apply -f - >/dev/null
unset LLM_MODEL_API
kubectl --context "$context" apply -f "$repo_root/manifests/phase10/l402-adapter.yaml"
echo "Phase 10 bootstrap prepared the local adapter and AgentGateway runtime Secret."
