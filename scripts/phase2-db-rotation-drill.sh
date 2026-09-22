#!/usr/bin/env bash
# Bounded local test of VSO lease renewal and LND credential rotation.
set -euo pipefail

context=""
state_dir=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --context) context="$2"; shift 2 ;;
    --state-dir) state_dir="$2"; shift 2 ;;
    *) echo "usage: $0 --context kind-ln-ssdf-phase0 --state-dir ABSOLUTE_PATH" >&2; exit 2 ;;
  esac
done
[[ "$context" == "kind-ln-ssdf-phase0" && "$state_dir" = /* ]] || {
  echo "explicit Phase 0 context and absolute state directory required" >&2; exit 2;
}
for command in jq kubectl; do command -v "$command" >/dev/null || {
  echo "missing $command" >&2; exit 1;
}; done
init_file="$state_dir/main-init.json"
[[ -f "$init_file" ]] || { echo "missing main Vault recovery file" >&2; exit 1; }
[[ "$(stat -f '%Lp' "$init_file" 2>/dev/null || stat -c '%a' "$init_file")" == 600 ]] || {
  echo "main Vault recovery file must have mode 600" >&2; exit 1;
}

k() { kubectl --context "$context" "$@"; }
write_role_ttl() {
  local default_ttl="$1" max_ttl="$2"
  # Vault template placeholders are intentionally literal.
  # shellcheck disable=SC2016
  jq -r '.root_token' "$init_file" |
    k -n vault-system exec -i main-vault-0 -- sh -ec '
      read -r VAULT_TOKEN
      export VAULT_TOKEN VAULT_ADDR=http://127.0.0.1:8200
      vault write database/roles/lnd \
        db_name=postgres \
        creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '\''{{password}}'\'' VALID UNTIL '\''{{expiration}}'\'' IN ROLE lnd_runtime; GRANT CONNECT ON DATABASE lnd TO \"{{name}}\"; ALTER ROLE \"{{name}}\" SET ROLE lnd_runtime;" \
        renew_statements="ALTER ROLE \"{{name}}\" VALID UNTIL '\''{{expiration}}'\'';" \
        default_ttl="$1" max_ttl="$2" >/dev/null
    ' sh "$default_ttl" "$max_ttl"
}
secret_username() { k -n ssdf-system get secret lnd-db-credential -o json | jq -r '.data.username | @base64d'; }
pod_uid() { k -n ssdf-system get pod lnd-primary-0 -o jsonpath='{.metadata.uid}' 2>/dev/null || true; }
role_expiry() {
  local username="$1"
  k -n ssdf-system exec ssdf-postgres-0 -- psql -U postgres -d postgres -Atc \
    "SELECT rolname, extract(epoch from rolvaliduntil)::bigint FROM pg_authid WHERE rolname LIKE 'v-kubernet-lnd-%'" |
    awk -F '|' -v username="$username" '$1 == username {print $2; found=1} END {if (!found) exit 1}'
}
wait_for_new_secret() {
  local old_username="$1" timeout_seconds="$2" username
  for ((elapsed=0; elapsed<timeout_seconds; elapsed+=2)); do
    username="$(secret_username)"
    if [[ "$username" != "$old_username" ]]; then printf '%s' "$username"; return 0; fi
    sleep 2
  done
  echo "VSO did not rotate the Secret within ${timeout_seconds}s" >&2
  return 1
}
wait_for_pod() {
  local old_uid="$1" username="$2" timeout_seconds="$3" current_uid current_username
  for ((elapsed=0; elapsed<timeout_seconds; elapsed+=2)); do
    current_uid="$(pod_uid)"
    if [[ -n "$current_uid" && "$current_uid" != "$old_uid" ]] &&
       k -n ssdf-system get pod lnd-primary-0 -o json | jq -e \
         '.status.containerStatuses | all(.ready == true)' >/dev/null 2>&1; then
      current_username="$(k -n ssdf-system exec lnd-primary-0 -c lnd -- printenv DB_USERNAME)"
      [[ "$current_username" == "$username" ]] || {
        echo "new LND Pod is not using the current Secret role" >&2; return 1;
      }
      return 0
    fi
    sleep 2
  done
  echo "LND Pod did not restart ready with the new Secret within ${timeout_seconds}s" >&2
  return 1
}

original_username="$(secret_username)"
original_uid="$(pod_uid)"
trap 'write_role_ttl 1h 2h || echo "WARNING: restore Vault lnd role TTL manually" >&2' EXIT
write_role_ttl 90s 180s
k -n ssdf-system annotate vaultdynamicsecret lnd-db-credential \
  "ln-ssdf.io/rotation-test-at=$(date -u +%Y-%m-%dT%H:%M:%SZ)" --overwrite >/dev/null

short_username="$(wait_for_new_secret "$original_username" 90)"
wait_for_pod "$original_uid" "$short_username" 120
first_expiry="$(role_expiry "$short_username")"
[[ "$first_expiry" -gt "$(date -u +%s)" ]] || { echo "issued role already expired" >&2; exit 1; }

renewed=false
for ((elapsed=0; elapsed<140; elapsed+=2)); do
  [[ "$(secret_username)" == "$short_username" ]] || break
  expiry="$(role_expiry "$short_username" 2>/dev/null || true)"
  if [[ -n "$expiry" && "$expiry" -gt "$((first_expiry + 10))" ]]; then renewed=true; break; fi
  sleep 2
done
[[ "$renewed" == true ]] || { echo "VSO did not extend PostgreSQL role expiry on lease renewal" >&2; exit 1; }
echo "VSO renewal extended the same PostgreSQL role expiry."

short_uid="$(pod_uid)"
next_username="$(wait_for_new_secret "$short_username" 240)"
wait_for_pod "$short_uid" "$next_username" 120
next_expiry="$(role_expiry "$next_username")"
[[ "$next_expiry" -gt "$(date -u +%s)" ]] || { echo "rotated role already expired" >&2; exit 1; }
echo "VSO rotation issued a new role and restarted LND with it."

# Leave the workload on the normal one-hour lease, not the short-lived probe.
write_role_ttl 1h 2h
next_uid="$(pod_uid)"
k -n ssdf-system annotate vaultdynamicsecret lnd-db-credential \
  "ln-ssdf.io/rotation-test-at=$(date -u +%Y-%m-%dT%H:%M:%SZ)" --overwrite >/dev/null
normal_username="$(wait_for_new_secret "$next_username" 90)"
wait_for_pod "$next_uid" "$normal_username" 120
k -n ssdf-system get vaultdynamicsecret lnd-db-credential -o json |
  jq -e '.status.secretLease.duration == 3600' >/dev/null
trap - EXIT
echo "Normal one-hour lease restored and LND restarted ready."

lncli_exec() {
  local pod="$1"; shift
  k -n ssdf-system exec "$pod" -c lnd -- \
    lncli --network=regtest --rpcserver=localhost:10009 --tlscertpath=/root/.lnd/tls.cert \
      --macaroonpath=/root/.lnd/data/chain/bitcoin/regtest/admin.macaroon "$@"
}
if ! lncli_exec lnd-primary-0 getinfo | jq -e '.synced_to_chain == true' >/dev/null; then
  address="$(lncli_exec lnd-primary-0 newaddress p2wkh | jq -er '.address')"
  # Expand the RPC password inside the bitcoind container.
  # shellcheck disable=SC2016
  k -n ssdf-system exec bitcoind-0 -- sh -ec \
    'bitcoin-cli -regtest -rpcuser=regtest -rpcpassword="$RPC_PASSWORD" generatetoaddress 1 "$1" >/dev/null' \
    sh "$address"
fi
for ((elapsed=0; elapsed<120; elapsed+=2)); do
  if lncli_exec lnd-primary-0 getinfo | jq -e '.synced_to_chain == true' >/dev/null &&
     lncli_exec lnd-primary-0 listchannels | jq -e '.channels[0].active == true' >/dev/null; then break; fi
  sleep 2
done
lncli_exec lnd-primary-0 listchannels | jq -e '.channels[0].active == true' >/dev/null
invoice="$(lncli_exec lnd-peer-0 addinvoice --amt=1000 | jq -er '.payment_request')"
lncli_exec lnd-primary-0 payinvoice --force --json "$invoice" |
  jq -e '.status == "SUCCEEDED"' >/dev/null
echo "Post-rotation LND payment settled."
