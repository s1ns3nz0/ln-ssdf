import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

const inventory = readFileSync('manifests/phase7/image-evidence-inventory.yaml', 'utf8');
const gate = readFileSync('scripts/phase7-readiness.sh', 'utf8');

test('Phase 7 inventory exposes every current image as no_evidence rather than verified', () => {
  assert.equal((inventory.match(/^      status: no_evidence$/gm) ?? []).length, 7);
  assert.doesNotMatch(inventory, /^      status: verified$/m);
});

test('Phase 7 readiness blocks both image drift and missing verification evidence', () => {
  assert.doesNotMatch(gate, /\byq\b/);
  assert.match(gate, /runtime image inventory differs/);
  assert.match(gate, /exit 1/);
  assert.match(gate, /not verified/);
  assert.match(gate, /exit 3/);
});
