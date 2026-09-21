#!/usr/bin/env bash
# Install the pinned Chaos Mesh control plane required by the Phase 12 API-only
# drills. This is explicit and local-only; it does not create an experiment.
set -euo pipefail

[[ "${1:-}" == "--context" && "${2:-}" == "kind-ln-ssdf-phase0" && "${3:-}" == "--confirm-local-chaos" ]] || {
  echo "usage: $0 --context kind-ln-ssdf-phase0 --confirm-local-chaos" >&2
  exit 2
}
context="$2"
for command in helm kubectl; do command -v "$command" >/dev/null || { echo "missing $command" >&2; exit 1; }; done
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$repo_root/scripts/lib/phase8-local-kind-guard.sh"
require_phase8_local_kind "$context"

helm repo add chaos-mesh https://charts.chaos-mesh.org --force-update >/dev/null
helm repo update chaos-mesh >/dev/null
helm upgrade --install chaos-mesh chaos-mesh/chaos-mesh \
  --kube-context "$context" --namespace chaos-mesh --create-namespace \
  --version 2.7.2 \
  --set chaosDaemon.runtime=containerd \
  --set chaosDaemon.socketPath=/run/containerd/containerd.sock \
  --wait --timeout 5m >/dev/null
kubectl --context "$context" -n chaos-mesh rollout status deployment/chaos-controller-manager --timeout=180s >/dev/null
kubectl --context "$context" -n chaos-mesh rollout status daemonset/chaos-daemon --timeout=180s >/dev/null
echo "Chaos Mesh 2.7.2 control plane and CRDs are ready for the Phase 12 API-only drill."
