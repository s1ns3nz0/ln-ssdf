import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

const script = readFileSync('scripts/phase12-a2a-e2e-acceptance.sh', 'utf8');

test('Phase 12 A2A acceptance orders synthetic alert, pending proposal, scoped approval, restart, and evidence', () => {
  assert.match(script, /port-forward --address 127\.0\.0\.1 deployment\/alertmanager 19093:9093/);
  assert.match(script, /grep -q 'Forwarding from 127\.0\.0\.1:19093' "\$forward_log"/);
  assert.match(script, /kill -0 "\$forward_pid"/);
  assert.match(script, /\/api\/v2\/alerts/);
  assert.match(script, /TiApiAvailabilityLow/);
  assert.match(script, /alert_run_id="\$\{forward_log##\*-\}"/);
  assert.match(script, /\.spec\.approved == false and \.spec\.approvedBy == "pending"/);
  assert.match(script, /phase12-a2a-operator/);
  assert.match(script, /auth can-i patch remediationrequests\.aiops\.ln-ssdf\.io/);
  assert.match(script, /ln-ssdf\.io\/last-remediation/);
  assert.match(script, /\.endpoint == "kubernetes-api"/);
  assert.match(script, /endpoint: "none"/);
  assert.match(script, /record-runtime-evidence\.sh/);
  assert.match(script, /Shared evidence append is last/);
  assert.doesNotMatch(script, /OPENROUTER_API_KEY|\.env/);
});
