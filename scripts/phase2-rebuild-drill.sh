#!/usr/bin/env bash
# Destructive local proof for Phase 2. It targets only ln-ssdf-phase0.
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
for command in base64 helm jq kubectl openssl; do command -v "$command" >/dev/null || { echo "missing $command" >&2; exit 1; }; done

"$repo_root/scripts/phase1-rebuild-drill.sh" --context "$context" --state-dir "$state_dir"
rpc_password="$(openssl rand -base64 32)"
kubectl --context "$context" -n ssdf-system create secret generic bitcoind-rpc \
  --from-literal=rpc-password="$rpc_password" \
  --dry-run=client -o yaml | kubectl --context "$context" apply -f - >/dev/null
helm upgrade --install bitcoind "$repo_root/charts/bitcoind" --kube-context "$context" --namespace ssdf-system \
  --set auth.manageRpcSecret=false
unset rpc_password
kubectl --context "$context" -n ssdf-system rollout status statefulset/bitcoind --timeout=180s
"$repo_root/scripts/phase2-bootstrap.sh" --context "$context" --state-dir "$state_dir"

lncli_exec() {
  local pod="$1"; shift
  kubectl --context "$context" -n ssdf-system exec "$pod" -c lnd -- \
    lncli --network=regtest --rpcserver=localhost:10009 --tlscertpath=/root/.lnd/tls.cert \
    --macaroonpath=/root/.lnd/data/chain/bitcoin/regtest/admin.macaroon "$@"
}
bitcoin_cli() {
  kubectl --context "$context" -n ssdf-system exec bitcoind-0 -- sh -ec \
    'bitcoin-cli -regtest -rpcuser=regtest -rpcpassword="$RPC_PASSWORD" "$@"' ignored "$@"
}
for _ in $(seq 1 30); do
  # A fresh regtest chain at height zero is intentionally not "synced" yet.
  # Establish only that both RPC servers are active before mining its first blocks.
  if lncli_exec lnd-primary-0 getinfo | jq -e '.identity_pubkey | length > 0' >/dev/null 2>&1 && \
     lncli_exec lnd-peer-0 getinfo | jq -e '.identity_pubkey | length > 0' >/dev/null 2>&1; then break; fi
  sleep 2
done
lncli_exec lnd-primary-0 getinfo | jq -e '.identity_pubkey | length > 0' >/dev/null
lncli_exec lnd-peer-0 getinfo | jq -e '.identity_pubkey | length > 0' >/dev/null
address="$(lncli_exec lnd-primary-0 newaddress p2wkh | jq -er '.address')"
bitcoin_cli generatetoaddress 101 "$address" >/dev/null
for _ in $(seq 1 30); do
  if lncli_exec lnd-primary-0 getinfo | jq -e '.synced_to_chain == true' >/dev/null && \
     lncli_exec lnd-peer-0 getinfo | jq -e '.synced_to_chain == true' >/dev/null; then break; fi
  sleep 2
done
peer_pubkey="$(lncli_exec lnd-peer-0 getinfo | jq -er '.identity_pubkey')"
lncli_exec lnd-primary-0 connect "${peer_pubkey}@lnd-peer.ssdf-system.svc:9735" >/dev/null || true
lncli_exec lnd-primary-0 openchannel --node_key="$peer_pubkey" --local_amt=1000000 --push_amt=100000 >/dev/null
bitcoin_cli generatetoaddress 6 "$address" >/dev/null
for _ in $(seq 1 30); do
  if lncli_exec lnd-primary-0 listchannels | jq -e '.channels | length == 1 and .[0].active == true' >/dev/null; then break; fi
  sleep 2
done
lncli_exec lnd-primary-0 listchannels | jq -e '.channels | length == 1 and .[0].active == true' >/dev/null
pay_with_retry() {
  local payer="$1" payee="$2" amount="$3" result invoice
  for _ in $(seq 1 10); do
    # A failed payment hash cannot be retried by lnd. Mint a new invoice for
    # each bounded attempt, so only an independently successful settlement wins.
    invoice="$(lncli_exec "$payee" addinvoice --amt="$amount" | jq -er '.payment_request')"
    if result="$(lncli_exec "$payer" payinvoice --force --json "$invoice" 2>&1)" && \
       jq -e 'select(.status == "SUCCEEDED")' <<<"$result" >/dev/null; then
      return 0
    fi
    sleep 2
  done
  echo "payment from $payer to $payee did not settle after 10 independent attempts" >&2
  return 1
}
pay_with_retry lnd-primary-0 lnd-peer-0 10000
pay_with_retry lnd-peer-0 lnd-primary-0 7000
kubectl --context "$context" -n ssdf-system exec ssdf-postgres-0 -- psql -U postgres -d lnd -Atc \
  "SELECT count(*) FROM pg_tables WHERE schemaname='public'" | awk '$1 >= 6 {ok=1} END {exit !ok}'
# Do not use grep -q here: it may close the pipe early and make kubectl logs
# report SIGPIPE under pipefail, despite the expected log line being present.
kubectl --context "$context" -n ssdf-system logs lnd-primary-0 -c lnd | grep -F 'Using remote postgres database' >/dev/null
lncli_exec lnd-peer-0 listchannels | jq -e '.channels | length == 1 and .[0].active == true' >/dev/null
echo "Phase 2 destructive rebuild drill passed. New regtest chain/channel created; old channels are intentionally not claimed recovered."
