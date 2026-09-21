#!/usr/bin/env bash
set -euo pipefail

[[ "${1:-}" == "--context" && "${2:-}" == "kind-ln-ssdf-phase0" ]] || {
  echo "usage: $0 --context kind-ln-ssdf-phase0" >&2
  exit 2
}
context="$2"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$repo_root/scripts/lib/phase8-local-kind-guard.sh"
require_phase8_local_kind "$context"
revision="$(git -C "$repo_root" rev-parse HEAD)"
synced_revision="$(kubectl --context "$context" -n argocd get application observability -o jsonpath='{.status.sync.revision}')"
[[ "$synced_revision" == "$revision" ]] || {
  echo "Phase 8 bootstrap requires observability to be synced from Git revision $revision (got $synced_revision)." >&2
  exit 1
}
policy_revision="$(kubectl --context "$context" -n argocd get application phase8-network-policy -o jsonpath='{.status.sync.revision}')"
[[ "$policy_revision" == "$revision" ]] || {
  echo "Phase 8 bootstrap requires network policy to be synced from Git revision $revision (got $policy_revision)." >&2
  exit 1
}

kubectl --context "$context" -n ssdf-system exec -i ssdf-postgres-0 -- \
  psql -U postgres -d ssdf -v ON_ERROR_STOP=1 < "$repo_root/db/migrations/phase8-evidence-integrity.sql"
kubectl --context "$context" -n ssdf-system exec ssdf-postgres-0 -- \
  psql -U postgres -d ssdf -v ON_ERROR_STOP=1 -c 'GRANT CONNECT ON DATABASE ssdf TO postgres_monitor;' >/dev/null
kubectl --context "$context" -n ssdf-system rollout status deployment/postgres-exporter --timeout=180s
# Prometheus does not watch ConfigMap-mounted rule files by itself. Reload the
# Git-synced rule revision before asserting that the alert path is live.
kubectl --context "$context" -n ssdf-system rollout restart deployment/prometheus >/dev/null
kubectl --context "$context" -n ssdf-system rollout status deployment/prometheus --timeout=180s

for _ in $(seq 1 15); do
  metric="$(kubectl --context "$context" -n ssdf-system exec deploy/postgres-exporter -- sh -c \
    "wget -qO- http://127.0.0.1:9187/metrics | grep '^ssdf_evidence_chain_tamper_detected' | cut -d' ' -f2")"
  [[ "$metric" == "0" ]] && break
  sleep 3
done
[[ "${metric:-}" == "0" ]] || { echo "evidence integrity metric did not reach healthy value 0" >&2; exit 1; }
kubectl --context "$context" -n ssdf-system get networkpolicy \
  postgres-exporter-observability-only prometheus-grafana-ingress-only >/dev/null
postgres_up="$(kubectl --context "$context" -n ssdf-system exec deploy/prometheus -- sh -c \
  'wget -qO- "http://127.0.0.1:9090/api/v1/query?query=up%7Bjob%3D%22postgres%22%7D"' \
  | jq -r '.data.result[].value[1]')"
[[ "$postgres_up" == "1" ]] || { echo "Prometheus cannot scrape the policy-restricted postgres exporter" >&2; exit 1; }
if kubectl --context "$context" -n ssdf-system exec deploy/postgres-exporter -- \
  sh -c 'wget -T 3 -qO- http://prometheus:9090/-/ready' >/dev/null 2>&1; then
  echo "postgres exporter unexpectedly reached Prometheus despite its egress policy" >&2
  exit 1
fi
echo "Phase 8 bootstrap passed: evidence chain metric is healthy."
