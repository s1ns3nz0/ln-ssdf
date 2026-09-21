#!/usr/bin/env bash
set -euo pipefail

[[ "${1:-}" == "--context" && "${2:-}" == "kind-ln-ssdf-phase0" ]] || {
  echo "usage: $0 --context kind-ln-ssdf-phase0" >&2
  exit 2
}
context="$2"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
image="phase10-l402-adapter:local"

docker build --pull -t "$image" "$repo_root/integrations/agentgateway"
kind load docker-image --name "${context#kind-}" "$image"
agentgateway_image="phase10-agentgateway:local"
agentgateway_commit="91182a58528fee5dd8d6f86906716281d8c45c3f"
if [[ -n "${AGENTGATEWAY_PHASE10_CHECKOUT:-}" ]]; then
  agentgateway_checkout="$AGENTGATEWAY_PHASE10_CHECKOUT"
else
  agentgateway_checkout="$(mktemp -d)"
  trap 'rm -rf "$agentgateway_checkout"' EXIT
  git clone --no-checkout https://github.com/agentgateway/agentgateway.git "$agentgateway_checkout"
  git -C "$agentgateway_checkout" checkout --detach "$agentgateway_commit"
  git -C "$agentgateway_checkout" apply "$repo_root/integrations/agentgateway/native-l402.patch"
fi
[[ -f "$agentgateway_checkout/Dockerfile" ]] || { echo "missing AgentGateway checkout: $agentgateway_checkout" >&2; exit 1; }
docker build \
  -f "$repo_root/integrations/agentgateway/Dockerfile.agentgateway-headless" \
  -t "$agentgateway_image" "$agentgateway_checkout"
kind load docker-image --name "${context#kind-}" "$agentgateway_image"
echo "Built and loaded $image for $context. Apply manifests/phase10 after configuring an Aperture-compatible backend."
