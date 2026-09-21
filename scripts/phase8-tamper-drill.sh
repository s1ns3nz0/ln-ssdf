#!/usr/bin/env bash
# This intentionally performs and then restores a controlled local mutation.
# It must only ever target kind-ln-ssdf-phase0, never a real environment.
set -euo pipefail

[[ "${1:-}" == "--context" && "${2:-}" == "kind-ln-ssdf-phase0" ]] || {
  echo "usage: $0 --context kind-ln-ssdf-phase0" >&2
  exit 2
}
context="$2"
k() { kubectl --context "$context" -n ssdf-system "$@"; }

k exec -i ssdf-postgres-0 -- psql -U postgres -d ssdf -v ON_ERROR_STOP=1 <<'SQL'
SELECT append_evidence(
  'policy_report', 'first_party', 'phase8_tamper_drill',
  'urn:ln-ssdf:phase8:tamper-drill', 'phase8-local-drill',
  'local://phase8/tamper-drill', clock_timestamp(), NULL, 'phase8-v1',
  '{"fixture":"intact"}'::jsonb
);
SQL
baseline="$(k exec ssdf-postgres-0 -- psql -U postgres -d ssdf -Atc 'SELECT valid::text FROM verify_evidence_chain()')"
[[ "$baseline" == "true" ]] || { echo "baseline evidence chain is not valid" >&2; exit 1; }

# The local superuser models an attacker who bypasses the append-only trigger.
k exec -i ssdf-postgres-0 -- psql -U postgres -d ssdf -v ON_ERROR_STOP=1 <<'SQL'
ALTER TABLE evidence DISABLE TRIGGER evidence_append_only;
UPDATE evidence SET claim = '{"fixture":"tampered"}'::jsonb
WHERE subject_ref = 'urn:ln-ssdf:phase8:tamper-drill' AND issuer = 'phase8-local-drill';
ALTER TABLE evidence ENABLE TRIGGER evidence_append_only;
SQL
broken="$(k exec ssdf-postgres-0 -- psql -U postgres -d ssdf -Atc 'SELECT valid::text FROM verify_evidence_chain()')"
[[ "$broken" == "false" ]] || { echo "controlled mutation was not detected by the verifier" >&2; exit 1; }

for _ in $(seq 1 15); do
  metric="$(k exec deploy/postgres-exporter -- sh -c \
    'wget -qO- http://127.0.0.1:9187/metrics | awk "$1 == \"ssdf_evidence_chain_tamper_detected\" { print $2 }"')"
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
k exec -i ssdf-postgres-0 -- psql -U postgres -d ssdf -v ON_ERROR_STOP=1 <<'SQL'
ALTER TABLE evidence DISABLE TRIGGER evidence_append_only;
UPDATE evidence SET claim = '{"fixture":"intact"}'::jsonb
WHERE subject_ref = 'urn:ln-ssdf:phase8:tamper-drill' AND issuer = 'phase8-local-drill';
ALTER TABLE evidence ENABLE TRIGGER evidence_append_only;
SQL
for _ in $(seq 1 15); do
  metric="$(k exec deploy/postgres-exporter -- sh -c \
    'wget -qO- http://127.0.0.1:9187/metrics | awk "$1 == \"ssdf_evidence_chain_tamper_detected\" { print $2 }"')"
  [[ "$metric" == "0" ]] && break
  sleep 3
done
[[ "${metric:-}" == "0" ]] || { echo "tamper metric did not return to 0 after restoration" >&2; exit 1; }
echo "Phase 8 tamper drill passed: mutation, metric, firing alert, and restoration verified."
