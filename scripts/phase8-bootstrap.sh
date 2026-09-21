#!/usr/bin/env bash
set -euo pipefail

[[ "${1:-}" == "--context" && "${2:-}" == "kind-ln-ssdf-phase0" ]] || {
  echo "usage: $0 --context kind-ln-ssdf-phase0" >&2
  exit 2
}
context="$2"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
revision="$(git -C "$repo_root" rev-parse HEAD)"
synced_revision="$(kubectl --context "$context" -n argocd get application observability -o jsonpath='{.status.sync.revision}')"
[[ "$synced_revision" == "$revision" ]] || {
  echo "Phase 8 bootstrap requires observability to be synced from Git revision $revision (got $synced_revision)." >&2
  exit 1
}

kubectl --context "$context" -n ssdf-system exec -i ssdf-postgres-0 -- \
  psql -U postgres -d ssdf -v ON_ERROR_STOP=1 < "$repo_root/db/migrations/phase8-evidence-integrity.sql"
kubectl --context "$context" -n ssdf-system exec ssdf-postgres-0 -- \
  psql -U postgres -d ssdf -v ON_ERROR_STOP=1 -c 'GRANT CONNECT ON DATABASE ssdf TO postgres_monitor;' >/dev/null
kubectl --context "$context" -n ssdf-system rollout status deployment/postgres-exporter --timeout=180s
kubectl --context "$context" -n ssdf-system rollout status deployment/prometheus --timeout=180s

for _ in $(seq 1 15); do
  metric="$(kubectl --context "$context" -n ssdf-system exec deploy/postgres-exporter -- sh -c \
    'wget -qO- http://127.0.0.1:9187/metrics | awk "$1 == \"ssdf_evidence_chain_tamper_detected\" { print $2 }"')"
  [[ "$metric" == "0" ]] && break
  sleep 3
done
[[ "${metric:-}" == "0" ]] || { echo "evidence integrity metric did not reach healthy value 0" >&2; exit 1; }
echo "Phase 8 bootstrap passed: evidence chain metric is healthy."
