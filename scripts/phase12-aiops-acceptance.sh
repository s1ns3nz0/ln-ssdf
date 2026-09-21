#!/usr/bin/env bash
# Live local-only acceptance for the real Phase 12 trigger path:
# Chaos Mesh -> Prometheus -> Alertmanager -> controller -> kagent -> pending CR.
# Approval and execution are opt-in and require --confirm-local-approval.
set -euo pipefail

[[ "${1:-}" == "--context" && "${2:-}" == "kind-ln-ssdf-phase0" && "${3:-}" == "--confirm-local-aiops" ]] || {
  echo "usage: $0 --context kind-ln-ssdf-phase0 --confirm-local-aiops [--confirm-local-approval]" >&2
  exit 2
}
approval_enabled=false
if [[ $# -eq 4 ]]; then
  [[ "$4" == "--confirm-local-approval" ]] || { echo "unknown option: $4" >&2; exit 2; }
  approval_enabled=true
fi
context="$2"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
for command in curl jq kubectl; do command -v "$command" >/dev/null || { echo "missing required command: $command" >&2; exit 1; }; done
source "$repo_root/scripts/lib/phase8-local-kind-guard.sh"
require_phase8_local_kind "$context"

kubectl --context "$context" -n ssdf-system get service prometheus alertmanager remediation-controller >/dev/null
kubectl --context "$context" -n kagent get agent phase12-aiops >/dev/null
kubectl --context "$context" -n ssdf-system get configmap phase11-prometheus-rules -o json \
  | jq -e '.data["phase11.yaml"] | contains("alert: TiApiScrapeDown")' >/dev/null
kubectl --context "$context" -n ssdf-system get configmap alertmanager-config -o json \
  | jq -e '.data["alertmanager.yml"] | contains("TiApiScrapeDown")' >/dev/null
before_names="$(kubectl --context "$context" -n ssdf-system get remediationrequests -o json | jq -c '[.items[]?.metadata.name]')"

temporary_dir="$(mktemp -d)"
prometheus_pid=""
alertmanager_pid=""
chaos_pid=""
cleanup() {
  [[ -n "$chaos_pid" ]] && kill "$chaos_pid" 2>/dev/null || true
  [[ -n "$prometheus_pid" ]] && kill "$prometheus_pid" 2>/dev/null || true
  [[ -n "$alertmanager_pid" ]] && kill "$alertmanager_pid" 2>/dev/null || true
  rm -rf "$temporary_dir"
}
trap cleanup EXIT

report_readiness_failure() {
  echo "Phase 12 AIOps port-forward readiness failed; captured logs:" >&2
  for log_file in "$temporary_dir/prometheus.log" "$temporary_dir/alertmanager.log"; do
    if [[ -f "$log_file" ]]; then
      echo "--- $log_file ---" >&2
      sed -n '1,120p' "$log_file" >&2
    fi
  done
}

kubectl --context "$context" -n ssdf-system port-forward --address 127.0.0.1 service/prometheus 19090:9090 >"$temporary_dir/prometheus.log" 2>&1 &
prometheus_pid=$!
kubectl --context "$context" -n ssdf-system port-forward --address 127.0.0.1 service/alertmanager 19093:9093 >"$temporary_dir/alertmanager.log" 2>&1 &
alertmanager_pid=$!
for _ in $(seq 1 30); do
  curl --silent --fail http://127.0.0.1:19090/-/ready >/dev/null 2>&1 && \
    curl --silent --fail http://127.0.0.1:19093/-/ready >/dev/null 2>&1 && break
  sleep 1
done
if ! curl --silent --fail http://127.0.0.1:19090/-/ready >/dev/null; then
  report_readiness_failure
  exit 1
fi
if ! curl --silent --fail http://127.0.0.1:19093/-/ready >/dev/null; then
  report_readiness_failure
  exit 1
fi

"$repo_root/scripts/phase12-chaos-drill.sh" --context "$context" --experiment pod-failure --confirm-local-chaos \
  >"$temporary_dir/chaos.log" 2>&1 &
chaos_pid=$!

prometheus_seen=false
alertmanager_seen=false
proposal_name=""
for _ in $(seq 1 120); do
  if ! kill -0 "$chaos_pid" 2>/dev/null; then
    set +e
    wait "$chaos_pid"
    chaos_status=$?
    set -e
    echo "Chaos drill exited before the real AIOps proposal was observed (status $chaos_status)." >&2
    echo "--- $temporary_dir/chaos.log ---" >&2
    sed -n '1,160p' "$temporary_dir/chaos.log" >&2
    exit 1
  fi
  if ! $prometheus_seen && curl --silent --fail http://127.0.0.1:19090/api/v1/alerts \
    | jq -e '[.data.alerts[]? | select(.labels.alertname == "TiApiScrapeDown" and (.state == "pending" or .state == "firing"))] | length > 0' >/dev/null; then
    prometheus_seen=true
  fi
  if ! $alertmanager_seen && curl --silent --fail http://127.0.0.1:19093/api/v2/alerts \
    | jq -e '[.[]? | select(.labels.alertname == "TiApiScrapeDown" and .status.state == "active")] | length > 0' >/dev/null; then
    alertmanager_seen=true
  fi
  proposal_name="$(kubectl --context "$context" -n ssdf-system get remediationrequests -o json \
    | jq -r --argjson before "$before_names" '[.items[]? | .metadata.name as $name | select(($before | index($name)) == null) | select(.spec.approved == false and .spec.approvedBy == "pending" and .spec.target == "ti-api" and (.spec.reason | contains("TiApiScrapeDown")))] | .[0].metadata.name // empty')"
  [[ "$prometheus_seen" == true && "$alertmanager_seen" == true && -n "$proposal_name" ]] && break
  sleep 2
done

[[ "$prometheus_seen" == true ]] || { echo "Prometheus did not observe TiApiScrapeDown" >&2; exit 1; }
[[ "$alertmanager_seen" == true ]] || { echo "Alertmanager did not receive active TiApiScrapeDown" >&2; exit 1; }
[[ -n "$proposal_name" ]] || { echo "kagent did not create a pending ti-api RemediationRequest" >&2; exit 1; }
wait "$chaos_pid"
chaos_pid=""
if [[ "$approval_enabled" != true ]]; then
  echo "Phase 12 AIOps path passed: Prometheus -> Alertmanager -> controller -> kagent -> pending RemediationRequest ${proposal_name}; no approval or remediation was performed."
  exit 0
fi

# This is deliberately separate from the default pending-only path. The token
# is minted for a distinct, narrowly bound operator ServiceAccount and is used
# only to approve the newly observed request after Chaos recovery.
cat <<'YAML' | kubectl --context "$context" -n ssdf-system apply -f - >/dev/null
apiVersion: v1
kind: ServiceAccount
metadata: { name: phase12-aiops-operator, namespace: ssdf-system }
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata: { name: phase12-aiops-operator, namespace: ssdf-system }
subjects: [{ kind: ServiceAccount, name: phase12-aiops-operator }]
roleRef: { apiGroup: rbac.authorization.k8s.io, kind: Role, name: remediation-request-approver }
YAML
operator_token="$(kubectl --context "$context" -n ssdf-system create token phase12-aiops-operator --duration=10m)"
[[ "$(kubectl --context "$context" --token="$operator_token" -n ssdf-system auth can-i patch remediationrequests.aiops.ln-ssdf.io)" == "yes" ]] || {
  unset operator_token
  echo "phase12-aiops-operator cannot approve RemediationRequest" >&2
  exit 1
}
kubectl --context "$context" --token="$operator_token" -n ssdf-system patch remediationrequest "$proposal_name" --type=merge \
  -p '{"spec":{"approved":true,"approvedBy":"phase12-aiops-operator"}}' >/dev/null
unset operator_token

phase=""
for _ in $(seq 1 60); do
  phase="$(kubectl --context "$context" -n ssdf-system get remediationrequest "$proposal_name" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  [[ "$phase" == "Succeeded" || "$phase" == "Failed" || "$phase" == "NeedsHuman" ]] && break
  sleep 2
done
[[ "$phase" == "Succeeded" ]] || { echo "approved Chaos proposal did not succeed: ${phase:-unknown}" >&2; exit 1; }

request_json="$(kubectl --context "$context" -n ssdf-system get remediationrequest "$proposal_name" -o json)"
correlation_id="$(jq -r '.status.correlationId // empty' <<<"$request_json")"
[[ "$correlation_id" =~ ^[a-f0-9]{32}$ ]] || { echo "controller did not report a safe remediation correlation ID" >&2; exit 1; }
kubectl --context "$context" -n opencti-system get deployment/ti-product-api -o json \
  | jq -e --arg correlation_id "$correlation_id" '.spec.template.metadata.annotations["ln-ssdf.io/last-remediation"] == $correlation_id' >/dev/null \
  || { echo "TI API deployment lacks the matching remediation annotation" >&2; exit 1; }
jq -e --arg correlation_id "$correlation_id" '
  .status.approvalEvidence.operatorIdentity == "phase12-aiops-operator"
  and .status.approvalEvidence.target == "ti-api"
  and .status.approvalEvidence.action == "restartDeployment"
  and ((.status.evidence | keys | sort) == ["amount_sat","correlation_id","endpoint","event","outcome","subject"])
  and .status.evidence.event == "remediation"
  and .status.evidence.subject == "ti-api"
  and .status.evidence.outcome == "passed"
  and .status.evidence.endpoint == "kubernetes-api"
  and .status.evidence.amount_sat == 0
  and .status.evidence.correlation_id == $correlation_id
' <<<"$request_json" >/dev/null || { echo "approved proposal evidence is missing or not redacted" >&2; exit 1; }
echo "Phase 12 AIOps approval path passed: real Chaos alert produced ${proposal_name}; phase12-aiops-operator approval succeeded with matching TI API annotation and redacted evidence."
