import assert from 'node:assert/strict';
import test from 'node:test';
import { execFileSync } from 'node:child_process';

test('OSCAL documents preserve the DEPLOY-REQ-4 trace and five project statuses', () => {
  const result = execFileSync(process.execPath, ['scripts/validate-oscal-trace.mjs'], { encoding: 'utf8' });
  assert.match(result, /OSCAL trace and project-status mapping are valid/);
});
