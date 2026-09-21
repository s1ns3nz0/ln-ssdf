#!/usr/bin/env bash
# Destructive local proof: recreate kind, restore both Vault Raft snapshots,
# then prove the Phase 1 functional gate again. It targets only ln-ssdf-phase0.
set -euo pipefail

context="kind-ln-ssdf-phase0"
state_dir=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --state-dir) state_dir="$2"; shift 2 ;;
    --context) context="$2"; shift 2 ;;
    *) echo "usage: $0 --state-dir ABSOLUTE_PATH [--context kind-ln-ssdf-phase0]" >&2; exit 2 ;;
  esac
done
[[ "$context" == "kind-ln-ssdf-phase0" && "$state_dir" = /* ]] || { echo "explicit Phase 0 context and absolute state-dir are required" >&2; exit 2; }

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
case "$state_dir" in "$repo_root"|"$repo_root"/*) echo "state-dir must be outside repository" >&2; exit 2;; esac
for command in base64 helm jq kind kubectl openssl; do command -v "$command" >/dev/null || { echo "missing: $command" >&2; exit 1; }; done
for artifact in unsealer-init.json main-init.json snapshots/unsealer-vault.snap snapshots/main-vault.snap; do
  [[ -f "$state_dir/$artifact" ]] || { echo "missing recovery artifact: $artifact" >&2; exit 1; }
done

k() { kubectl --context "$context" "$@"; }
vault_exec() {
  local pod="$1"
  shift
  k -n vault-system exec "$pod" -- env VAULT_ADDR=http://127.0.0.1:8200 "$@"
}
token_exec() {
  local pod="$1" token="$2"
  shift 2
  k -n vault-system exec "$pod" -- env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN="$token" "$@"
}
unseal() {
  local pod="$1" init_file="$2"
  jq -r '.unseal_keys_b64[]' "$init_file" | head -n "$(jq -r '.unseal_threshold' "$init_file")" | while IFS= read -r key; do
    vault_exec "$pod" vault operator unseal "$key" >/dev/null
  done
}
wait_running() {
  local workload="$1"
  k -n vault-system rollout status "statefulset/$workload" --timeout=180s
}
restore_snapshot() {
  local pod="$1" temp_root="$2" snapshot="$3" original_init="$4" manual_unseal="$5"
  k -n vault-system cp "$snapshot" "$pod:/tmp/restore.snap" >/dev/null
  token_exec "$pod" "$temp_root" vault operator raft snapshot restore -force /tmp/restore.snap >/dev/null
  # restore is asynchronous; original Shamir material becomes authoritative
  # after the old storage is installed.
  sleep 5
  if [[ "$manual_unseal" == "true" ]]; then
    unseal "$pod" "$original_init"
  else
    for _ in $(seq 1 30); do
      restore_status="$(vault_exec "$pod" vault status -format=json 2>/dev/null || true)"
      if printf '%s' "$restore_status" | jq -e '.sealed == false' >/dev/null 2>&1; then
        return 0
      fi
      sleep 2
    done
    echo "transit auto-unseal did not complete after snapshot restore" >&2
    exit 1
  fi
}

# The current cluster and its PVCs are intentionally destroyed. Only the
# supplied host recovery directory survives this drill.
kind delete cluster --name ln-ssdf-phase0
kind create cluster --config "$repo_root/local/kind-config.yaml" --wait 120s

bootstrap_password="$(openssl rand -base64 32)"
k create namespace ssdf-system
k -n ssdf-system create secret generic ssdf-postgres-bootstrap \
  --from-literal=POSTGRES_PASSWORD="$bootstrap_password" \
  --dry-run=client -o yaml | k apply -f - >/dev/null
helm upgrade --install ssdf "$repo_root/charts/postgres" \
  --kube-context "$context" --namespace ssdf-system
unset bootstrap_password
k -n ssdf-system rollout status statefulset/ssdf-postgres --timeout=180s
"$repo_root/scripts/phase0-verify.sh" --context "$context"

k create namespace vault-system
helm upgrade --install unsealer "$repo_root/charts/vault" --kube-context "$context" --namespace vault-system
wait_running unsealer-vault

temporary_dir="$(mktemp -d)"
trap 'rm -rf "$temporary_dir"' EXIT
unsealer_temp="$temporary_dir/unsealer.json"
vault_exec unsealer-vault-0 vault operator init -format=json > "$unsealer_temp"
chmod 600 "$unsealer_temp"
unseal unsealer-vault-0 "$unsealer_temp"
unsealer_temp_root="$(jq -er '.root_token' "$unsealer_temp")"
restore_snapshot unsealer-vault-0 "$unsealer_temp_root" "$state_dir/snapshots/unsealer-vault.snap" "$state_dir/unsealer-init.json" true
unsealer_status="$(vault_exec unsealer-vault-0 vault status -format=json 2>/dev/null || true)"
printf '%s' "$unsealer_status" | jq -e '.sealed == false and .type == "shamir" and .storage_type == "raft"' >/dev/null

unsealer_root="$(jq -er '.root_token' "$state_dir/unsealer-init.json")"
transit_token="$(token_exec unsealer-vault-0 "$unsealer_root" vault token create -orphan -period=24h -policy=main-transit -format=json | jq -er '.auth.client_token')"
k -n vault-system create secret generic main-vault-transit --from-literal=token="$transit_token"
unset transit_token
helm upgrade --install main "$repo_root/charts/vault" --kube-context "$context" --namespace vault-system \
  --set transit.enabled=true \
  --set transit.address=http://unsealer-vault.vault-system.svc:8200 \
  --set transit.tokenSecretName=main-vault-transit
wait_running main-vault

main_temp="$temporary_dir/main.json"
vault_exec main-vault-0 vault operator init -format=json > "$main_temp"
chmod 600 "$main_temp"
main_temp_root="$(jq -er '.root_token' "$main_temp")"
restore_snapshot main-vault-0 "$main_temp_root" "$state_dir/snapshots/main-vault.snap" "$state_dir/main-init.json" false
main_status="$(vault_exec main-vault-0 vault status -format=json 2>/dev/null || true)"
printf '%s' "$main_status" | jq -e '.sealed == false and .type == "transit" and .storage_type == "raft"' >/dev/null

# Snapshot data has the old bootstrap password and prior cluster Kubernetes auth
# configuration. Reconcile only those environment-dependent values.
k -n ssdf-system exec -i ssdf-postgres-0 -- psql -U postgres -d postgres -v ON_ERROR_STOP=1 <<'SQL'
DO $$ BEGIN CREATE ROLE lnd_runtime NOLOGIN; EXCEPTION WHEN duplicate_object THEN NULL; END $$;
GRANT ALL PRIVILEGES ON DATABASE lnd TO lnd_runtime;
DO $$ BEGIN CREATE ROLE postgres_monitor NOLOGIN; EXCEPTION WHEN duplicate_object THEN NULL; END $$;
GRANT CONNECT ON DATABASE postgres TO postgres_monitor;
GRANT pg_monitor TO postgres_monitor;
SQL
k -n ssdf-system exec -i ssdf-postgres-0 -- psql -U postgres -d lnd -v ON_ERROR_STOP=1 <<'SQL'
GRANT ALL PRIVILEGES ON SCHEMA public TO lnd_runtime;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO lnd_runtime;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO lnd_runtime;
SQL
main_root="$(jq -er '.root_token' "$state_dir/main-init.json")"
postgres_password="$(k -n ssdf-system get secret ssdf-postgres-bootstrap -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 -d)"
token_exec main-vault-0 "$main_root" vault write database/config/postgres \
  plugin_name=postgresql-database-plugin allowed_roles=lnd,postgres-observability \
  connection_url='postgresql://{{username}}:{{password}}@ssdf-postgres.ssdf-system.svc:5432/postgres?sslmode=disable' \
  username=postgres password="$postgres_password" >/dev/null
unset postgres_password
token_exec main-vault-0 "$main_root" vault write database/roles/lnd \
  db_name=postgres \
  creation_statements='CREATE ROLE "{{name}}" WITH LOGIN PASSWORD '\''{{password}}'\'' VALID UNTIL '\''{{expiration}}'\'' IN ROLE lnd_runtime; ALTER ROLE "{{name}}" SET ROLE lnd_runtime;' \
  default_ttl=1h max_ttl=2h >/dev/null
token_exec main-vault-0 "$main_root" vault write database/roles/postgres-observability \
  db_name=postgres \
  creation_statements='CREATE ROLE "{{name}}" WITH LOGIN PASSWORD '\''{{password}}'\'' VALID UNTIL '\''{{expiration}}'\'' IN ROLE postgres_monitor; ALTER ROLE "{{name}}" SET ROLE postgres_monitor;' \
  default_ttl=1h max_ttl=2h >/dev/null
cat <<'POLICY' | k -n vault-system exec -i main-vault-0 -- env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN="$main_root" vault policy write ssdf-database-read - >/dev/null
path "database/creds/lnd" { capabilities = ["read"] }
path "database/creds/postgres-observability" { capabilities = ["read"] }
POLICY
token_exec main-vault-0 "$main_root" sh -ec 'vault write auth/kubernetes/config kubernetes_host="https://${KUBERNETES_PORT_443_TCP_ADDR}:443"' >/dev/null

helm upgrade --install vault-secrets-operator https://helm.releases.hashicorp.com/vault-secrets-operator-1.5.1.tgz \
  --kube-context "$context" --namespace vault-system \
  --set controller.manager.globalTransformationOptions.excludeRaw=true
k wait --for=condition=Established --timeout=180s crd/vaultdynamicsecrets.secrets.hashicorp.com
k apply -f "$repo_root/manifests/phase1/vso-resources.yaml"
k -n ssdf-system wait --for=condition=Ready vaultdynamicsecret/lnd-db-credential --timeout=180s
"$repo_root/scripts/phase1-verify.sh" --context "$context" --state-dir "$state_dir"
echo "Phase 1 destructive rebuild drill passed."
