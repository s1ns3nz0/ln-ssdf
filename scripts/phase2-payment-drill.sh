#!/usr/bin/env bash
# Prove the Phase 2 seller/buyer payment path after Phase 2 has been bootstrapped.
set -euo pipefail

context="kind-ln-ssdf-phase0"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --context) context="$2"; shift 2 ;;
    *) echo "usage: $0 [--context kind-ln-ssdf-phase0]" >&2; exit 2 ;;
  esac
done
[[ "$context" == "kind-ln-ssdf-phase0" ]] || { echo "payment drill is limited to the explicit Phase 0 kind context" >&2; exit 2; }
for command in jq kubectl; do command -v "$command" >/dev/null || { echo "missing $command" >&2; exit 1; }; done

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

# lnd-primary is the seller; lnd-peer is the buyer. A new regtest network at
# height zero is not synced yet, so wait for RPC before mining its first block.
for _ in $(seq 1 30); do
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
lncli_exec lnd-primary-0 getinfo | jq -e '.synced_to_chain == true' >/dev/null
lncli_exec lnd-peer-0 getinfo | jq -e '.synced_to_chain == true' >/dev/null
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
    invoice="$(lncli_exec "$payee" addinvoice --amt="$amount" | jq -er '.payment_request')"
    if result="$(lncli_exec "$payer" payinvoice --force --json "$invoice" 2>&1)" && \
       jq -e 'select(.status == "SUCCEEDED")' <<<"$result" >/dev/null; then return 0; fi
    sleep 2
  done
  echo "payment from $payer to $payee did not settle after 10 independent attempts" >&2
  return 1
}

# Buyer settles a seller invoice, followed by the reverse payment to establish
# that both endpoints can issue and pay over the new channel.
pay_with_retry lnd-peer-0 lnd-primary-0 10000
pay_with_retry lnd-primary-0 lnd-peer-0 7000
kubectl --context "$context" -n ssdf-system exec ssdf-postgres-0 -- psql -U postgres -d lnd -Atc \
  "SELECT count(*) FROM pg_tables WHERE schemaname='public'" | awk '$1 >= 6 {ok=1} END {exit !ok}'
# Do not use grep -q: it may cause a SIGPIPE under pipefail despite a match.
kubectl --context "$context" -n ssdf-system logs lnd-primary-0 -c lnd | grep -F 'Using remote postgres database' >/dev/null
lncli_exec lnd-peer-0 listchannels | jq -e '.channels | length == 1 and .[0].active == true' >/dev/null
echo "Phase 2 seller/buyer payment drill passed. Buyer settled a seller invoice and the reverse payment settled."
