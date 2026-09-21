const SHA256_DIGEST = /^sha256:[a-f0-9]{64}$/;

export function validateVsa(value, expected = {}) {
  const errors = [];

  if (!value || typeof value !== 'object') {
    return { valid: false, errors: ['VSA must be an object.'] };
  }

  if (value.schemaVersion !== 1) errors.push('schemaVersion must be 1.');
  if (!SHA256_DIGEST.test(value.subject?.imageDigest ?? '')) {
    errors.push('subject.imageDigest must be a sha256 digest.');
  }
  if (!SHA256_DIGEST.test(value.subject?.sbomDigest ?? '')) {
    errors.push('subject.sbomDigest must be a sha256 digest.');
  }
  if (SHA256_DIGEST.test(expected.imageDigest ?? '')
    && value.subject?.imageDigest !== expected.imageDigest) {
    errors.push('subject.imageDigest does not match the deployed image digest.');
  }
  if (SHA256_DIGEST.test(expected.sbomDigest ?? '')
    && value.subject?.sbomDigest !== expected.sbomDigest) {
    errors.push('subject.sbomDigest does not match the signed SBOM digest.');
  }
  const sbomInput = value.inputAttestations?.find((attestation) => (
    attestation?.uri === 'urn:ln-ssdf:sbom:cyclonedx'
  ));
  if (!SHA256_DIGEST.test(sbomInput?.digest?.sha256 ? `sha256:${sbomInput.digest.sha256}` : '')) {
    errors.push('CycloneDX input attestation must contain a sha256 digest.');
  }
  if (SHA256_DIGEST.test(expected.sbomDigest ?? '')
    && sbomInput?.digest?.sha256 !== expected.sbomDigest.slice('sha256:'.length)) {
    errors.push('CycloneDX input attestation does not match the signed SBOM digest.');
  }
  if (value.scan?.verdict !== 'pass') errors.push('scan.verdict must be pass.');
  if (!isIsoInstant(value.scan?.scannedAt)) errors.push('scan.scannedAt must be an ISO-8601 instant.');
  if (!isIsoInstant(value.scan?.expiresAt)) errors.push('scan.expiresAt must be an ISO-8601 instant.');
  if (isIsoInstant(value.scan?.scannedAt) && isIsoInstant(value.scan?.expiresAt)
    && Date.parse(value.scan.expiresAt) <= Date.parse(value.scan.scannedAt)) {
    errors.push('scan.expiresAt must be after scan.scannedAt.');
  }
  if (isIsoInstant(expected.now) && isIsoInstant(value.scan?.expiresAt)
    && Date.parse(value.scan.expiresAt) <= Date.parse(expected.now)) {
    errors.push('scan.expiresAt must be later than admission time.');
  }

  return { valid: errors.length === 0, errors };
}

function isIsoInstant(value) {
  return typeof value === 'string' && !Number.isNaN(Date.parse(value));
}
