#!/usr/bin/env bash
set -euo pipefail

context=""
namespace="ssdf-system"

usage() {
  echo "usage: $0 --context NAME" >&2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --context) context="$2"; shift 2 ;;
    *) usage; exit 2 ;;
  esac
done

[[ -n "$context" ]] || { usage; exit 2; }
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
for command in base64 helm jq kubectl openssl; do
  command -v "$command" >/dev/null || { echo "missing required command: $command" >&2; exit 1; }
done

k() { kubectl --context "$context" "$@"; }
password_file="$(mktemp)"
chmod 600 "$password_file"
trap 'rm -f "$password_file"' EXIT

# Generate a local-only administrator password if bootstrap has not made one.
# Existing Secret data is never read back into the Helm release or Git values.
if ! k -n "$namespace" get secret grafana-admin >/dev/null 2>&1; then
  openssl rand -hex 32 > "$password_file"
  k -n "$namespace" create secret generic grafana-admin \
    --from-file=admin-password="$password_file" \
    --dry-run=client -o yaml | k apply -f - >/dev/null
fi

k -n "$namespace" wait --for=condition=Ready vaultdynamicsecret/postgres-exporter-credential --timeout=180s
helm upgrade --install observability "$repo_root/charts/observability" \
  --kube-context "$context" --namespace "$namespace" \
  --set grafana.manageAdminSecret=false

for deployment in postgres-exporter prometheus grafana; do
  k -n "$namespace" rollout status "deployment/$deployment" --timeout=300s
done

# Grafana reads GF_SECURITY_ADMIN_PASSWORD only while its SQLite store is first
# initialized. Reconcile the running account with the Kubernetes Secret on
# every bootstrap so a recreated or retained PVC cannot leave the documented
# administrator credential stale. The password moves only over stdin and is
# never rendered into Helm values, command arguments, or logs.
k -n "$namespace" get secret grafana-admin -o jsonpath='{.data.admin-password}' |
  base64 -d |
  k -n "$namespace" exec -i deployment/grafana -- \
    grafana cli admin reset-admin-password --password-from-stdin >/dev/null 2>&1

# The destination must contain only a renewable database username/password pair.
k -n "$namespace" get secret postgres-exporter-credential -o json |
  jq -e '(.data | keys | sort) == ["password", "username"]' >/dev/null

# Make the evidence check through Prometheus, rather than accepting container
# readiness as proof that a target is actually scraped.
for attempt in $(seq 1 12); do
  targets="$(k -n "$namespace" exec deployment/prometheus -- wget -qO- 'http://127.0.0.1:9090/api/v1/query?query=up')"
  if jq -e '[.data.result[] | {job: .metric.job, value: .value[1]}] | sort_by(.job) == [{job:"lnd",value:"1"},{job:"lnd",value:"1"},{job:"lndmon",value:"1"},{job:"postgres",value:"1"}]' <<<"$targets" >/dev/null; then
    break
  fi
  [[ "$attempt" == "12" ]] && { echo "Prometheus has an unhealthy required target" >&2; exit 1; }
  sleep 5
done

# Grafana has no ingress and anonymous access is disabled. Its health endpoint
# confirms the provisioned internal service starts without exposing credentials.
k -n "$namespace" exec deployment/grafana -- sh -ec 'wget -qO- http://127.0.0.1:3000/api/health | grep -q '\''"database": "ok"'\''' >/dev/null

echo "Phase 3 observability bootstrap and scrape gate passed."
