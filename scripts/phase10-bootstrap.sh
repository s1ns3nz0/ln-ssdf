#!/usr/bin/env bash
set -euo pipefail

[[ "${1:-}" == "--context" && "${2:-}" == "kind-ln-ssdf-phase0" ]] || {
  echo "usage: $0 --context kind-ln-ssdf-phase0" >&2
  exit 2
}
context="$2"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
for command in docker kubectl jq; do command -v "$command" >/dev/null || { echo "missing required command: $command" >&2; exit 1; }; done
node=ln-ssdf-phase0-control-plane
host_ip="$(docker exec "$node" getent hosts host.docker.internal | awk 'NR == 1 { print $1 }')"
[[ "$host_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || { echo "cannot resolve an IPv4 Docker host address" >&2; exit 1; }
docker exec "$node" curl -fsS --max-time 5 http://host.docker.internal:11434/api/tags | \
  jq -e 'any(.models[]?; .name == "gpt-oss:20b")' >/dev/null || {
    echo "local Ollama gpt-oss:20b is not reachable from kind" >&2
    exit 1
  }

# Create the namespace before applying the local AgentGateway and adapter.
kubectl --context "$context" apply -f - <<'YAML' >/dev/null
apiVersion: v1
kind: Namespace
metadata:
  name: phase10-system
YAML
kubectl --context "$context" apply -f "$repo_root/manifests/phase10/l402-adapter.yaml"
kubectl --context "$context" -n phase10-system patch networkpolicy phase10-agentgateway-egress \
  --type=json -p "$(jq -nc --arg cidr "$host_ip/32" '[{"op":"replace","path":"/spec/egress/1/to/0/ipBlock/cidr","value":$cidr}]')" >/dev/null
kubectl --context "$context" -n phase10-system rollout restart deployment/phase10-agentgateway >/dev/null
kubectl --context "$context" -n phase10-system rollout status deployment/phase10-agentgateway --timeout=120s
echo "Phase 10 bootstrap prepared AgentGateway for local Ollama gpt-oss:20b and retained the L402 adapter."
