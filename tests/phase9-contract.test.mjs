import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import test from 'node:test';

const buyer = readFileSync('services/payment-buyer/src/main.rs', 'utf8');
const drill = readFileSync('scripts/phase9-acceptance.sh', 'utf8');
const runtime = readFileSync('manifests/phase9/runtime.yaml', 'utf8');
const policy = readFileSync('manifests/phase9/network-policies.yaml', 'utf8');
const doc = readFileSync('docs/phase-9.md', 'utf8');
const bootstrap = readFileSync('scripts/phase9-bootstrap.sh', 'utf8');
const api = readFileSync('services/ti-product-api/src/main.rs', 'utf8');
const buyerCargo = readFileSync('services/payment-buyer/Cargo.toml', 'utf8');
const validator = 'scripts/phase9-validate-events.jq';

function validateEvents(events) {
  return spawnSync('jq', ['-cse', '--arg', 'expected_subject', 'threat-research-buyer', '-f', validator], {
    input: events.map((event) => JSON.stringify(event)).join('\n'),
    encoding: 'utf8',
  });
}

function event(eventName, outcome) {
  return {
    event: eventName,
    subject: 'threat-research-buyer',
    outcome,
    endpoint: '/v1/indicator/example',
    amount_sat: 10,
    correlation_id: 'p9-local-run',
  };
}

test('Phase 9 buyer confines spending, routes, retries, and evidence fields', () => {
  assert.match(buyer, /MAX_REQUEST_SAT: u64 = 50/);
  assert.match(buyer, /MAX_RUN_SAT: u64 = 100/);
  assert.match(buyer, /MAX_DAY_SAT: u64 = 200/);
  assert.match(buyer, /try_lock_exclusive/);
  assert.match(buyer, /fee_limit_sat": 1/);
  assert.match(buyer, /invoice amount differs from the allowlisted product price/);
  assert.match(buyer, /"failure"/);
  assert.match(buyer, /format!\("\{byte:02x\}"\)/);
  assert.match(buyer, /starts_with\("\/v1\/indicator\/"\)/);
  assert.match(buyer, /aperture\.ssdf-system\.svc/);
  assert.match(buyer, /endpoint must be the fixed local Aperture service/);
  assert.match(buyer, /save_budget/);
  assert.match(buyer, /envelope\.get\("result"\)/);
  assert.match(buyer, /Some\("SUCCEEDED"\)/);
  assert.match(buyer, /lnd payment failed/);
  assert.match(buyer, /invoice_payment_hash/);
  assert.match(buyer, /settled_payment_preimage/);
  assert.match(buyer, /payment_pending/);
  assert.match(buyerCargo, /native-tls-vendored/);
  assert.doesNotMatch(buyer, /danger_accept_invalid_certs/);
  assert.match(buyer, /LSAT \{\}:\{\}/);
  assert.match(buyer, /"event".*"subject".*"outcome".*"endpoint".*"amount_sat".*"correlation_id"/s);
  assert.doesNotMatch(buyer, /println!\([^\n]*(invoice|preimage|authorization|macaroon)/i);
});

test('Phase 9 manifest keeps the payment credential with only the buyer and restricts egress', () => {
  assert.match(runtime, /secretName: lnd-peer-payment-api/);
  assert.match(runtime, /kind: PersistentVolumeClaim/);
  assert.match(runtime, /payment-buyer-budget/);
  assert.match(runtime, /kind: VaultStaticSecret/);
  assert.match(bootstrap, /invoices:read invoices:write/);
  assert.match(bootstrap, /l402-macaroon-read/);
  assert.match(bootstrap, /offchain:read offchain:write/);
  assert.match(bootstrap, /311220b15b04c06ecabd52c78fde8f5d6ea73c82/);
  assert.match(runtime, /image: ln-ssdf\/aperture:phase9/);
  assert.equal((runtime.match(/secretName: lnd-peer-payment-api/g) ?? []).length, 1);
  assert.match(policy, /payment-buyer-narrow-egress/);
  assert.match(policy, /ln-ssdf\.io\/node: peer/);
  assert.match(policy, /app\.kubernetes\.io\/name: aperture/);
});

test('Phase 9 real-regtest drill prints only redacted common evidence records', () => {
  assert.match(drill, /aperture\.ssdf-system\.svc/);
  assert.doesNotMatch(drill, /aperture-url/);
  assert.match(drill, /phase9-validate-events\.jq/);
  assert.match(drill, /record-runtime-evidence\.sh/);
  assert.match(drill, /subject: "payment-buyer"/);
  assert.match(drill, /openssl rand -hex 16/);
  assert.match(drill, /refusing another Phase 9 payment/);
  assert.match(drill, /settled_ten_sat_count/);
  assert.match(drill, /authorized_access_count/);
  assert.match(drill, /after_settlements.*== "1"/);
  assert.match(drill, /before_authorized_accesses \+ 1/);
  assert.match(drill, /before evidence is/);
  assert.match(doc, /l402_challenges_total/);
  assert.match(doc, /l402_settlements_total/);
  assert.match(doc, /No metric label may contain a subject/);
  assert.match(api, /OPENCTI_GRAPHQL_URL/);
  assert.match(api, /OPENCTI_API_TOKEN_FILE/);
  assert.match(doc, /Phase 9 is partial/);
});

test('Phase 9 event validator accepts only the exact three-line success protocol', () => {
  const valid = [event('challenge', 'received'), event('settlement', 'settled'), event('authorized_access', 'authorized')];
  const result = validateEvents(valid);
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stdout.trim().split('\n').length, 3);

  for (const invalid of [
    [...valid, event('authorized_access', 'authorized')],
    [event('challenge', 'received'), event('settlement', 'failed'), event('authorized_access', 'authorized')],
    [event('challenge', 'received'), { ...event('settlement', 'settled'), amount_sat: 25 }, event('authorized_access', 'authorized')],
    [event('challenge', 'received'), { ...event('settlement', 'settled'), correlation_id: 'other' }, event('authorized_access', 'authorized')],
  ]) {
    assert.notEqual(validateEvents(invalid).status, 0);
  }
});
