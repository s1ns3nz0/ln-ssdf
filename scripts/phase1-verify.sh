#!/usr/bin/env bash
set -euo pipefail

context=""
state_dir=""

usage() {
  echo "usage: $0 --context NAME --state-dir ABSOLUTE_PATH" >&2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --context) context="$2"; shift 2 ;;
    --state-dir) state_dir="$2"; shift 2 ;;
    *) usage; exit 2 ;;
  esac
done

[[ -n "$context" && -n "$state_dir" && "$state_dir" = /* ]] || { usage; exit 2; }
for command in base64 jq kubectl; do
  command -v "$command" >/dev/null || { echo "missing required command: $command" >&2; exit 1; }
done

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
case "$state_dir" in
  "$repo_root"|"$repo_root"/*) echo "state-dir must be outside the repository" >&2; exit 2 ;;
esac

for init_file in unsealer-init.json main-init.json; do
  [[ -f "$state_dir/$init_file" ]] || { echo "missing recovery file: $init_file" >&2; exit 1; }
  [[ "$(stat -f '%Lp' "$state_dir/$init_file" 2>/dev/null || stat -c '%a' "$state_dir/$init_file")" == "600" ]] || {
    echo "recovery file must have mode 600: $init_file" >&2; exit 1;
  }
done

k() { kubectl --context "$context" "$@"; }
vault_status() {
  k -n vault-system exec "$1" -- env VAULT_ADDR=http://127.0.0.1:8200 vault status -format=json 2>/dev/null || true
}

k -n vault-system rollout status statefulset/unsealer-vault --timeout=180s
k -n vault-system rollout status statefulset/main-vault --timeout=180s
k -n vault-system rollout status deployment/vault-secrets-operator-controller-manager --timeout=180s

unsealer_status="$(vault_status unsealer-vault-0)"
main_status="$(vault_status main-vault-0)"
printf '%s' "$unsealer_status" | jq -e '.initialized == true and .sealed == false and .type == "shamir" and .storage_type == "raft"' >/dev/null
printf '%s' "$main_status" | jq -e '.initialized == true and .sealed == false and .type == "transit" and .storage_type == "raft"' >/dev/null

k -n ssdf-system get vaultconnection main-vault -o json | jq -e '.status.valid == true' >/dev/null
k -n ssdf-system get vaultauth ssdf-database-auth -o json | jq -e '.status.valid == true' >/dev/null
k -n ssdf-system get vaultdynamicsecret lnd-db-credential -o json | jq -e '
  .status.secretLease.duration == 3600 and
  .status.secretLease.renewable == true and
  (.status.conditions[] | select(.type == "Ready" and .status == "True"))
' >/dev/null
k -n ssdf-system get secret lnd-db-credential -o json | jq -e '.data | keys == ["password", "username"]' >/dev/null

db_user="$(k -n ssdf-system get secret lnd-db-credential -o jsonpath='{.data.username}' | base64 -d)"
db_password="$(k -n ssdf-system get secret lnd-db-credential -o jsonpath='{.data.password}' | base64 -d)"
k -n ssdf-system exec ssdf-postgres-0 -- env PGPASSWORD="$db_password" \
  psql -h ssdf-postgres -U "$db_user" -d lnd -Atc 'SELECT 1' | grep -qx 1
unset db_user db_password

echo "Phase 1 verification passed: persistent manual unsealer, transit-auto-unsealed main Vault, and renewable 1h VSO database credential."
