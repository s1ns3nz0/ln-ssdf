#!/usr/bin/env bash
set -euo pipefail

namespace="ssdf-system"
release="ssdf"
context=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --namespace) namespace="$2"; shift 2 ;;
    --release) release="$2"; shift 2 ;;
    --context) context="$2"; shift 2 ;;
    *) echo "usage: $0 --context NAME [--namespace NAME] [--release NAME]" >&2; exit 2 ;;
  esac
done

if [[ -z "$context" ]]; then
  echo "--context is required; refusing to rely on the ambient kubectl context" >&2
  exit 2
fi

pod="${release}-postgres-0"
kubectl --context "$context" -n "$namespace" rollout status "statefulset/${release}-postgres" --timeout=180s
kubectl --context "$context" -n "$namespace" get pvc "data-${release}-postgres-0" -o jsonpath='{.status.phase}' | grep -qx Bound

schema_state="$(kubectl --context "$context" -n "$namespace" exec "$pod" -- psql -U postgres -d ssdf -Atc "SELECT CASE WHEN to_regclass('public.evidence') IS NULL AND to_regclass('public.current_requirement_status') IS NULL AND to_regclass('public.schema_migrations') IS NULL THEN 'absent' WHEN to_regclass('public.evidence') IS NOT NULL AND to_regclass('public.current_requirement_status') IS NOT NULL AND to_regclass('public.schema_migrations') IS NOT NULL THEN 'complete' ELSE 'partial' END")"
case "$schema_state" in
  absent)
    # A single transaction prevents a failed initial apply from leaving a partial
    # schema. Subsequent verification runs detect the completed schema and do not
    # repeat DDL.
    kubectl --context "$context" -n "$namespace" exec -i "$pod" -- psql -U postgres -d ssdf --single-transaction -v ON_ERROR_STOP=1 < db/schema.sql
    ;;
  complete) ;;
  partial)
    echo "refusing to apply Phase 0 schema over a partial existing schema" >&2
    exit 1
    ;;
  *)
    echo "unexpected schema state: $schema_state" >&2
    exit 1
    ;;
esac
databases="$(kubectl --context "$context" -n "$namespace" exec "$pod" -- psql -U postgres -d postgres -Atc "SELECT datname FROM pg_database WHERE datname IN ('lnd', 'ssdf') ORDER BY datname")"
[[ "$databases" == $'lnd\nssdf' ]]

schema_check="$(kubectl --context "$context" -n "$namespace" exec "$pod" -- psql -U postgres -d ssdf -Atc "SELECT to_regclass('public.evidence') || '|' || to_regclass('public.current_requirement_status') || '|' || COALESCE((SELECT version FROM schema_migrations WHERE version = 'phase0-v1'), '')")"
[[ "$schema_check" == 'evidence|current_requirement_status|phase0-v1' ]]
echo "Phase 0 verification passed: PVC bound, lnd/ssdf databases present, schema applied."
