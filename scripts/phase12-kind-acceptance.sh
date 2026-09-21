#!/usr/bin/env bash
# Live Phase 12 acceptance. This is intentionally explicit and local-only:
# it builds/loads the controller, applies its CRDs/RBAC, then uses the current
# kubectl identity as the authorized operator to approve one restart request.
set -euo pipefail

[[ "${1:-}" == "--context" && "${2:-}" == "kind-ln-ssdf-phase0" && "${3:-}" == "--confirm-local-approval" ]] || {
  echo "usage: $0 --context kind-ln-ssdf-phase0 --confirm-local-approval" >&2
  exit 2
}
context="$2"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
for command in docker kind kubectl jq; do command -v "$command" >/dev/null || { echo "missing required command: $command" >&2; exit 1; }; done
source "$repo_root/scripts/lib/phase8-local-kind-guard.sh"
require_phase8_local_kind "$context"

image="ln-ssdf/remediation-controller:phase12"
docker image inspect phase10-l402-adapter:local >/dev/null || {
  echo "Phase 12 local build requires the Phase 10 Node image" >&2
  exit 1
}
docker build --build-arg BASE_IMAGE=phase10-l402-adapter:local -t "$image" "$repo_root/services/remediation-controller"
kind load docker-image --name "${context#kind-}" "$image"
kubectl --context "$context" apply -f "$repo_root/manifests/phase12/remediation-request-crd.yaml"
kubectl --context "$context" apply -f "$repo_root/manifests/phase12/approval-policy.yaml"
kubectl --context "$context" apply -f "$repo_root/manifests/phase12/remediation-controller.yaml"
kubectl --context "$context" apply -f "$repo_root/manifests/phase12/network-policy.yaml"
# kind routes the in-cluster Kubernetes API through the kubernetes Service and
# kube-proxy can DNAT that connection to an Endpoints address on 6443. Add only
# the live Service/endpoint IPs and declared TCP ports, each as an exact /32.
api_service_ip="$(kubectl --context "$context" -n default get service kubernetes -o jsonpath='{.spec.clusterIP}')"
[[ "$api_service_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || {
  echo "could not resolve an IPv4 Kubernetes API Service ClusterIP" >&2
  exit 1
}
api_destinations="$(kubectl --context "$context" -n default get endpoints kubernetes -o json \
  | jq -c '[.subsets[]? as $subset
    | ($subset.ports // [])[] as $port
    | $subset.addresses[]?.ip as $ip
    | select(($ip | test("^([0-9]{1,3}\\.){3}[0-9]{1,3}$")) and ($port.port | type) == "number")
    | {cidr: ($ip + "/32"), port: $port.port}]
    | unique_by([.cidr, .port])')"
jq -e 'length > 0' <<<"$api_destinations" >/dev/null || {
  echo "could not resolve IPv4 Kubernetes API Endpoints and ports" >&2
  exit 1
}
allow_api_destination() {
  local cidr="$1" port="$2"
  if ! kubectl --context "$context" -n ssdf-system get networkpolicy remediation-controller-local-only -o json \
    | jq -e --arg cidr "$cidr" --argjson port "$port" \
      'any(.spec.egress[]?; any(.to[]?; .ipBlock.cidr == $cidr) and any(.ports[]?; .port == $port))' >/dev/null; then
    api_egress_patch="$(jq -cn --arg cidr "$cidr" --argjson port "$port" '[{"op":"add","path":"/spec/egress/-","value":{"to":[{"ipBlock":{"cidr":$cidr}}],"ports":[{"protocol":"TCP","port":$port}]}}]')"
    kubectl --context "$context" -n ssdf-system patch networkpolicy remediation-controller-local-only \
      --type=json -p "$api_egress_patch" >/dev/null
  fi
}
allow_api_destination "$api_service_ip/32" 443
while IFS=$'\t' read -r endpoint_cidr endpoint_port; do
  allow_api_destination "$endpoint_cidr" "$endpoint_port"
done < <(jq -r '.[] | [.cidr, (.port | tostring)] | @tsv' <<<"$api_destinations")
kubectl --context "$context" -n ssdf-system rollout status deployment/remediation-controller --timeout=180s
kubectl --context "$context" -n opencti-system get deployment/ti-product-api >/dev/null

cat <<'YAML' | kubectl --context "$context" apply -f - >/dev/null
apiVersion: v1
kind: ServiceAccount
metadata:
  name: phase12-local-operator
  namespace: ssdf-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: phase12-local-operator
  namespace: ssdf-system
subjects:
  - kind: ServiceAccount
    name: phase12-local-operator
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: remediation-request-approver
YAML

name="phase12-live-approval"
kubectl --context "$context" -n ssdf-system delete remediationrequest "$name" --ignore-not-found >/dev/null
cat <<'YAML' | kubectl --context "$context" apply -f - >/dev/null
apiVersion: aiops.ln-ssdf.io/v1alpha1
kind: RemediationRequest
metadata:
  name: phase12-live-approval
  namespace: ssdf-system
spec:
  action: restartDeployment
  target: ti-api
  namespace: opencti-system
  approved: false
  approvedBy: pending
  approvalExpiresAt: "2099-01-01T00:00:00Z"
  reason: phase12 local SLO recovery acceptance
YAML
# This patch is the operator step. The controller service account has no patch
# permission on the RemediationRequest spec and cannot perform this transition.
operator_token="$(kubectl --context "$context" -n ssdf-system create token phase12-local-operator --duration=10m)"
kubectl --context "$context" --token="$operator_token" -n ssdf-system patch remediationrequest "$name" --type=merge \
  -p '{"spec":{"approved":true,"approvedBy":"local-operator"}}' >/dev/null
unset operator_token
for _ in $(seq 1 30); do
  phase="$(kubectl --context "$context" -n ssdf-system get remediationrequest "$name" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  [[ "$phase" == "Succeeded" || "$phase" == "Failed" || "$phase" == "NeedsHuman" ]] && break
  sleep 2
done
[[ "$phase" == "Succeeded" ]] || { echo "Phase 12 request did not succeed: ${phase:-unknown}" >&2; exit 1; }
kubectl --context "$context" -n opencti-system get deployment/ti-product-api -o json \
  | jq -e '.spec.template.metadata.annotations["ln-ssdf.io/last-remediation"] | test("^[a-f0-9]{32}$")' >/dev/null
kubectl --context "$context" -n ssdf-system get remediationrequest "$name" -o json \
  | jq -e '.status.evidence | (keys | sort) == ["amount_sat","correlation_id","endpoint","event","outcome","subject"]' >/dev/null
echo "Phase 12 live acceptance passed: RBAC-approved CR triggered an actual allowlisted Kubernetes API restart and emitted the six-field recorder event."
