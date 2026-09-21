#!/usr/bin/env bash
# Publish a combined Phase 11 + Phase 12 observability chart revision to the
# in-cluster Git source. ArgoCD remains the owner of alertmanager-config; this
# never patches the live ConfigMap directly. This is not run automatically.
set -euo pipefail

[[ "${1:-}" == "--context" && "${2:-}" == "kind-ln-ssdf-phase0" && "${3:-}" == "--confirm-local-alert-routing" ]] || {
  echo "usage: $0 --context kind-ln-ssdf-phase0 --confirm-local-alert-routing" >&2
  exit 2
}
context="$2"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
for command in git kubectl jq rg sed; do command -v "$command" >/dev/null || { echo "missing required command: $command" >&2; exit 1; }; done
source "$repo_root/scripts/lib/phase8-local-kind-guard.sh"
require_phase8_local_kind "$context"
k() { kubectl --context "$context" "$@"; }
temporary_dir="$(mktemp -d)"
cleanup() { rm -rf "$temporary_dir"; }
trap cleanup EXIT

git clone --quiet "$repo_root" "$temporary_dir/overlay"
cp "$repo_root/charts/observability/templates/stack.yaml" \
  "$temporary_dir/overlay/charts/observability/templates/stack.yaml"
sed 's/^  enabled: false$/  enabled: true/' \
  "$repo_root/charts/observability/values.yaml" \
  > "$temporary_dir/overlay/charts/observability/values.yaml"

stack="$temporary_dir/overlay/charts/observability/templates/stack.yaml"
awk '
  $0 == "    route: { receiver: local-operator-context }" {
    print "    route:"
    print "      receiver: local-operator-context"
    print "      group_wait: 5s"
    print "      group_interval: 5s"
    print "      repeat_interval: 30s"
    print "      routes:"
    print "        - receiver: phase12-aiops"
    print "          continue: true"
    print "          matchers: [alertname=~\"TiProductFailureRateHigh|TiApiAvailabilityLow|TiApiScrapeDown\"]"
    route_found = 1
    next
  }
  $0 == "        webhook_configs: [{ url: http://operator-context:8080/alertmanager }]" {
    print
    print "      - name: phase12-aiops"
    print "        webhook_configs: [{ url: http://remediation-controller.ssdf-system.svc.cluster.local:8080/alertmanager, send_resolved: true }]"
    receiver_found = 1
    next
  }
  $0 == "          - alert: TelemetryExportFailed" {
    print "          - alert: TiApiScrapeDown"
    print "            expr: up{job=\"ti-product-api\"} == 0"
    print "            for: 0m"
    print "            labels: { severity: critical }"
  }
  $0 == "    metadata: { labels: { app: alertmanager } }" {
    print "    metadata:"
    print "      labels: { app: alertmanager }"
    print "      annotations: { phase12.ln-ssdf.io/alertmanager-config: \"v2\" }"
    rollout_found = 1
    next
  }
  $0 == "    metadata: { labels: { app: prometheus } }" {
    print "    metadata:"
    print "      labels: { app: prometheus }"
    print "      annotations: { phase12.ln-ssdf.io/prometheus-rules: \"v2\" }"
    prometheus_rollout_found = 1
    next
  }
  { print }
  END {
    if (!route_found || !receiver_found || !rollout_found || !prometheus_rollout_found) exit 1
  }
' "$stack" > "$stack.new"
mv "$stack.new" "$stack"
rg -q 'TiProductFailureRateHigh\|TiApiAvailabilityLow\|TiApiScrapeDown' "$stack" || { echo "Phase 12 route was not added" >&2; exit 1; }
rg -q 'alert: TiApiScrapeDown' "$stack" || { echo "Phase 12 scrape-down rule was not added" >&2; exit 1; }
rg -q 'phase12.ln-ssdf.io/prometheus-rules' "$stack" || { echo "Phase 12 Prometheus rollout annotation was not added" >&2; exit 1; }

git -C "$temporary_dir/overlay" add charts/observability
git -C "$temporary_dir/overlay" -c user.name='ln-ssdf local gate' \
  -c user.email='local-gate@invalid' commit -qm 'test: add Phase 12 alert routing overlay'
overlay_revision="$(git -C "$temporary_dir/overlay" rev-parse HEAD)"
git clone --quiet --bare "$temporary_dir/overlay" "$temporary_dir/overlay.git"
touch "$temporary_dir/overlay.git/git-daemon-export-ok"
git_pod="$(k -n gitops-system get pod -l app=git-server -o jsonpath='{.items[?(@.status.phase=="Running")].metadata.name}')"
[[ -n "$git_pod" ]] || { echo "Phase 12 requires the in-cluster Git server" >&2; exit 1; }
k -n gitops-system exec "$git_pod" -- rm -rf /srv/git/ln-ssdf.git
k -n gitops-system cp "$temporary_dir/overlay.git" "$git_pod:/srv/git/ln-ssdf.git"
k -n argocd annotate application observability argocd.argoproj.io/refresh=hard --overwrite >/dev/null
for attempt in $(seq 1 90); do
  app_status="$(k -n argocd get application observability -o json)"
  if jq -e --arg revision "$overlay_revision" \
    '.status.sync.revision == $revision and .status.sync.status == "Synced" and .status.health.status == "Healthy"' \
    <<<"$app_status" >/dev/null; then break; fi
  [[ "$attempt" == 90 ]] && { echo "ArgoCD did not apply the Phase 12 alert overlay" >&2; exit 1; }
  sleep 2
done
k -n ssdf-system rollout status deployment/alertmanager --timeout=120s >/dev/null
k -n ssdf-system rollout status deployment/prometheus --timeout=120s >/dev/null
echo "Phase 12 Alertmanager routing and Prometheus rules are ArgoCD-owned and include the two Phase11 alerts plus TiApiScrapeDown."
