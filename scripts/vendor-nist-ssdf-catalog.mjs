import { mkdir, rename, writeFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const commit = '78650f02ad9321bb7b817846f8fbd4f2bcd620de';
const expectedSha256 = '5ec118109d7fca45785ed6cdad23e46bfc6dfb91cc23fd7140b702582f9da766';
const source = `https://raw.githubusercontent.com/usnistgov/oscal-content/${commit}/nist.gov/SP800-218/ver1/json/NIST_SP800-218_ver1_catalog-min.json`;
const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const destination = resolve(root, 'services/evidence-dashboard/fixtures/nist-sp800-218-v1.catalog.json');

const response = await fetch(source);
if (!response.ok) throw new Error(`catalog fetch failed: ${response.status}`);
const body = Buffer.from(await response.arrayBuffer());
const actualSha256 = createHash('sha256').update(body).digest('hex');
if (actualSha256 !== expectedSha256) throw new Error(`catalog hash mismatch: expected ${expectedSha256}, received ${actualSha256}`);
JSON.parse(body.toString('utf8'));
await mkdir(dirname(destination), { recursive: true });
const temporary = `${destination}.tmp`;
await writeFile(temporary, body, { mode: 0o644 });
await rename(temporary, destination);
console.log(`Vendored NIST SP 800-218 Catalog at ${commit} (${actualSha256}).`);
