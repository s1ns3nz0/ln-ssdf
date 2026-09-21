#!/usr/bin/env bash
# Installs pinned kagent 0.x and applies the bounded Phase 12 agent.
# Phase 10 owns the provider credential; this script never reads .env or a
# Secret value and never passes the key to kagent.
set -euo pipefail

[[ "${1:-}" == "--context" && "${2:-}" == "kind-ln-ssdf-phase0" && "${3:-}" == "--confirm-local-kagent" ]] || {
  echo "usage: $0 --context kind-ln-ssdf-phase0 --confirm-local-kagent" >&2
  exit 2
}
context="$2"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
for command in helm kubectl; do command -v "$command" >/dev/null || { echo "missing required command: $command" >&2; exit 1; }; done
kubectl --context "$context" -n phase10-system get secret phase10-openrouter >/dev/null || {
  echo "missing Phase 10 phase10-openrouter Secret; run Phase 10 bootstrap first" >&2
  exit 1
}
kubectl --context "$context" -n phase10-system get service phase10-agentgateway >/dev/null || {
  echo "missing Phase 10 phase10-agentgateway Service; run Phase 10 bootstrap first" >&2
  exit 1
}
helm upgrade --install kagent-crds oci://ghcr.io/kagent-dev/kagent/helm/kagent-crds \
  --version 0.6.3 --kube-context "$context" --namespace kagent --create-namespace
helm upgrade --install kagent oci://ghcr.io/kagent-dev/kagent/helm/kagent \
  --version 0.6.3 --kube-context "$context" --namespace kagent --create-namespace \
  --set 'rbac.namespaces={kagent}' --set 'controller.watchNamespaces={kagent}' \
  --set providers.default=openAI --set providers.openAI.provider=OpenAI \
  --set-string providers.openAI.model=openrouter/free \
  --set providers.openAI.apiKeySecretRef= --set providers.openAI.apiKeySecretKey= \
  --set-string providers.openAI.config.baseUrl=http://phase10-agentgateway.phase10-system.svc.cluster.local:3000/v1 \
  --set agents.argo-rollouts-agent.enabled=false \
  --set agents.cilium-debug-agent.enabled=false --set agents.cilium-manager-agent.enabled=false \
  --set agents.cilium-policy-agent.enabled=false --set agents.helm-agent.enabled=false \
  --set agents.istio-agent.enabled=false --set agents.k8s-agent.enabled=false \
  --set agents.kgateway-agent.enabled=false --set agents.observability-agent.enabled=false \
  --set agents.promql-agent.enabled=false --set tools.grafana-mcp.enabled=false \
  --set tools.querydoc.enabled=false --set kagent-tools.enabled=false
# The OpenAI-compatible client insists on a nonempty local key field. This is
# a public placeholder only; AgentGateway overwrites the upstream Authorization
# header with its Phase 10 Secret and kagent never receives that real key.
kubectl --context "$context" -n kagent create secret generic phase12-gateway-placeholder \
  --from-literal=OPENAI_API_KEY=phase12-gateway-managed-placeholder \
  --dry-run=client -o yaml | kubectl --context "$context" apply -f - >/dev/null
kubectl --context "$context" apply -f "$repo_root/manifests/phase12/kagent-aiops.yaml"
kubectl --context "$context" -n kagent rollout status deployment/kagent-controller --timeout=180s
kubectl --context "$context" -n kagent rollout status deployment/phase12-aiops --timeout=180s
kubectl --context "$context" -n kagent wait --for=condition=Ready agent/phase12-aiops --timeout=180s
echo "kagent 0.6.3 Phase 12 agent is Ready; provider credential remains owned by AgentGateway."
