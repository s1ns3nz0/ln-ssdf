#!/usr/bin/env bash
# Prove a real L402 challenge, lnd-peer settlement, and authorized retry.
set -euo pipefail

context=""; subject=""
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --context) context="$2"; shift 2 ;;
    --subject) subject="$2"; shift 2 ;;
    *) echo "usage: $0 --context kind-ln-ssdf-phase0 --subject SAFE_SUBJECT" >&2; exit 2 ;;
  esac
done
[[ "$context" == "kind-ln-ssdf-phase0" && "$subject" =~ ^[A-Za-z0-9._-]{1,64}$ ]] || { echo "invalid local context or safe subject" >&2; exit 2; }
for command in jq openssl; do command -v "$command" >/dev/null || { echo "missing $command" >&2; exit 1; }; done
endpoint="http://aperture.ssdf-system.svc:8080/v1/indicator/%5Bipv4-addr:value%20%3D%20%27198.51.100.42%27%5D"
settled_ten_sat_count() {
  kubectl --context "$context" -n ssdf-system exec lnd-peer-0 -c lnd -- \
    lncli --network=regtest --rpcserver=localhost:10009 --tlscertpath=/root/.lnd/tls.cert \
    --macaroonpath=/root/.lnd/data/chain/bitcoin/regtest/admin.macaroon listpayments \
    | jq '[.payments[]? | select(.status == "SUCCEEDED" and ((.value_sat | tonumber?) == 10))] | length'
}
authorized_access_count() {
  # Query through Aperture: the product API's ingress policy prohibits this
  # observation from the buyer and from arbitrary workloads.
  kubectl --context "$context" -n ssdf-system exec deploy/aperture -c aperture -- sh -ec \
    'wget -qO- http://ti-product-api.opencti-system.svc:8080/metrics' \
    | awk '$1 == "ti_product_authorized_accesses_total" { print $2; found=1 } END { exit !found }'
}
# This drill is single-use for a fresh local Phase 9 environment. Refuse to
# mint another invoice if a 10-sat TI payment already settled; a human must
# inspect the existing evidence rather than accidentally spending again.
existing_settlements="$(settled_ten_sat_count)"
[[ "$existing_settlements" == "0" ]] || { echo "refusing another Phase 9 payment: a 10-sat settlement already exists" >&2; exit 1; }
before_authorized_accesses="$(authorized_access_count)" || { echo "unable to independently read product authorized-access metric" >&2; exit 1; }
[[ "$before_authorized_accesses" =~ ^[0-9]+$ ]] || { echo "invalid product authorized-access metric" >&2; exit 1; }
output="$(kubectl --context "$context" -n ssdf-system exec deploy/payment-buyer -- \
  payment-buyer --endpoint "$endpoint" --subject "$subject" 2>&1)" || { echo "Phase 9 buyer did not complete; no payment material is printed." >&2; exit 1; }

# Buyer stdout is an exact three-record protocol. Slurp all lines so a log,
# duplicate event, or unexpected field causes rejection before evidence write.
validated="$(printf '%s\n' "$output" | jq -cse --arg expected_subject "$subject" \
  -f "$repo_root/scripts/phase9-validate-events.jq")" || {
  echo "buyer output did not satisfy the strict Phase 9 evidence protocol" >&2
  exit 1
}

# Independent ground truth comes from lnd-peer and the protected TI API, not
# buyer stdout. Both observations must increase exactly once before evidence is
# appended; otherwise the drill fails closed and appends nothing.
after_settlements="$(settled_ten_sat_count)"
after_authorized_accesses="$(authorized_access_count)" || { echo "unable to independently read product authorized-access metric" >&2; exit 1; }
[[ "$after_settlements" == "1" && "$after_authorized_accesses" =~ ^[0-9]+$ ]] || { echo "independent Phase 9 observations are invalid" >&2; exit 1; }
[[ "$after_authorized_accesses" -eq $((before_authorized_accesses + 1)) ]] || { echo "TI API authorized-access counter did not increase exactly once" >&2; exit 1; }

# Keep caller-selected subjects, full paths, and buyer-side correlations out of
# the evidence chain. Only verified success records are mapped to its bounded
# vocabulary, then appended one record at a time.
correlation_id="$(openssl rand -hex 16)"
normalized="$(printf '%s\n' "$validated" | jq -ce --arg correlation_id "$correlation_id" '
  { event, subject: "payment-buyer", outcome: "passed",
    endpoint: (if .endpoint | startswith("/v1/indicator/") then "indicator"
               elif .endpoint | startswith("/v1/campaign/") then "campaign"
               else "report" end),
    amount_sat, correlation_id: $correlation_id }
')"
while IFS= read -r record; do
  printf '%s\n' "$record" | "$repo_root/scripts/record-runtime-evidence.sh" --context "$context" >/dev/null
done <<<"$normalized"
printf '%s\n' "$normalized"
