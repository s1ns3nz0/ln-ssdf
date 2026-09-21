#!/usr/bin/env bash
set -euo pipefail

[[ "${1:-}" == "--context" && "${2:-}" == "kind-ln-ssdf-phase0" ]] || {
  echo "usage: $0 --context kind-ln-ssdf-phase0" >&2
  exit 2
}
context="$2"
for command in curl kubectl rg; do
  command -v "$command" >/dev/null || { echo "missing required command: $command" >&2; exit 1; }
done

kubectl --context "$context" -n ssdf-system rollout status deployment/aperture --timeout=120s >/dev/null
kubectl --context "$context" -n phase10-system rollout status deployment/phase10-l402-adapter --timeout=120s >/dev/null
kubectl --context "$context" -n phase10-system rollout status deployment/phase10-agentgateway --timeout=120s >/dev/null

headers="$(mktemp)"
port_forward_log="$(mktemp)"
port_forward_pid=""
cleanup() {
  if [[ -n "$port_forward_pid" ]]; then
    kill "$port_forward_pid" 2>/dev/null || true
    wait "$port_forward_pid" 2>/dev/null || true
  fi
  rm -f "$headers" "$port_forward_log"
}
trap cleanup EXIT

kubectl --context "$context" -n phase10-system port-forward service/phase10-agentgateway 13080:3000 >"$port_forward_log" 2>&1 &
port_forward_pid=$!
for attempt in $(seq 1 30); do
  if rg -q 'Forwarding from 127.0.0.1:13080' "$port_forward_log"; then break; fi
  kill -0 "$port_forward_pid" 2>/dev/null || { echo "AgentGateway port-forward failed" >&2; exit 1; }
  [[ "$attempt" == 30 ]] && { echo "AgentGateway port-forward timed out" >&2; exit 1; }
  sleep 1
done

status="$(curl --silent --show-error --max-time 20 -D "$headers" -o /dev/null -w '%{http_code}' \
  http://127.0.0.1:13080/ti/indicator/phase10-acceptance)"
[[ "$status" == "402" ]] || { echo "AgentGateway did not forward L402 challenge (HTTP $status)" >&2; exit 1; }
rg -qi '^www-authenticate:.*L402' "$headers" || { echo "AgentGateway omitted the L402 challenge header" >&2; exit 1; }

denied="$(curl --silent --show-error --max-time 10 -o /dev/null -w '%{http_code}' \
  http://127.0.0.1:13080/ti/unlisted/phase10-acceptance)"
[[ "$denied" != "200" && "$denied" != "402" ]] || {
  echo "AgentGateway accepted an unallowlisted TI route (HTTP $denied)" >&2
  exit 1
}
echo "Phase 10 live gate passed: gateway forwards Aperture L402 challenge and rejects an unallowlisted TI route."
