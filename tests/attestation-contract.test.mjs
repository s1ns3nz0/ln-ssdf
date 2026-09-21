import assert from 'node:assert/strict';
import test from 'node:test';

import { validateVsa } from '../scripts/lib/attestation-contract.mjs';

const sbomDigest = 'sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

function inputAttestations(digest = sbomDigest.slice('sha256:'.length)) {
  return [{ uri: 'urn:ln-ssdf:sbom:cyclonedx', digest: { sha256: digest } }];
}

test('accepts a passing VSA bound to its image and admitted SBOM attestation digest', () => {
  const result = validateVsa({
    schemaVersion: 1,
    subject: {
      imageDigest: 'sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      sbomDigest,
    },
    inputAttestations: inputAttestations(),
    scan: {
      verdict: 'pass',
      scannedAt: '2026-09-21T00:00:00Z',
      expiresAt: '2026-09-23T00:00:00Z',
    },
  });

  assert.deepEqual(result, { valid: true, errors: [] });
});

test('rejects a missing, non-passing, or already-expired VSA', () => {
  const result = validateVsa({
    schemaVersion: 1,
    subject: {
      imageDigest: 'sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      sbomDigest: 'not-a-digest',
    },
    inputAttestations: [],
    scan: {
      verdict: 'fail',
      scannedAt: '2026-09-23T00:00:00Z',
      expiresAt: '2026-09-21T00:00:00Z',
    },
  });

  assert.deepEqual(result, {
    valid: false,
    errors: [
      'subject.sbomDigest must be a sha256 digest.',
      'CycloneDX input attestation must contain a sha256 digest.',
      'scan.verdict must be pass.',
      'scan.expiresAt must be after scan.scannedAt.',
    ],
  });
});

test('rejects a VSA that is expired at admission time or bound to another subject', () => {
  const result = validateVsa({
    schemaVersion: 1,
    subject: {
      imageDigest: 'sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      sbomDigest,
    },
    inputAttestations: inputAttestations(),
    scan: {
      verdict: 'pass',
      scannedAt: '2026-09-21T00:00:00Z',
      expiresAt: '2026-09-22T00:00:00Z',
    },
  }, {
    now: '2026-09-22T00:00:00Z',
    imageDigest: 'sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc',
    sbomDigest,
  });

  assert.deepEqual(result, {
    valid: false,
    errors: [
      'subject.imageDigest does not match the deployed image digest.',
      'scan.expiresAt must be later than admission time.',
    ],
  });
});

test('rejects a VSA whose SBOM input attestation points at different evidence', () => {
  const result = validateVsa({
    schemaVersion: 1,
    subject: {
      imageDigest: 'sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      sbomDigest,
    },
    inputAttestations: inputAttestations('cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc'),
    scan: {
      verdict: 'pass',
      scannedAt: '2026-09-21T00:00:00Z',
      expiresAt: '2026-09-23T00:00:00Z',
    },
  }, { sbomDigest });

  assert.deepEqual(result, {
    valid: false,
    errors: ['CycloneDX input attestation does not match the signed SBOM digest.'],
  });
});
