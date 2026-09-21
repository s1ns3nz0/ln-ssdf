import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

const migration = readFileSync('db/migrations/phase8-evidence-integrity.sql', 'utf8');
const chart = readFileSync('charts/observability/templates/stack.yaml', 'utf8');
const drill = readFileSync('scripts/phase8-tamper-drill.sh', 'utf8');
const policies = readFileSync('manifests/phase8/network-policies.yaml', 'utf8');
const guard = readFileSync('scripts/lib/phase8-local-kind-guard.sh', 'utf8');

test('Phase 8 recomputes prior links and row hashes under a restricted verifier', () => {
  assert.match(migration, /verify_evidence_chain/);
  assert.match(migration, /candidate\.previous_hash IS DISTINCT FROM prior_hash/);
  assert.match(migration, /candidate\.row_hash IS DISTINCT FROM expected_hash/);
  assert.match(migration, /REVOKE ALL ON FUNCTION verify_evidence_chain\(\) FROM PUBLIC/);
});

test('Phase 8 connects detector metric to a Prometheus alert and reversible drill', () => {
  assert.match(chart, /ssdf_evidence_chain_tamper_detected > 0/);
  assert.match(chart, /alert: SsdfEvidenceTamperDetected/);
  assert.match(drill, /ALTER TABLE evidence DISABLE TRIGGER evidence_append_only/);
  assert.match(drill, /WHERE evidence_id = :'fixture_id'::uuid/);
  assert.match(drill, /--confirm-local-tamper-drill/);
  assert.match(drill, /trap cleanup EXIT/);
  assert.match(drill, /BEGIN;\nALTER TABLE evidence DISABLE TRIGGER/);
  assert.match(drill, /tamper alert did not fire/);
  assert.match(drill, /tamper metric did not return to 0/);
  assert.match(drill, /tamper alert did not resolve after restoration/);
});

test('Phase 8 refuses a merely similarly named non-kind context', () => {
  assert.match(guard, /docker inspect/);
  assert.match(guard, /kind:\/\/docker\/ln-ssdf-phase0/);
});

test('Phase 8 scopes NetworkPolicy to the tested observability data path', () => {
  assert.match(policies, /postgres-exporter-observability-only/);
  assert.match(policies, /app: prometheus/);
  assert.match(policies, /app\.kubernetes\.io\/name: postgres/);
  assert.match(policies, /k8s-app: kube-dns/);
  assert.match(readFileSync('scripts/phase8-bootstrap.sh', 'utf8'), /unexpectedly reached Prometheus/);
});
