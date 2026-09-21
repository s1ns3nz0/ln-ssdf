#!/usr/bin/env bash

require_phase8_local_kind() {
  local context="$1"
  [[ "$context" == "kind-ln-ssdf-phase0" ]] || { echo "only kind-ln-ssdf-phase0 is permitted" >&2; return 2; }
  command -v docker >/dev/null || { echo "Docker is required to prove the local kind cluster identity" >&2; return 1; }
  [[ "$(docker inspect -f '{{.State.Running}}' ln-ssdf-phase0-control-plane 2>/dev/null)" == "true" ]] || { echo "expected local kind control-plane container is not running" >&2; return 1; }
  local provider_ids
  provider_ids="$(kubectl --context "$context" get nodes -o jsonpath='{range .items[*]}{.spec.providerID}{"\n"}{end}')"
  [[ -n "$provider_ids" ]] && ! grep -Ev '^kind://docker/ln-ssdf-phase0/ln-ssdf-phase0-(control-plane|worker[0-9]*)$' <<<"$provider_ids" >/dev/null || { echo "cluster nodes do not identify as ln-ssdf-phase0 kind nodes" >&2; return 1; }
}
