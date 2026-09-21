import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
test('CI pins actions and reserves keyless signing for main pushes', () => {
  const workflow = readFileSync('.github/workflows/ci.yml', 'utf8');
  assert.match(workflow, /actions\/checkout@[0-9a-f]{40}/);
  assert.match(workflow, /sigstore\/cosign-installer@[0-9a-f]{40}/);
  assert.match(workflow, /id-token: write/);
  assert.match(workflow, /github\.event_name == 'push' && github\.ref == 'refs\/heads\/main'/);
  assert.match(workflow, /cosign sign-blob --yes/);
  const verifier = readFileSync('scripts/verify-ci-provenance.sh', 'utf8');
  assert.match(verifier, /--certificate-oidc-issuer 'https:\/\/token\.actions\.githubusercontent\.com'/);
  assert.match(verifier, /github\.com\/\$\{repository\}\/.github\/workflows\/ci\.yml@refs\/heads\/main/);
});
