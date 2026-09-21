#!/usr/bin/env bash
# Apply exactly one Chaos Mesh experiment and restore it. Live execution is
# explicit and targets only the TI API Deployment.
set -euo pipefail

[[ "${1:-}" == "--context" && "${2:-}" == "kind-ln-ssdf-phase0" && "${3:-}" == "--experiment" && ("${4:-}" == "pod-failure" || "${4:-}" == "latency") && "${5:-}" == "--confirm-local-chaos" ]] || {
  echo "usage: $0 --context kind-ln-ssdf-phase0 --experiment pod-failure|latency --confirm-local-chaos" >&2
  exit 2
}
context="$2"
experiment="$4"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
for command in kubectl jq; do command -v "$command" >/dev/null || { echo "missing $command" >&2; exit 1; }; done
source "$repo_root/scripts/lib/phase8-local-kind-guard.sh"
require_phase8_local_kind "$context"
"$repo_root/scripts/phase12-chaos-install.sh" --context "$context" --confirm-local-chaos

case "$experiment" in
  pod-failure) resource="podchaos/phase12-ti-api-pod-failure"; field="pod-failure"; manifest="chaos-pod-failure.yaml" ;;
  latency) resource="networkchaos/phase12-ti-api-latency"; field="delay"; manifest="chaos-latency.yaml" ;;
esac
cleanup() {
  kubectl --context "$context" -n chaos-testing delete "$resource" --ignore-not-found --wait=true >/dev/null 2>&1 || true
}
trap cleanup EXIT
kubectl --context "$context" apply -f "$repo_root/manifests/phase12/$manifest" >/dev/null
kubectl --context "$context" -n chaos-testing get "$resource" -o json \
  | jq -e --arg action "$field" '.spec.action == $action and (.spec.selector.namespaces == ["opencti-system"]) and (.spec.selector.labelSelectors.app == "ti-product-api")' >/dev/null
wait_condition() {
  local condition="$1" attempts="$2" status=""
  for _ in $(seq 1 "$attempts"); do
    status="$(kubectl --context "$context" -n chaos-testing get "$resource" -o json 2>/dev/null || true)"
    if [[ -n "$status" ]] && jq -e --arg condition "$condition" \
      'any(.status.conditions[]?; .type == $condition and .status == "True")' <<<"$status" >/dev/null; then
      return 0
    fi
    sleep 2
  done
  echo "Chaos Mesh $experiment did not report $condition=True" >&2
  return 1
}
wait_condition Selected 60
wait_condition AllInjected 60
echo "Phase 12 Chaos Mesh $experiment experiment is active; observe the TI API alert and bounded diagnosis during this window."
sleep 120
wait_condition AllRecovered 60
kubectl --context "$context" -n chaos-testing delete "$resource" --wait=true >/dev/null
kubectl --context "$context" -n opencti-system rollout status deployment/ti-product-api --timeout=180s
echo "Phase 12 Chaos Mesh $experiment drill restored the TI API Deployment."
