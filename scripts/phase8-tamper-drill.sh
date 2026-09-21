#!/usr/bin/env bash
# This intentionally performs and then restores a controlled local mutation.
# It must only ever target kind-ln-ssdf-phase0, never a real environment.
set -euo pipefail

[[ "${1:-}" == "--context" && "${2:-}" == "kind-ln-ssdf-phase0" && "${3:-}" == "--confirm-local-tamper-drill" ]] || {
  echo "usage: $0 --context kind-ln-ssdf-phase0 --confirm-local-tamper-drill" >&2
  exit 2
}
context="$2"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$repo_root/scripts/lib/phase8-local-kind-guard.sh"
require_phase8_local_kind "$context"
k() { kubectl --context "$context" -n ssdf-system "$@"; }
fixture_id=""
restore_required=0

cleanup() {
  local status="$?"
  if [[ "$restore_required" == "1" && "$fixture_id" =~ ^[0-9a-f-]{36}$ ]]; then
    k exec -i ssdf-postgres-0 -- psql -U postgres -d ssdf -v ON_ERROR_STOP=1 -v fixture_id="$fixture_id" <<'SQL' >/dev/null 2>&1 || true
BEGIN;
ALTER TABLE evidence DISABLE TRIGGER evidence_append_only;
UPDATE evidence SET claim = '{"fixture":"intact"}'::jsonb
WHERE evidence_id = :'fixture_id'::uuid;
ALTER TABLE evidence ENABLE TRIGGER evidence_append_only;
COMMIT;
SQL
  fi
  exit "$status"
}
trap cleanup EXIT

fixture_id="$(
  k exec -i ssdf-postgres-0 -- psql -U postgres -d ssdf -At -v ON_ERROR_STOP=1 <<'SQL'
SELECT evidence_id FROM append_evidence(
  'policy_report', 'first_party', 'phase8_tamper_drill',
  'urn:ln-ssdf:phase8:tamper-drill', 'phase8-local-drill',
  'local://phase8/tamper-drill', clock_timestamp(), NULL, 'phase8-v1',
  '{"fixture":"intact"}'::jsonb
);
SQL
)"
[[ "$fixture_id" =~ ^[0-9a-f-]{36}$ ]] || { echo "failed to create a dedicated drill fixture" >&2; exit 1; }
baseline="$(k exec ssdf-postgres-0 -- psql -U postgres -d ssdf -Atc 'SELECT valid::text FROM verify_evidence_chain()')"
[[ "$baseline" == "true" ]] || { echo "baseline evidence chain is not valid" >&2; exit 1; }

# The local superuser models an attacker who bypasses the append-only trigger.
restore_required=1
k exec -i ssdf-postgres-0 -- psql -U postgres -d ssdf -v ON_ERROR_STOP=1 -v fixture_id="$fixture_id" <<'SQL'
BEGIN;
ALTER TABLE evidence DISABLE TRIGGER evidence_append_only;
UPDATE evidence SET claim = '{"fixture":"tampered"}'::jsonb
WHERE evidence_id = :'fixture_id'::uuid;
ALTER TABLE evidence ENABLE TRIGGER evidence_append_only;
COMMIT;
SQL
broken="$(k exec ssdf-postgres-0 -- psql -U postgres -d ssdf -Atc 'SELECT valid::text FROM verify_evidence_chain()')"
[[ "$broken" == "false" ]] || { echo "controlled mutation was not detected by the verifier" >&2; exit 1; }

for _ in $(seq 1 15); do
  metric="$(k exec deploy/postgres-exporter -- sh -c \
    "wget -qO- http://127.0.0.1:9187/metrics | grep '^ssdf_evidence_chain_tamper_detected' | cut -d' ' -f2")"
  [[ "$metric" == "1" ]] && break
  sleep 3
done
[[ "${metric:-}" == "1" ]] || { echo "tamper metric did not become 1" >&2; exit 1; }

for _ in $(seq 1 20); do
  alerts="$(k exec deploy/prometheus -- sh -c 'wget -qO- http://127.0.0.1:9090/api/v1/alerts')"
  if jq -e '.data.alerts[] | select(.labels.alertname == "SsdfEvidenceTamperDetected" and .state == "firing")' <<<"$alerts" >/dev/null; then break; fi
  sleep 3
done
jq -e '.data.alerts[] | select(.labels.alertname == "SsdfEvidenceTamperDetected" and .state == "firing")' \
  <<<"${alerts:-}" >/dev/null || { echo "tamper alert did not fire" >&2; exit 1; }

# Restore exactly the fixture claim; the fixture remains as local drill evidence.
k exec -i ssdf-postgres-0 -- psql -U postgres -d ssdf -v ON_ERROR_STOP=1 -v fixture_id="$fixture_id" <<'SQL'
BEGIN;
ALTER TABLE evidence DISABLE TRIGGER evidence_append_only;
UPDATE evidence SET claim = '{"fixture":"intact"}'::jsonb
WHERE evidence_id = :'fixture_id'::uuid;
ALTER TABLE evidence ENABLE TRIGGER evidence_append_only;
COMMIT;
SQL
for _ in $(seq 1 15); do
  metric="$(k exec deploy/postgres-exporter -- sh -c \
    "wget -qO- http://127.0.0.1:9187/metrics | grep '^ssdf_evidence_chain_tamper_detected' | cut -d' ' -f2")"
  [[ "$metric" == "0" ]] && break
  sleep 3
done
[[ "${metric:-}" == "0" ]] || { echo "tamper metric did not return to 0 after restoration" >&2; exit 1; }
for _ in $(seq 1 20); do
  alerts="$(k exec deploy/prometheus -- sh -c 'wget -qO- http://127.0.0.1:9090/api/v1/alerts')"
  if ! jq -e '.data.alerts[]? | select(.labels.alertname == "SsdfEvidenceTamperDetected" and .state == "firing")' \
      <<<"$alerts" >/dev/null; then
    break
  fi
  sleep 3
done
if jq -e '.data.alerts[]? | select(.labels.alertname == "SsdfEvidenceTamperDetected" and .state == "firing")' \
    <<<"${alerts:-}" >/dev/null; then
  echo "tamper alert did not resolve after restoration" >&2
  exit 1
fi
restore_required=0
echo "Phase 8 tamper drill passed: mutation, metric, firing alert, restoration, and alert resolution verified."
