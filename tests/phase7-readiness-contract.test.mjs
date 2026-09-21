import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

const inventory = readFileSync('manifests/phase7/image-evidence-inventory.yaml', 'utf8');
const gate = readFileSync('scripts/phase7-readiness.sh', 'utf8');

test('Phase 7 inventory records failed evidence without treating it as verified', () => {
  assert.equal((inventory.match(/^      status: failed_vsa$/gm) ?? []).length, 7);
  assert.match(inventory, /^      blockingFindings: [1-9][0-9]*$/m);
  assert.doesNotMatch(inventory, /^      status: verified$/m);
});

test('Phase 7 readiness blocks both image drift and missing verification evidence', () => {
  assert.doesNotMatch(gate, /\byq\b/);
  assert.match(gate, /runtime image inventory differs/);
  assert.match(gate, /exit 1/);
  assert.match(gate, /not verified/);
  assert.match(gate, /exit 3/);
});
