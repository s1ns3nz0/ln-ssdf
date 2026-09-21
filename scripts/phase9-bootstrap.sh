#!/usr/bin/env bash
# Install the locally built Phase 9 API and the narrowly credentialed buyer.
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
[[ "$context" == "kind-ln-ssdf-phase0" && "$state_dir" = /* && -f "$state_dir/main-init.json" ]] || { echo "Phase 9 requires the named local context and a Phase 1 external state directory" >&2; exit 2; }
for command in docker git kind jq kubectl; do command -v "$command" >/dev/null || { echo "missing $command" >&2; exit 1; }; done
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
k() { kubectl --context "$context" "$@"; }
aperture_source_dir=""
cleanup() {
  k -n ssdf-system exec lnd-peer-0 -c lnd -- rm -f /tmp/phase9-payment.macaroon >/dev/null 2>&1 || true
  k -n ssdf-system exec lnd-primary-0 -c lnd -- rm -f /tmp/phase9-invoice.macaroon >/dev/null 2>&1 || true
  [[ -z "$aperture_source_dir" ]] || rm -rf "$aperture_source_dir"
}
trap cleanup EXIT

# Grant VSO access only to the dedicated seller invoice credential. The Vault
# root token remains shell memory and this script never prints it.
main_root="$(jq -er '.root_token' "$state_dir/main-init.json")"
vault_exec() { k -n vault-system exec main-vault-0 -- env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN="$main_root" "$@"; }
cat <<'POLICY' | k -n vault-system exec -i main-vault-0 -- env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN="$main_root" vault policy write l402-macaroon-read - >/dev/null
path "kv/data/lnd-primary-l402" { capabilities = ["read"] }
POLICY
vault_exec vault write auth/kubernetes/role/ssdf-vso \
  bound_service_account_names=ssdf-vso-auth bound_service_account_namespaces=ssdf-system \
  audience=vault token_policies=ssdf-database-read,ssdf-wallet-read,l402-macaroon-read \
  token_ttl=1h token_max_ttl=2h >/dev/null
k -n vault-system rollout restart deployment/vault-secrets-operator-controller-manager >/dev/null
k -n vault-system rollout status deployment/vault-secrets-operator-controller-manager --timeout=180s

# Both narrow macaroons are baked inside their respective LND pods. The buyer
# alone receives offchain:write; Aperture receives only invoices:read/write via
# Vault/VSO. No admin macaroon, seed, or wallet password leaves the node.
k -n ssdf-system exec lnd-peer-0 -c lnd -- sh -ec '
  rm -f /tmp/phase9-payment.macaroon
  lncli --network=regtest --rpcserver=localhost:10009 --tlscertpath=/root/.lnd/tls.cert \
    --macaroonpath=/root/.lnd/data/chain/bitcoin/regtest/admin.macaroon \
    bakemacaroon --save_to=/tmp/phase9-payment.macaroon offchain:read offchain:write >/dev/null
'
k -n ssdf-system create secret generic lnd-peer-payment-api \
  --from-file=admin.macaroon=<(k -n ssdf-system exec lnd-peer-0 -c lnd -- cat /tmp/phase9-payment.macaroon) \
  --from-file=tls.cert=<(k -n ssdf-system exec lnd-peer-0 -c lnd -- cat /root/.lnd/tls.cert) \
  --dry-run=client -o yaml | k apply -f - >/dev/null
k -n ssdf-system exec lnd-primary-0 -c lnd -- sh -ec '
  rm -f /tmp/phase9-invoice.macaroon
  lncli --network=regtest --rpcserver=localhost:10009 --tlscertpath=/root/.lnd/tls.cert \
    --macaroonpath=/root/.lnd/data/chain/bitcoin/regtest/admin.macaroon \
    bakemacaroon --save_to=/tmp/phase9-invoice.macaroon invoices:read invoices:write >/dev/null
'
seller_macaroon_b64="$(k -n ssdf-system exec lnd-primary-0 -c lnd -- sh -c 'base64 < /tmp/phase9-invoice.macaroon' | tr -d '\n')"
seller_tls_b64="$(k -n ssdf-system exec lnd-primary-0 -c lnd -- sh -c 'base64 < /root/.lnd/tls.cert' | tr -d '\n')"
vault_exec vault kv put kv/lnd-primary-l402 invoice.macaroon-b64="$seller_macaroon_b64" tls.cert-b64="$seller_tls_b64" >/dev/null
unset seller_macaroon_b64 seller_tls_b64 main_root

docker build -t ln-ssdf/ti-product-api:phase9 "$repo_root/services/ti-product-api"
docker build -t ln-ssdf/payment-buyer:phase9 "$repo_root/services/payment-buyer"
# The published v0.5.0 Aperture image is amd64-only. Build the exact upstream
# v0.5.0 source commit locally for the kind node's architecture instead.
aperture_source_dir="$(mktemp -d /tmp/ln-ssdf-aperture-XXXXXX)"
aperture_commit="311220b15b04c06ecabd52c78fde8f5d6ea73c82"
git clone --depth 1 --branch v0.5.0 https://github.com/lightninglabs/aperture.git "$aperture_source_dir" >/dev/null
[[ "$(git -C "$aperture_source_dir" rev-parse HEAD)" == "$aperture_commit" ]] || { echo "Aperture v0.5.0 source revision mismatch" >&2; exit 1; }
docker build --build-arg checkout="$aperture_commit" -t ln-ssdf/aperture:phase9 "$aperture_source_dir"
kind load docker-image --name ln-ssdf-phase0 ln-ssdf/ti-product-api:phase9 ln-ssdf/payment-buyer:phase9 ln-ssdf/aperture:phase9
k apply -f "$repo_root/manifests/phase9/runtime.yaml"
k apply -f "$repo_root/manifests/phase9/network-policies.yaml"
k -n ssdf-system wait --for=condition=Ready vaultstaticsecret/aperture-seller-invoice --timeout=180s
k -n opencti-system rollout status deployment/ti-product-api --timeout=180s
k -n ssdf-system rollout status deployment/aperture --timeout=180s
k -n ssdf-system rollout status deployment/payment-buyer --timeout=180s
echo "Phase 9 runtime installed with fixed Aperture L402 routes."
