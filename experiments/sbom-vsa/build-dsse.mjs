import { readFileSync, writeFileSync } from 'node:fs';

const [mode, input, output] = process.argv.slice(2);
const payloadType = 'application/vnd.in-toto+json';

if (mode === 'pae') {
  const payload = readFileSync(input);
  const pae = Buffer.concat([
    Buffer.from(`DSSEv1 ${Buffer.byteLength(payloadType)} ${payloadType} ${payload.length} `),
    payload,
  ]);
  writeFileSync(output, pae);
} else if (mode === 'envelope') {
  const payload = readFileSync(input);
  const signature = process.env.DSSE_SIGNATURE;
  if (!signature) throw new Error('DSSE_SIGNATURE is required.');
  writeFileSync(output, `${JSON.stringify({
    payload: payload.toString('base64'),
    payloadType,
    signatures: [{ sig: signature.trim() }],
  })}\n`);
} else {
  throw new Error('usage: build-dsse.mjs <pae|envelope> <input> <output>');
}
