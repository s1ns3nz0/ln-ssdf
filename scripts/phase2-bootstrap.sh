#!/usr/bin/env bash
set -euo pipefail

context=""
state_dir=""
namespace="ssdf-system"
vault_namespace="vault-system"

usage() {
  echo "usage: $0 --context NAME --state-dir ABSOLUTE_PATH" >&2
  echo "state-dir is the Phase 1 recovery-material directory; no secret is written to this repository." >&2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --context) context="$2"; shift 2 ;;
    --state-dir) state_dir="$2"; shift 2 ;;
    *) usage; exit 2 ;;
  esac
done

[[ -n "$context" && -n "$state_dir" && "$state_dir" = /* ]] || { usage; exit 2; }
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
case "$state_dir" in "$repo_root"|"$repo_root"/*) echo "state-dir must be outside repository" >&2; exit 2;; esac
[[ -f "$state_dir/main-init.json" ]] || { echo "missing Phase 1 main-init.json" >&2; exit 1; }
for command in base64 curl helm jq kubectl tar; do command -v "$command" >/dev/null || { echo "missing $command" >&2; exit 1; }; done

k() { kubectl --context "$context" "$@"; }
vault_token_exec() {
  local token="$1"
  shift
  k -n "$vault_namespace" exec main-vault-0 -- env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN="$token" "$@"
}

k -n "$namespace" wait --for=condition=Ready vaultdynamicsecret/lnd-db-credential --timeout=180s
k -n "$namespace" rollout status statefulset/bitcoind --timeout=180s
main_root="$(jq -er '.root_token' "$state_dir/main-init.json")"

# lndinit produces lnd's aezeed format. Use the official signed-release
# manifest hash and retain values only in shell memory until Vault accepts them.
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"; unset main_root' EXIT
case "$(uname -s)/$(uname -m)" in
  Darwin/arm64)
    archive_name=lndinit-darwin-arm64-v0.1.26-beta.tar.gz
    archive_sha=dc617a6779b2bb9cce3b8a822f12a9d8d69f5939299efb04ea1d4011a57b35d5
    checksum_cmd=(shasum -a 256)
    ;;
  Linux/aarch64|Linux/arm64)
    archive_name=lndinit-linux-arm64-v0.1.26-beta.tar.gz
    archive_sha=175cdf07d32c196136aecaa80c4e00c18002c4184f26a9fd601c379d4f2efd36
    checksum_cmd=(sha256sum)
    ;;
  Linux/x86_64|Linux/amd64)
    archive_name=lndinit-linux-amd64-v0.1.26-beta.tar.gz
    archive_sha=6ab28d5b63681dfd0f35a30cbb26a5ce7dd4dbe68819650b0c1432257fb5ded5
    checksum_cmd=(sha256sum)
    ;;
  *) echo "unsupported bootstrap platform: $(uname -s)/$(uname -m)" >&2; exit 1;;
esac
curl --fail --location --proto '=https' --tlsv1.2 \
  "https://github.com/lightninglabs/lndinit/releases/download/v0.1.26-beta/$archive_name" \
  -o "$tmp_dir/$archive_name"
actual_sha="$("${checksum_cmd[@]}" "$tmp_dir/$archive_name" | awk '{print $1}')"
[[ "$actual_sha" == "$archive_sha" ]] || { echo "lndinit checksum mismatch" >&2; exit 1; }
tar -xzf "$tmp_dir/$archive_name" -C "$tmp_dir"
lndinit_bin="$(find "$tmp_dir" -type f -name lndinit -perm -u+x -print -quit)"
[[ -n "$lndinit_bin" ]] || { echo "lndinit binary missing from release archive" >&2; exit 1; }

vault_token_exec "$main_root" vault secrets enable -path=kv kv-v2 >/dev/null 2>&1 || true
for node in primary peer; do
  if ! vault_token_exec "$main_root" vault kv get -field=seed "kv/lnd-$node" >/dev/null 2>&1; then
    seed="$($lndinit_bin gen-seed)"
    wallet_password="$($lndinit_bin gen-password)"
    vault_token_exec "$main_root" vault kv put "kv/lnd-$node" seed="$seed" wallet-password="$wallet_password" >/dev/null
    unset seed wallet_password
  fi
done

cat <<'POLICY' | k -n "$vault_namespace" exec -i main-vault-0 -- env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN="$main_root" vault policy write ssdf-wallet-read - >/dev/null
path "kv/data/lnd-primary" { capabilities = ["read"] }
path "kv/data/lnd-peer" { capabilities = ["read"] }
POLICY
vault_token_exec "$main_root" vault write auth/kubernetes/role/ssdf-vso \
  bound_service_account_names=ssdf-vso-auth \
  bound_service_account_namespaces=ssdf-system \
  audience=vault token_policies=ssdf-database-read,ssdf-wallet-read \
  token_ttl=1h token_max_ttl=2h >/dev/null

# Phase 1's VSO client can still hold a database-only Kubernetes token. Restart
# it after adding wallet-read so the static wallet Secrets cannot wait for the
# prior token's one-hour lifetime before receiving the expanded policy.
k -n "$vault_namespace" rollout restart deployment/vault-secrets-operator-controller-manager >/dev/null
k -n "$vault_namespace" rollout status deployment/vault-secrets-operator-controller-manager --timeout=180s

k apply -f "$repo_root/manifests/phase2/vso-resources.yaml"
k -n "$namespace" wait --for=condition=Ready vaultstaticsecret/lnd-primary-wallet --timeout=180s
k -n "$namespace" wait --for=condition=Ready vaultstaticsecret/lnd-peer-wallet --timeout=180s
helm upgrade --install lnd "$repo_root/charts/lnd" --kube-context "$context" --namespace "$namespace"
k -n "$namespace" rollout status statefulset/lnd-primary --timeout=300s
k -n "$namespace" rollout status statefulset/lnd-peer --timeout=300s

echo "Phase 2 runtime bootstrap completed. Wallet material remains only in Vault and VSO destination Secrets."
