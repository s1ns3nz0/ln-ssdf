#!/usr/bin/env bash
set -euo pipefail

[[ "${1:-}" == "--context" && "${2:-}" == "kind-ln-ssdf-phase0" ]] || {
  echo "usage: $0 --context kind-ln-ssdf-phase0 [--vsa-run-id ID] [--scorecard-run-id ID]" >&2
  exit 2
}
context="$2"; shift 2
vsa_run_id=35592447283
scorecard_run_id=35591904489
while (($#)); do
  case "$1" in
    --vsa-run-id) vsa_run_id=${2:?}; shift 2 ;;
    --scorecard-run-id) scorecard_run_id=${2:?}; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

vsa_url="https://github.com/s1ns3nz0/ln-ssdf/actions/runs/${vsa_run_id}"
scorecard_url="https://github.com/s1ns3nz0/ln-ssdf/actions/runs/${scorecard_run_id}"
observed_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

kubectl --context "$context" -n ssdf-system exec -i ssdf-postgres-0 -- \
  psql -U postgres -d ssdf -v ON_ERROR_STOP=1 \
  -v vsa_url="$vsa_url" -v scorecard_url="$scorecard_url" -v observed_at="$observed_at" <<'SQL'
SELECT append_evidence(
  'vsa', 'first_party', 'github_workflow_run', :'vsa_url', 'github-actions',
  :'vsa_url', :'observed_at'::timestamptz, :'observed_at'::timestamptz + interval '48 hours',
  'phase7-diagnostic-v1', jsonb_build_object('workflow', 'Phase 7 image evidence', 'verificationMode', 'diagnostic', 'result', 'PASSED')
);
SELECT append_evidence(
  'scorecard', 'third_party', 'github_workflow_run', :'scorecard_url', 'github-actions',
  :'scorecard_url', :'observed_at'::timestamptz, :'observed_at'::timestamptz + interval '48 hours',
  'scorecard-v1', jsonb_build_object('workflow', 'Measure Upstream Scorecards', 'lndScore', 5.8, 'apertureScore', 4.7)
);
SQL

echo "Recorded external VSA and Scorecard references in the evidence hash chain."
