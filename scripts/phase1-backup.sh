#!/usr/bin/env bash
set -euo pipefail

context=""
state_dir=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --context) context="$2"; shift 2 ;;
    --state-dir) state_dir="$2"; shift 2 ;;
    *) echo "usage: $0 --context NAME --state-dir ABSOLUTE_PATH" >&2; exit 2 ;;
  esac
done

[[ -n "$context" && "$state_dir" = /* ]] || { echo "--context and absolute --state-dir are required" >&2; exit 2; }
for command in jq kubectl; do command -v "$command" >/dev/null || exit 1; done
[[ -f "$state_dir/unsealer-init.json" && -f "$state_dir/main-init.json" ]] || { echo "missing Vault recovery material" >&2; exit 1; }
umask 077
mkdir -p "$state_dir/snapshots"
chmod 700 "$state_dir/snapshots"

snapshot() {
  local pod="$1"
  local init_file="$2"
  local destination="$3"
  local root_token
  root_token="$(jq -er '.root_token' "$init_file")"
  kubectl --context "$context" -n vault-system exec "$pod" -- \
    env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN="$root_token" \
    vault operator raft snapshot save /tmp/phase1.snapshot >/dev/null
  kubectl --context "$context" -n vault-system cp "$pod:/tmp/phase1.snapshot" "$destination"
  chmod 600 "$destination"
}

snapshot unsealer-vault-0 "$state_dir/unsealer-init.json" "$state_dir/snapshots/unsealer-vault.snap"
snapshot main-vault-0 "$state_dir/main-init.json" "$state_dir/snapshots/main-vault.snap"
echo "Phase 1 Raft snapshots written under $state_dir/snapshots"
