import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

const migration = readFileSync('db/migrations/phase8-evidence-integrity.sql', 'utf8');
const chart = readFileSync('charts/observability/templates/stack.yaml', 'utf8');
const drill = readFileSync('scripts/phase8-tamper-drill.sh', 'utf8');

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
  assert.match(drill, /tamper alert did not fire/);
  assert.match(drill, /tamper metric did not return to 0/);
});
