import assert from 'node:assert/strict';
import test from 'node:test';

import { validateRecoveryApproval } from '../scripts/lib/recovery-approval.mjs';

const approval = {
  workload: 'lnd-primary', namespace: 'experiment-2',
  imageDigest: 'sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  policyVersion: '2026-09-21', approvedBy: 'system:serviceaccount:experiment-2:ci-deployer',
  issuedAt: '2026-09-21T06:00:00Z',
  evidenceFreshUntil: '2026-09-21T06:05:00Z',
  executionLeaseExpiresAt: '2026-09-21T06:10:00Z',
  trustState: 'trusted', trustStateExpiresAt: '2026-09-21T06:07:00Z',
  pod: {
    metadata: {
      annotations: { 'ln-ssdf.io/policy-version': '2026-09-21', 'ln-ssdf.io/recovery': 'true' },
      labels: { 'ln-ssdf.io/workload': 'lnd-primary' },
    },
    spec: {
      containers: [{ image: 'registry/lnd@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', name: 'lnd-primary' }],
      restartPolicy: 'Never',
    },
  },
};

test('allows an exact request during the execution lease even after the issuance-time evidence snapshot expires', () => {
  assert.deepEqual(validateRecoveryApproval(approval, {
    ...approval, now: '2026-09-21T06:06:00Z',
  }), { valid: true, errors: [] });
});

test('rejects a changed image, complete Pod template, requester, or stale trust state', () => {
  const result = validateRecoveryApproval(approval, {
    ...approval, imageDigest: 'sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc',
    approvedBy: 'system:serviceaccount:experiment-2:other', now: '2026-09-21T06:07:00Z',
    pod: { ...approval.pod, spec: { ...approval.pod.spec, serviceAccountName: 'unapproved' } },
  });
  assert.deepEqual(result.valid, false);
  assert.equal(result.errors.length, 4);
});

test('rejects added sidecars, init containers, and workload-affecting annotations', () => {
  const changes = [
    { spec: { ...approval.pod.spec, containers: [...approval.pod.spec.containers, { image: 'evil', name: 'sidecar' }] } },
    { spec: { ...approval.pod.spec, initContainers: [{ image: 'evil', name: 'init' }] } },
    { metadata: { ...approval.pod.metadata, annotations: { ...approval.pod.metadata.annotations, 'sidecar.istio.io/inject': 'true' } } },
  ];

  for (const change of changes) {
    const pod = { ...approval.pod, ...change };
    const result = validateRecoveryApproval(approval, { ...approval, pod, now: '2026-09-21T06:06:00Z' });
    assert.deepEqual(result, { valid: false, errors: ['complete Pod template does not match approval.'] });
  }
});

test('rejects an approval whose execution lease has elapsed or exceeds the rollout bound', () => {
  const elapsed = validateRecoveryApproval(approval, {
    ...approval, now: '2026-09-21T06:10:00Z',
  });
  assert.equal(elapsed.valid, false);
  assert.deepEqual(elapsed.errors, ['execution lease is expired.', 'current trust state is stale or expired.']);

  const oversized = validateRecoveryApproval({
    ...approval, executionLeaseExpiresAt: '2026-09-21T06:10:01Z',
  }, {
    ...approval, now: '2026-09-21T06:06:00Z',
  });
  assert.equal(oversized.valid, false);
  assert.deepEqual(oversized.errors, ['execution lease must be positive and no longer than 10 minutes.']);
});
