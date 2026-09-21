#!/usr/bin/env bash
set -euo pipefail

context=""
namespace="ssdf-system"

usage() { echo "usage: $0 --context NAME" >&2; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --context) context="$2"; shift 2 ;;
    *) usage; exit 2 ;;
  esac
done
[[ -n "$context" ]] || { usage; exit 2; }

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
for command in curl docker git helm jq kind kubectl rg sed; do
  command -v "$command" >/dev/null || { echo "missing required command: $command" >&2; exit 1; }
done
k() { kubectl --context "$context" "$@"; }
temporary_dir="$(mktemp -d)"
grafana_pid=""
loki_pid=""
prometheus_pid=""
cleanup() {
  if [[ -n "$grafana_pid" ]]; then kill "$grafana_pid" 2>/dev/null || true; wait "$grafana_pid" 2>/dev/null || true; fi
  if [[ -n "$loki_pid" ]]; then kill "$loki_pid" 2>/dev/null || true; wait "$loki_pid" 2>/dev/null || true; fi
  if [[ -n "$prometheus_pid" ]]; then kill "$prometheus_pid" 2>/dev/null || true; wait "$prometheus_pid" 2>/dev/null || true; fi
  rm -rf "$temporary_dir"
}
trap cleanup EXIT

# Replay safely after a rebuild: Phase 3 remains the owner of the metrics base.
if ! k -n "$namespace" get deployment/grafana >/dev/null 2>&1; then
  "$repo_root/scripts/phase3-bootstrap.sh" --context "$context"
fi
docker image inspect phase10-l402-adapter:local >/dev/null || {
  echo "Phase 11 local build requires the Phase 10 Node image" >&2
  exit 1
}
docker build --build-arg BASE_IMAGE=phase10-l402-adapter:local \
  -t operator-context:phase11 "$repo_root/services/operator-context" >/dev/null
kind load docker-image --name "${context#kind-}" operator-context:phase11 >/dev/null
k apply -f "$repo_root/manifests/phase11/operator-context.yaml" >/dev/null
k -n "$namespace" rollout status deployment/operator-context --timeout=180s

# ArgoCD owns the Phase 3 observability release. Publish a local-only Phase 11
# chart revision to its in-cluster Git mirror so self-heal preserves, rather
# than removes, the new scrape and rules. Never change the host main branch.
git clone --quiet "$repo_root" "$temporary_dir/overlay"
cp "$repo_root/charts/observability/templates/stack.yaml" \
  "$temporary_dir/overlay/charts/observability/templates/stack.yaml"
sed 's/^  enabled: false$/  enabled: true/' \
  "$repo_root/charts/observability/values.yaml" \
  > "$temporary_dir/overlay/charts/observability/values.yaml"
rg -q '^  enabled: true$' "$temporary_dir/overlay/charts/observability/values.yaml" || {
  echo "Phase 11 chart overlay could not enable the feature" >&2; exit 1;
}
git -C "$temporary_dir/overlay" add charts/observability
git -C "$temporary_dir/overlay" -c user.name='ln-ssdf local gate' \
  -c user.email='local-gate@invalid' commit -qm 'test: enable Phase 11 local observability overlay'
overlay_revision="$(git -C "$temporary_dir/overlay" rev-parse HEAD)"
git clone --quiet --bare "$temporary_dir/overlay" "$temporary_dir/overlay.git"
touch "$temporary_dir/overlay.git/git-daemon-export-ok"
git_pod="$(k -n gitops-system get pod -l app=git-server -o jsonpath='{.items[?(@.status.phase=="Running")].metadata.name}')"
[[ -n "$git_pod" ]] || { echo "Phase 11 requires the in-cluster Git server" >&2; exit 1; }
k -n gitops-system exec "$git_pod" -- rm -rf /srv/git/ln-ssdf.git
k -n gitops-system cp "$temporary_dir/overlay.git" "$git_pod:/srv/git/ln-ssdf.git"
k -n argocd annotate application observability argocd.argoproj.io/refresh=hard --overwrite >/dev/null
for attempt in $(seq 1 90); do
  app_status="$(k -n argocd get application observability -o json)"
  if jq -e --arg revision "$overlay_revision" \
    '.status.sync.revision == $revision and .status.sync.status == "Synced" and .status.health.status == "Healthy"' \
    <<<"$app_status" >/dev/null; then break; fi
  [[ "$attempt" == 90 ]] && { echo "ArgoCD did not apply the Phase 11 chart overlay" >&2; exit 1; }
  sleep 2
done
for deployment in prometheus alertmanager; do
  k -n "$namespace" rollout status "deployment/$deployment" --timeout=300s
done
k apply -f "$repo_root/manifests/phase11/ti-api-metrics-ingress.yaml" >/dev/null

k -n "$namespace" port-forward service/prometheus 13090:9090 >"$temporary_dir/prometheus-port-forward.log" 2>&1 &
prometheus_pid=$!
for attempt in $(seq 1 30); do
  curl --silent --fail http://127.0.0.1:13090/-/ready >/dev/null && break
  [[ "$attempt" == 30 ]] && { echo "Prometheus port-forward did not become ready" >&2; exit 1; }
  sleep 1
done
for attempt in $(seq 1 30); do
  scrape="$(curl --silent --fail --get http://127.0.0.1:13090/api/v1/query \
    --data-urlencode 'query=up{job="ti-product-api"}')"
  if jq -e '[.data.result[]?.value[1]] | any(. == "1")' <<<"$scrape" >/dev/null; then break; fi
  [[ "$attempt" == 30 ]] && { echo "Prometheus is not scraping the live TI API" >&2; exit 1; }
  sleep 2
done
kill "$prometheus_pid" 2>/dev/null || true
wait "$prometheus_pid" 2>/dev/null || true
prometheus_pid=""

helm upgrade --install phase11-observability "$repo_root/charts/phase11" \
  --kube-context "$context" --namespace "$namespace"
for deployment in loki tempo otel-collector; do
  k -n "$namespace" rollout status "deployment/$deployment" --timeout=300s
done

# Phase 3 owns Prometheus's mounted rule directory. Apply this additive rule
# ConfigMap now; mounting it is deliberately an explicit Phase 3 adapter step
# documented in docs/phase-11.md rather than a fragile live Deployment patch.
k apply -f "$repo_root/manifests/phase11/dashboards.yaml" >/dev/null

# Grafana is deliberately API-provisioned here because Phase 3 owns its Pod
# mounts. Credentials stay in a mode-0600 temporary netrc, never in Helm values.
k -n "$namespace" port-forward service/grafana 13000:3000 >"$temporary_dir/grafana-port-forward.log" 2>&1 &
grafana_pid=$!
for attempt in $(seq 1 30); do
  curl --silent --fail http://127.0.0.1:13000/api/health >/dev/null && break
  [[ "$attempt" == 30 ]] && { echo "Grafana port-forward did not become ready" >&2; exit 1; }
  sleep 1
done
password="$(k -n "$namespace" get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d)"
netrc="$temporary_dir/grafana.netrc"
umask 077
printf 'machine 127.0.0.1 login admin password %s\n' "$password" >"$netrc"
unset password
grafana_api() {
  curl --silent --show-error --netrc-file "$netrc" -H 'Content-Type: application/json' "$@"
}
for datasource in '{"name":"Loki","uid":"phase11-loki","type":"loki","access":"proxy","url":"http://loki:3100","editable":false}' '{"name":"Tempo","uid":"phase11-tempo","type":"tempo","access":"proxy","url":"http://tempo:3200","editable":false}'; do
  status="$(grafana_api -o /dev/null -w '%{http_code}' -X POST http://127.0.0.1:13000/api/datasources --data "$datasource")"
  [[ "$status" == 200 || "$status" == 409 ]] || { echo "Grafana datasource creation failed ($status)" >&2; exit 1; }
done
for dashboard in phase11-dashboard-overview phase11-dashboard-marketplace phase11-dashboard-investigation; do
  k -n "$namespace" get configmap "$dashboard" -o jsonpath='{.data.dashboard\.json}' >"$temporary_dir/$dashboard.json"
  grafana_api --fail -X POST http://127.0.0.1:13000/api/dashboards/db --data @"$temporary_dir/$dashboard.json" >/dev/null
done
kill "$grafana_pid" 2>/dev/null || true
wait "$grafana_pid" 2>/dev/null || true
grafana_pid=""

# A deliberately unique canary proves the Collector redacts before Loki stores
# it. It contains no real credential and the probe Pod is removed afterwards.
k -n "$namespace" run phase11-redaction-probe --rm -i --restart=Never \
  --image=curlimages/curl:8.12.1 --command -- \
  curl --silent --show-error --fail -X POST http://otel-collector:4318/v1/logs \
    -H 'Content-Type: application/json' \
    --data "{\"resourceLogs\":[{\"resource\":{\"attributes\":[{\"key\":\"service.name\",\"value\":{\"stringValue\":\"phase11-redaction-probe\"}}]},\"scopeLogs\":[{\"scope\":{},\"logRecords\":[{\"timeUnixNano\":\"$(date +%s)000000000\",\"body\":{\"stringValue\":\"authorization=phase11-secret macaroon=phase11-secret\"}}]}]}]}" >/dev/null

k -n "$namespace" port-forward service/loki 13100:3100 >"$temporary_dir/loki-port-forward.log" 2>&1 &
loki_pid=$!
for attempt in $(seq 1 30); do
  curl --silent --fail http://127.0.0.1:13100/ready >/dev/null && break
  [[ "$attempt" == 30 ]] && { echo "Loki port-forward did not become ready" >&2; exit 1; }
  sleep 1
done
for attempt in $(seq 1 12); do
  curl --silent --fail --get http://127.0.0.1:13100/loki/api/v1/query_range \
    --data-urlencode 'query={service_name="phase11-redaction-probe"}' >"$temporary_dir/loki.json"
  if rg -q 'REDACTED' "$temporary_dir/loki.json"; then break; fi
  [[ "$attempt" == 12 ]] && { echo "redacted probe log did not reach Loki" >&2; exit 1; }
  sleep 2
done
! rg -q 'phase11-secret' "$temporary_dir/loki.json" || { echo "redaction failure: probe value reached Loki" >&2; exit 1; }

echo "Phase 11 Loki, Tempo, Collector, dashboards, and redaction gate passed."
