#!/usr/bin/env bash
# Prove the bounded Phase 12 alert -> A2A -> pending proposal -> approved
# restart path. This script deliberately does not install charts, controllers,
# or chaos tooling; their dedicated bootstrap scripts remain their owners.
set -euo pipefail

[[ "${1:-}" == "--context" && "${2:-}" == "kind-ln-ssdf-phase0" && "${3:-}" == "--confirm-local-a2a-acceptance" ]] || {
  echo "usage: $0 --context kind-ln-ssdf-phase0 --confirm-local-a2a-acceptance" >&2
  exit 2
}
context="$2"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
for command in curl jq kubectl; do command -v "$command" >/dev/null || { echo "missing required command: $command" >&2; exit 1; }; done
source "$repo_root/scripts/lib/phase8-local-kind-guard.sh"
require_phase8_local_kind "$context"
k() { kubectl --context "$context" "$@"; }
for deployment in alertmanager remediation-controller; do k -n ssdf-system rollout status "deployment/$deployment" --timeout=120s >/dev/null; done
k -n kagent rollout status deployment/kagent-controller --timeout=120s >/dev/null
k -n opencti-system rollout status deployment/ti-product-api --timeout=120s >/dev/null
k -n ssdf-system get remediationrequests.aiops.ln-ssdf.io >/dev/null

before_names="$(k -n ssdf-system get remediationrequests.aiops.ln-ssdf.io -o json | jq -r '.items[]?.metadata.name')"
forward_log="$(mktemp /tmp/phase12-alertmanager-forward-XXXXXX)"
# Alertmanager fingerprints all labels. Keep every drill distinct so an earlier
# firing synthetic alert cannot be deduplicated into a false negative.
alert_run_id="${forward_log##*-}"
k -n ssdf-system port-forward --address 127.0.0.1 deployment/alertmanager 19093:9093 >"$forward_log" 2>&1 &
forward_pid=$!
cleanup() { kill "$forward_pid" >/dev/null 2>&1 || true; rm -f "$forward_log"; }
trap cleanup EXIT
for _ in $(seq 1 30); do
  grep -q 'Forwarding from 127.0.0.1:19093' "$forward_log" && break
  kill -0 "$forward_pid" >/dev/null 2>&1 || { echo "Alertmanager port-forward did not become ready" >&2; exit 1; }
  sleep 1
done
grep -q 'Forwarding from 127.0.0.1:19093' "$forward_log" || { echo "Alertmanager port-forward did not become ready" >&2; exit 1; }
curl --fail --silent http://127.0.0.1:19093/-/ready >/dev/null || { echo "Alertmanager port-forward readiness check failed" >&2; exit 1; }

# Alertmanager owns delivery to the controller. This payload has only an
# allowlisted alert name and no raw log, credential, or TI-document content.
curl --fail --silent -X POST http://127.0.0.1:19093/api/v2/alerts -H 'content-type: application/json' \
  --data "[{\"labels\":{\"alertname\":\"TiApiAvailabilityLow\",\"severity\":\"critical\",\"phase12_acceptance\":\"${alert_run_id}\"},\"annotations\":{\"summary\":\"bounded synthetic Phase 12 acceptance\"}}]" >/dev/null

request_name=""
for _ in $(seq 1 45); do
  request_name="$(k -n ssdf-system get remediationrequests.aiops.ln-ssdf.io -o json | jq -r --arg before "$before_names" '
    .items[]? | .metadata.name as $name
    | select((($before | split("\n")) | index($name)) == null)
    | select(.spec.action == "restartDeployment" and .spec.target == "ti-api" and .spec.namespace == "opencti-system")
    | select(.spec.approved == false and .spec.approvedBy == "pending") | $name' | tail -n 1)"
  [[ -n "$request_name" ]] && break
  sleep 2
done
[[ -n "$request_name" ]] || { echo "kagent A2A diagnosis did not create a new pending ti-api request" >&2; exit 1; }

# The controller cannot patch spec.approved. Only this scoped operator token
# holds the approver Role and it patches the newly observed request.
cat <<'YAML' | k apply -f - >/dev/null
apiVersion: v1
kind: ServiceAccount
metadata: { name: phase12-a2a-operator, namespace: ssdf-system }
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata: { name: phase12-a2a-operator, namespace: ssdf-system }
subjects: [{ kind: ServiceAccount, name: phase12-a2a-operator }]
roleRef: { apiGroup: rbac.authorization.k8s.io, kind: Role, name: remediation-request-approver }
YAML
operator_token="$(k -n ssdf-system create token phase12-a2a-operator --duration=10m)"
[[ "$(k --token="$operator_token" -n ssdf-system auth can-i patch remediationrequests.aiops.ln-ssdf.io)" == "yes" ]] || { echo "scoped operator cannot approve request" >&2; exit 1; }
k --token="$operator_token" -n ssdf-system patch remediationrequest "$request_name" --type=merge -p '{"spec":{"approved":true,"approvedBy":"phase12-a2a-operator"}}' >/dev/null
unset operator_token

phase=""
for _ in $(seq 1 45); do
  phase="$(k -n ssdf-system get remediationrequest "$request_name" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  [[ "$phase" == "Succeeded" || "$phase" == "Failed" || "$phase" == "NeedsHuman" ]] && break
  sleep 2
done
[[ "$phase" == "Succeeded" ]] || { echo "approved A2A proposal did not succeed: ${phase:-unknown}" >&2; exit 1; }
correlation_id="$(k -n ssdf-system get remediationrequest "$request_name" -o jsonpath='{.status.correlationId}')"
[[ "$correlation_id" =~ ^[a-f0-9]{32}$ ]] || { echo "controller did not report a safe restart correlation ID" >&2; exit 1; }
k -n opencti-system get deployment/ti-product-api -o json | jq -e --arg correlation_id "$correlation_id" '.spec.template.metadata.annotations["ln-ssdf.io/last-remediation"] == $correlation_id' >/dev/null

# Shared evidence append is last: no pending proposal or failed action is
# recorded as success. The controller's Kubernetes API endpoint is not a TI
# product route, so only this exact, independently verified controller event is
# normalized to the recorder's bounded `none` endpoint vocabulary.
evidence="$(k -n ssdf-system get remediationrequest "$request_name" -o json | jq -ce --arg correlation_id "$correlation_id" '
  .status.evidence
  | select((keys | sort) == ["amount_sat","correlation_id","endpoint","event","outcome","subject"])
  | select(.event == "remediation" and .subject == "ti-api" and .outcome == "passed")
  | select(.endpoint == "kubernetes-api" and .amount_sat == 0 and .correlation_id == $correlation_id)
  | {event, subject, outcome, endpoint: "none", amount_sat, correlation_id}
')"
printf '%s\n' "$evidence" | "$repo_root/scripts/record-runtime-evidence.sh" --context "$context" >/dev/null
echo "Phase 12 A2A acceptance passed: Alertmanager firing alert produced a pending ti-api request; scoped operator approval restarted the deployment and appended redacted evidence."
