import { createHash } from 'node:crypto';
import { readFileSync, writeFileSync } from 'node:fs';

const [sbomPath, scanPath, image, outputPath] = process.argv.slice(2);
if (![sbomPath, scanPath, image, outputPath].every(Boolean)) {
  throw new Error('usage: generate-phase7-vsa.mjs SBOM.json SCAN.json IMAGE VSA.json');
}
const gateMode = process.env.PHASE7_VSA_GATE_MODE ?? 'diagnostic';
if (!['diagnostic', 'enforce'].includes(gateMode)) {
  throw new Error('PHASE7_VSA_GATE_MODE must be diagnostic or enforce');
}
const digest = (path) => createHash('sha256').update(readFileSync(path)).digest('hex');
const scan = JSON.parse(readFileSync(scanPath, 'utf8'));
const findings = [];
for (const result of scan.Results ?? []) for (const finding of result.Vulnerabilities ?? []) {
  const severity = String(finding.Severity ?? '').toUpperCase();
  const fixed = Boolean(finding.FixedVersion);
  if ((severity === 'CRITICAL') || (severity === 'HIGH' && fixed)) {
    findings.push({ id: finding.VulnerabilityID, severity, fixedVersion: finding.FixedVersion ?? null, target: result.Target ?? null });
  }
}
const blocked = gateMode === 'enforce' ? findings : [];
const now = new Date();
const expires = new Date(now.getTime() + 48 * 60 * 60 * 1000);
const predicate = {
  verifier: { id: 'https://github.com/s1ns3nz0/ln-ssdf/.github/workflows/phase7-image-evidence.yml' },
  timeVerified: now.toISOString(),
  expiresAt: expires.toISOString(),
  resourceUri: image,
  verificationResult: blocked.length === 0 ? 'PASSED' : 'FAILED',
  policy: {
    uri: 'https://github.com/s1ns3nz0/ln-ssdf/blob/main/docs/design-decisions.md',
    mode: gateMode,
    rules: gateMode === 'diagnostic'
      ? ['signed SBOM', 'fresh scan', 'record fixed HIGH, fixed CRITICAL, and unfixed CRITICAL findings']
      : ['fixed HIGH', 'fixed CRITICAL', 'unfixed CRITICAL']
  },
  inputAttestations: [
    { uri: 'urn:ln-ssdf:sbom:cyclonedx', digest: { sha256: digest(sbomPath) } },
    { uri: 'urn:ln-ssdf:scan:trivy', digest: { sha256: digest(scanPath) } }
  ],
  blockingFindings: blocked,
  observedFindings: findings
};
writeFileSync(outputPath, `${JSON.stringify(predicate, null, 2)}\n`, { mode: 0o600 });
console.log(JSON.stringify({ mode: gateMode, result: predicate.verificationResult, sbomDigest: predicate.inputAttestations[0].digest.sha256, scanDigest: predicate.inputAttestations[1].digest.sha256, observed: findings.length, blocked: blocked.length }));
