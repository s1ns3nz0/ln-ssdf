import { createHash } from 'node:crypto';
import { readFileSync, writeFileSync } from 'node:fs';

const [sbomPath, scanPath, image, outputPath] = process.argv.slice(2);
if (![sbomPath, scanPath, image, outputPath].every(Boolean)) {
  throw new Error('usage: generate-phase7-vsa.mjs SBOM.json SCAN.json IMAGE VSA.json');
}
const digest = (path) => createHash('sha256').update(readFileSync(path)).digest('hex');
const scan = JSON.parse(readFileSync(scanPath, 'utf8'));
const blocked = [];
for (const result of scan.Results ?? []) for (const finding of result.Vulnerabilities ?? []) {
  const severity = String(finding.Severity ?? '').toUpperCase();
  const fixed = Boolean(finding.FixedVersion);
  if ((severity === 'CRITICAL') || (severity === 'HIGH' && fixed)) {
    blocked.push({ id: finding.VulnerabilityID, severity, fixedVersion: finding.FixedVersion ?? null, target: result.Target ?? null });
  }
}
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
    rules: ['fixed HIGH', 'fixed CRITICAL', 'unfixed CRITICAL']
  },
  inputAttestations: [
    { uri: 'urn:ln-ssdf:sbom:cyclonedx', digest: { sha256: digest(sbomPath) } },
    { uri: 'urn:ln-ssdf:scan:trivy', digest: { sha256: digest(scanPath) } }
  ],
  blockingFindings: blocked
};
writeFileSync(outputPath, `${JSON.stringify(predicate, null, 2)}\n`, { mode: 0o600 });
console.log(JSON.stringify({ result: predicate.verificationResult, sbomDigest: predicate.inputAttestations[0].digest.sha256, scanDigest: predicate.inputAttestations[1].digest.sha256, blocked: blocked.length }));
