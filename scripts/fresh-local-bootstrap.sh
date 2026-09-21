#!/usr/bin/env bash
# Recreate the explicit local kind environment from Phase 0. This is not a
# restore drill: it intentionally creates a new regtest chain, Vault state,
# wallets, channel, and payment history, then records fresh Vault snapshots.
set -euo pipefail

context="kind-ln-ssdf-phase0"
state_dir=""
confirm=""

usage() {
  echo "usage: $0 --state-dir ABSOLUTE_PATH --confirm-recreate [--context kind-ln-ssdf-phase0]" >&2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --context) context="$2"; shift 2 ;;
    --state-dir) state_dir="$2"; shift 2 ;;
    --confirm-recreate) confirm="yes"; shift ;;
    *) usage; exit 2 ;;
  esac
done

[[ "$context" == "kind-ln-ssdf-phase0" && "$state_dir" = /* && "$confirm" == "yes" ]] || { usage; exit 2; }
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
case "$state_dir" in "$repo_root"|"$repo_root"/*) echo "state-dir must be outside repository" >&2; exit 2;; esac
for command in base64 curl git helm jq kind kubectl openssl shasum tar; do
  command -v "$command" >/dev/null || { echo "missing: $command" >&2; exit 1; }
done

umask 077
mkdir -p "$state_dir"
chmod 700 "$state_dir"

# This targets the named local kind cluster only. Its PVs contain disposable
# regtest/Vault state and are deliberately replaced by this fresh bootstrap.
kind delete cluster --name ln-ssdf-phase0 >/dev/null 2>&1 || true
kind create cluster --config "$repo_root/local/kind-config.yaml" --wait 120s

k() { kubectl --context "$context" "$@"; }
bootstrap_password="$(openssl rand -base64 32)"
k create namespace ssdf-system
k -n ssdf-system create secret generic ssdf-postgres-bootstrap \
  --from-literal=POSTGRES_PASSWORD="$bootstrap_password" \
  --dry-run=client -o yaml | k apply -f - >/dev/null
unset bootstrap_password
helm upgrade --install ssdf "$repo_root/charts/postgres" --kube-context "$context" --namespace ssdf-system
"$repo_root/scripts/phase0-verify.sh" --context "$context"

"$repo_root/scripts/phase1-bootstrap.sh" --context "$context" --state-dir "$state_dir"
"$repo_root/scripts/phase1-backup.sh" --context "$context" --state-dir "$state_dir"

rpc_password="$(openssl rand -base64 32)"
k -n ssdf-system create secret generic bitcoind-rpc \
  --from-literal=rpc-password="$rpc_password" \
  --dry-run=client -o yaml | k apply -f - >/dev/null
unset rpc_password
helm upgrade --install bitcoind "$repo_root/charts/bitcoind" --kube-context "$context" --namespace ssdf-system \
  --set auth.manageRpcSecret=false
k -n ssdf-system rollout status statefulset/bitcoind --timeout=180s
"$repo_root/scripts/phase2-bootstrap.sh" --context "$context" --state-dir "$state_dir"
"$repo_root/scripts/phase3-bootstrap.sh" --context "$context"
"$repo_root/scripts/phase4-bootstrap.sh" --context "$context"
"$repo_root/scripts/phase6-bootstrap.sh" --context "$context"
"$repo_root/scripts/phase8-bootstrap.sh" --context "$context"

echo "Fresh local Phase 0-8 bootstrap passed. New recovery material is in $state_dir."
