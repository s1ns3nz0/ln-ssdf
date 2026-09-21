export function normalizeBasePath(value = '/lnd') {
  const trimmed = value.trim().replace(/^\/+|\/+$/g, '');
  if (trimmed && (!/^[A-Za-z0-9._-]+(?:\/[A-Za-z0-9._-]+)*$/.test(trimmed) || trimmed.split('/').some((part) => part === '.' || part === '..'))) throw new Error('BASE_PATH contains unsupported characters');
  return trimmed ? `/${trimmed}` : '';
}

export function signalFor({ rawStatus, expiresAt, observedFindings = 0, required = true, now = Date.now() }) {
  if (expiresAt && Date.parse(expiresAt) <= now) return 'Unknown';
  if (rawStatus === 'no_evidence' || rawStatus === 'not_implemented') return 'Unknown';
  if (rawStatus === 'not_satisfied' && required) return 'Blocked';
  if (observedFindings > 0 || rawStatus === 'not_satisfied') return 'Attention';
  return 'Verified';
}

export function publicClaims(kind, claim = {}) {
  const allowed = {
    vsa: ['workflow', 'verificationMode', 'result'],
    scorecard: ['workflow', 'lndScore', 'apertureScore'],
    sbom: ['format', 'generator', 'componentCount'],
    vulnerability_report: ['critical', 'high', 'scannerVersion'],
  }[kind] || [];
  return Object.fromEntries(allowed.filter((key) => Object.hasOwn(claim, key)).map((key) => [key, claim[key]]));
}

export function evidenceRow(row, now) {
  const claims = publicClaims(row.kind, row.claim);
  const observedFindings = row.kind === 'vulnerability_report'
    ? Number(claims.critical || 0) + Number(claims.high || 0)
    : 0;
  return {
    id: row.evidence_id,
    kind: row.kind,
    track: row.track,
    subject: row.subject_ref,
    subjectKind: row.subject_kind,
    issuer: row.issuer,
    sourceUri: row.source_uri,
    observedAt: row.observed_at,
    evaluatedAt: row.evaluated_at,
    expiresAt: row.expires_at,
    policyVersion: row.policy_version,
    claims,
    signal: signalFor({ expiresAt: row.expires_at, observedFindings, now }),
  };
}
