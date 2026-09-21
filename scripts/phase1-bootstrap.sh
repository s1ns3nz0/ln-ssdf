#!/usr/bin/env bash
set -euo pipefail

context=""
state_dir=""
namespace="vault-system"
postgres_namespace="ssdf-system"

usage() {
  echo "usage: $0 --context NAME --state-dir ABSOLUTE_PATH [--namespace NAME]" >&2
  echo "state-dir must be outside this repository; it contains Vault recovery material." >&2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --context) context="$2"; shift 2 ;;
    --state-dir) state_dir="$2"; shift 2 ;;
    --namespace) namespace="$2"; shift 2 ;;
    *) usage; exit 2 ;;
  esac
done

[[ -n "$context" && -n "$state_dir" ]] || { usage; exit 2; }
[[ "$state_dir" = /* ]] || { echo "--state-dir must be absolute" >&2; exit 2; }

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
case "$state_dir" in
  "$repo_root"|"$repo_root"/*)
    echo "--state-dir must be outside the repository" >&2
    exit 2
    ;;
esac

for command in base64 helm jq kubectl; do
  command -v "$command" >/dev/null || { echo "missing required command: $command" >&2; exit 1; }
done

umask 077
mkdir -p "$state_dir"
chmod 700 "$state_dir"

k() { kubectl --context "$context" "$@"; }
vault_exec() {
  local pod="$1"
  shift
  k -n "$namespace" exec "$pod" -- env VAULT_ADDR=http://127.0.0.1:8200 "$@"
}
vault_token_exec() {
  local pod="$1"
  local token="$2"
  shift 2
  k -n "$namespace" exec "$pod" -- env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN="$token" "$@"
}
unseal_from_file() {
  local pod="$1"
  local init_file="$2"
  local status_json
  status_json="$(vault_exec "$pod" vault status -format=json 2>/dev/null || true)"
  if [[ "$(jq -r '.sealed' <<<"$status_json")" != "true" ]]; then
    return 0
  fi
  jq -r '.unseal_keys_b64[]' "$init_file" | head -n "$(jq -r '.unseal_threshold' "$init_file")" | while IFS= read -r key; do
    # Vault CLI requires a TTY when reading a key from stdin. Passing the key
    # directly avoids output while keeping it out of shell history and Git.
    k -n "$namespace" exec "$pod" -- env VAULT_ADDR=http://127.0.0.1:8200 vault operator unseal "$key" >/dev/null
  done
}
init_if_needed() {
  local pod="$1"
  local init_file="$2"
  if [[ ! -f "$init_file" ]]; then
    k -n "$namespace" exec "$pod" -- env VAULT_ADDR=http://127.0.0.1:8200 vault operator init -format=json > "$init_file"
    chmod 600 "$init_file"
  fi
}

k get namespace "$namespace" >/dev/null 2>&1 || k create namespace "$namespace"

helm upgrade --install unsealer "$repo_root/charts/vault" \
  --kube-context "$context" --namespace "$namespace"

unsealer_pod="unsealer-vault-0"
k -n "$namespace" rollout status statefulset/unsealer-vault --timeout=180s
unsealer_init="$state_dir/unsealer-init.json"
init_if_needed "$unsealer_pod" "$unsealer_init"
unseal_from_file "$unsealer_pod" "$unsealer_init"
unsealer_root="$(jq -er '.root_token' "$unsealer_init")"

# The main Vault gets a narrowly scoped renewable token, never the unsealer root
# token. The token is intentionally runtime-only Kubernetes state.
vault_token_exec "$unsealer_pod" "$unsealer_root" vault secrets enable transit >/dev/null 2>&1 || true
vault_token_exec "$unsealer_pod" "$unsealer_root" vault write -f transit/keys/main-unseal >/dev/null
cat <<'POLICY' | k -n "$namespace" exec -i "$unsealer_pod" -- env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN="$unsealer_root" vault policy write main-transit - >/dev/null
path "transit/encrypt/main-unseal" { capabilities = ["update"] }
path "transit/decrypt/main-unseal" { capabilities = ["update"] }
POLICY
transit_token="$(vault_token_exec "$unsealer_pod" "$unsealer_root" vault token create -orphan -period=24h -policy=main-transit -format=json | jq -er '.auth.client_token')"
k -n "$namespace" create secret generic main-vault-transit \
  --from-literal=token="$transit_token" \
  --dry-run=client -o yaml | k apply -f - >/dev/null
unset transit_token

helm upgrade --install main "$repo_root/charts/vault" \
  --kube-context "$context" --namespace "$namespace" \
  --set transit.enabled=true \
  --set transit.address="http://unsealer-vault.${namespace}.svc:8200" \
  --set transit.tokenSecretName=main-vault-transit

main_pod="main-vault-0"
k -n "$namespace" rollout status statefulset/main-vault --timeout=180s
main_init="$state_dir/main-init.json"
init_if_needed "$main_pod" "$main_init"
main_root="$(jq -er '.root_token' "$main_init")"

# Prove auto-unseal before configuring VSO: a sealed main Vault cannot pass this.
main_status="$(vault_exec "$main_pod" vault status -format=json 2>/dev/null || true)"
[[ "$(jq -r '.sealed' <<<"$main_status")" == "false" ]]

# A non-login group owns lnd schema privileges; short-lived lease principals are
# only members of this group, so the bootstrap superuser is never an app credential.
k -n "$postgres_namespace" exec -i ssdf-postgres-0 -- psql -U postgres -d postgres -v ON_ERROR_STOP=1 <<'SQL'
DO $$ BEGIN
  CREATE ROLE lnd_runtime NOLOGIN;
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;
-- LND creates and migrates its graph database during first boot. CONNECT alone
-- is insufficient for the postgres backend; the non-login runtime role needs
-- the database-level CREATE/TEMP privileges as well. Lease principals assume
-- this role, keeping the bootstrap superuser out of the running workload.
GRANT ALL PRIVILEGES ON DATABASE lnd TO lnd_runtime;
DO $$ BEGIN
  CREATE ROLE postgres_monitor NOLOGIN;
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;
GRANT CONNECT ON DATABASE postgres TO postgres_monitor;
GRANT pg_monitor TO postgres_monitor;
SQL
k -n "$postgres_namespace" exec -i ssdf-postgres-0 -- psql -U postgres -d lnd -v ON_ERROR_STOP=1 <<'SQL'
GRANT USAGE, CREATE ON SCHEMA public TO lnd_runtime;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO lnd_runtime;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO lnd_runtime;
SQL

postgres_password="$(k -n "$postgres_namespace" get secret ssdf-postgres-bootstrap -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 -d)"
vault_token_exec "$main_pod" "$main_root" vault secrets enable database >/dev/null 2>&1 || true
vault_token_exec "$main_pod" "$main_root" vault write database/config/postgres \
  plugin_name=postgresql-database-plugin \
  allowed_roles=lnd,postgres-observability \
  connection_url='postgresql://{{username}}:{{password}}@ssdf-postgres.ssdf-system.svc:5432/postgres?sslmode=disable' \
  username=postgres password="$postgres_password" >/dev/null
unset postgres_password
vault_token_exec "$main_pod" "$main_root" vault write database/roles/lnd \
  db_name=postgres \
  creation_statements='CREATE ROLE "{{name}}" WITH LOGIN PASSWORD '\''{{password}}'\'' VALID UNTIL '\''{{expiration}}'\'' IN ROLE lnd_runtime; GRANT CONNECT ON DATABASE lnd TO "{{name}}"; ALTER ROLE "{{name}}" SET ROLE lnd_runtime;' \
  default_ttl=1h max_ttl=2h >/dev/null
vault_token_exec "$main_pod" "$main_root" vault write database/roles/postgres-observability \
  db_name=postgres \
  creation_statements='CREATE ROLE "{{name}}" WITH LOGIN PASSWORD '\''{{password}}'\'' VALID UNTIL '\''{{expiration}}'\'' IN ROLE postgres_monitor; ALTER ROLE "{{name}}" SET ROLE postgres_monitor;' \
  default_ttl=1h max_ttl=2h >/dev/null

vault_token_exec "$main_pod" "$main_root" vault auth enable kubernetes >/dev/null 2>&1 || true
vault_token_exec "$main_pod" "$main_root" sh -ec 'vault write auth/kubernetes/config kubernetes_host="https://${KUBERNETES_PORT_443_TCP_ADDR}:443"' >/dev/null
cat <<'POLICY' | k -n "$namespace" exec -i "$main_pod" -- env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN="$main_root" vault policy write ssdf-database-read - >/dev/null
path "database/creds/lnd" { capabilities = ["read"] }
path "database/creds/postgres-observability" { capabilities = ["read"] }
POLICY
vault_token_exec "$main_pod" "$main_root" vault write auth/kubernetes/role/ssdf-vso \
  bound_service_account_names=ssdf-vso-auth \
  bound_service_account_namespaces=ssdf-system \
  audience=vault token_policies=ssdf-database-read token_ttl=1h token_max_ttl=2h >/dev/null

# This chart is pinned by version and upstream package digest in the Phase 1 doc.
helm upgrade --install vault-secrets-operator \
  https://helm.releases.hashicorp.com/vault-secrets-operator-1.5.1.tgz \
  --kube-context "$context" --namespace "$namespace" \
  --set controller.manager.globalTransformationOptions.excludeRaw=true
k wait --for=condition=Established --timeout=180s crd/vaultdynamicsecrets.secrets.hashicorp.com
k apply -f "$repo_root/manifests/phase1/vso-resources.yaml"
k -n "$postgres_namespace" wait --for=condition=Ready vaultdynamicsecret/lnd-db-credential --timeout=180s

echo "Phase 1 bootstrap completed. Recovery material is only in $state_dir."
