#!/usr/bin/env bash
# Read one deliberately narrow, redacted runtime observation from stdin.
set -euo pipefail

context="kind-ln-ssdf-phase0"
if [[ $# -eq 2 && "$1" == "--context" ]]; then context="$2";
elif [[ $# -ne 0 ]]; then echo "usage: $0 [--context kind-ln-ssdf-phase0] < event.json" >&2; exit 2;
fi
[[ "$context" == "kind-ln-ssdf-phase0" ]] || { echo "runtime evidence is limited to the local kind context" >&2; exit 2; }
for tool in jq kubectl; do command -v "$tool" >/dev/null || { echo "missing $tool" >&2; exit 1; }; done
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Drop unknown fields so a caller cannot accidentally store a token, raw TI
# document, log body, or payment preimage in the immutable evidence chain.
claim="$(jq -ce '
  select(type == "object")
  | select((keys - ["event","subject","outcome","endpoint","amount_sat","correlation_id"]) == [])
  | select(.event | IN("challenge","settlement","authorized_access","payment_failure","alert","diagnosis","approval","remediation","chaos","recovery"))
  | select(.subject | IN("ti-api","aperture","payment-buyer","agentgateway","otel-collector","opencti","kagent"))
  | select(.outcome | IN("passed","failed","pending","needs_human"))
  | select((.endpoint // "none") | IN("none","indicator","campaign","report"))
  | select((.amount_sat // 0) | type == "number" and . >= 0 and . <= 200 and floor == .)
  | select((.correlation_id // "") | test("^[a-f0-9]{16,64}$"))
  | {event,subject,outcome,endpoint:(.endpoint // "none"),amount_sat:(.amount_sat // 0),correlation_id}
' <&0)" || { echo "invalid redacted runtime evidence record" >&2; exit 2; }
[[ -n "$claim" ]] || { echo "empty runtime evidence record" >&2; exit 2; }

kubectl --context "$context" -n ssdf-system exec -i ssdf-postgres-0 -- \
  psql -U postgres -d ssdf -v ON_ERROR_STOP=1 < "$repo_root/db/migrations/phase9-12-runtime-evidence.sql" >/dev/null
observed_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
kubectl --context "$context" -n ssdf-system exec -i ssdf-postgres-0 -- \
  psql -U postgres -d ssdf -v ON_ERROR_STOP=1 -v observed_at="$observed_at" \
  -v claim="$claim" <<'SQL'
SELECT evidence_id FROM append_evidence(
  'runtime_observation', 'first_party', 'runtime_event',
  (:'claim'::jsonb->>'event') || ':' || (:'claim'::jsonb->>'correlation_id'), 'local-drill',
  'local://phase9-12/runtime', :'observed_at'::timestamptz, NULL,
  'phase9-12-runtime-v1', :'claim'::jsonb
);
SQL
