#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == "--context" && "${2:-}" == "kind-ln-ssdf-phase0" ]] || { echo "usage: $0 --context kind-ln-ssdf-phase0" >&2; exit 2; }
context="$2"; repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
curl --fail --location --proto '=https' --tlsv1.2 https://kyverno.github.io/kyverno/kyverno-3.9.1.tgz -o "$tmp/kyverno.tgz"
[[ "$(shasum -a 256 "$tmp/kyverno.tgz" | awk '{print $1}')" == "7b7fe51a431b5b133b0ce7eb9dcb222b6a37fb967c163223cf480054ad14d752" ]] || { echo checksum mismatch >&2; exit 1; }
kubectl --context "$context" create namespace kyverno >/dev/null 2>&1 || true
helm upgrade --install kyverno "$tmp/kyverno.tgz" --kube-context "$context" --namespace kyverno
kubectl --context "$context" -n kyverno rollout status deployment/kyverno-admission-controller --timeout=300s
kubectl --context "$context" apply -f "$repo_root/manifests/phase6/policies.yaml"
if kubectl --context "$context" run mutable-tag --image=busybox:1.36 --restart=Never -n ssdf-policy-test --dry-run=server >/dev/null 2>&1; then
  echo "mutable image unexpectedly admitted" >&2
  exit 1
fi
if kubectl --context "$context" run mutable-init-container --image=busybox@sha256:$(printf 'a%.0s' {1..64}) --restart=Never -n ssdf-policy-test --dry-run=server --overrides='{"spec":{"initContainers":[{"name":"mutable-init","image":"busybox:1.36"}]}}' >/dev/null 2>&1; then
  echo "mutable init container unexpectedly admitted" >&2
  exit 1
fi
kubectl --context "$context" get validatingpolicy ssdf-audit-image-digest ssdf-enforce-digest-isolated >/dev/null
echo "Phase 6 Audit and isolated admission gate passed with current Kyverno policy APIs."
