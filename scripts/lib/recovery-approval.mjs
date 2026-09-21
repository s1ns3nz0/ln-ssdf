const digest = /^sha256:[a-f0-9]{64}$/;

export function validateRecoveryApproval(approval, request) {
  const errors = [];
  for (const field of ['workload', 'namespace', 'imageDigest', 'policyVersion', 'approvedBy']) {
    if (approval?.[field] !== request?.[field]) errors.push(`${field} does not match approval.`);
  }
  if (stableJson(approval?.pod) !== stableJson(request?.pod)) {
    errors.push('complete Pod template does not match approval.');
  }
  if (!digest.test(approval?.imageDigest ?? '')) errors.push('approval image digest is invalid.');
  const issuedAt = Date.parse(approval?.issuedAt);
  const evidenceFreshUntil = Date.parse(approval?.evidenceFreshUntil);
  const executionLeaseExpiresAt = Date.parse(approval?.executionLeaseExpiresAt);
  const trustStateExpiresAt = Date.parse(approval?.trustStateExpiresAt);
  const now = Date.parse(request?.now);

  if (!Number.isFinite(issuedAt)) errors.push('issuedAt is invalid.');
  if (!Number.isFinite(evidenceFreshUntil) || evidenceFreshUntil <= issuedAt) {
    errors.push('evidence was not fresh when the approval was issued.');
  }
  if (!Number.isFinite(executionLeaseExpiresAt) || executionLeaseExpiresAt <= issuedAt
    || executionLeaseExpiresAt - issuedAt > 10 * 60 * 1000) {
    errors.push('execution lease must be positive and no longer than 10 minutes.');
  }
  if (!Number.isFinite(executionLeaseExpiresAt) || executionLeaseExpiresAt <= now) {
    errors.push('execution lease is expired.');
  }
  if (approval?.trustState !== 'trusted') errors.push('current trust state is not trusted.');
  if (!Number.isFinite(trustStateExpiresAt) || trustStateExpiresAt <= now) {
    errors.push('current trust state is stale or expired.');
  }
  return { valid: errors.length === 0, errors };
}

function stableJson(value) {
  if (Array.isArray(value)) return `[${value.map(stableJson).join(',')}]`;
  if (value && typeof value === 'object') {
    return `{${Object.keys(value).sort().map((key) => `${JSON.stringify(key)}:${stableJson(value[key])}`).join(',')}}`;
  }
  return JSON.stringify(value);
}
