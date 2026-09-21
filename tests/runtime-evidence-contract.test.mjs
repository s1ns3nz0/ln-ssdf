import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const script = fileURLToPath(new URL('../scripts/record-runtime-evidence.sh', import.meta.url));

for (const [name, record] of [
  ['bearer credential', { event: 'challenge', subject: 'ti-api', outcome: 'passed', correlation_id: '0123456789abcdef', authorization: 'Bearer secret' }],
  ['raw TI document', { event: 'challenge', subject: 'ti-api', outcome: 'passed', correlation_id: '0123456789abcdef', raw_response: 'STIX content' }],
  ['unbounded subject', { event: 'challenge', subject: 'wallet-seed', outcome: 'passed', correlation_id: '0123456789abcdef' }],
  ['nonhex correlation', { event: 'challenge', subject: 'ti-api', outcome: 'passed', correlation_id: 'not-a-safe-id' }],
]) {
  test(`runtime evidence rejects ${name} before database access`, () => {
    const result = spawnSync(script, { input: JSON.stringify(record), encoding: 'utf8' });
    assert.equal(result.status, 2);
    assert.match(result.stderr, /invalid redacted runtime evidence record/);
    assert.equal(result.stdout, '');
  });
}
