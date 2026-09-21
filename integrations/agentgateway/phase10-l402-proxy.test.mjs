import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import test from 'node:test';
import { createPhase10L402Proxy } from './phase10-l402-proxy.mjs';

async function listen(server) {
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  return `http://127.0.0.1:${server.address().port}`;
}

async function close(server) {
  await new Promise((resolve, reject) => server.close((error) => error ? reject(error) : resolve()));
}

async function fixture(t, handler, options = {}) {
  const backend = createServer(handler);
  const backendUrl = await listen(backend);
  const proxy = createPhase10L402Proxy({ backendUrl, timeoutMs: 50, ...options });
  const proxyUrl = await listen(proxy);
  t.after(async () => { await close(proxy); await close(backend); });
  return proxyUrl;
}

test('passes Aperture L402 challenges and retry credentials without owning them', async (t) => {
  const proxyUrl = await fixture(t, (request, response) => {
    assert.equal(request.url, '/v1/indicator/198.51.100.9');
    assert.match(request.headers['x-phase10-correlation-id'], /^[0-9a-f-]{36}$/);
    if (!request.headers.authorization) {
      response.writeHead(402, { 'www-authenticate': 'L402 macaroon="opaque", invoice="lnbcrt1..."' });
      response.end('payment required');
      return;
    }
    assert.equal(request.headers.authorization, 'L402 opaque:preimage');
    response.writeHead(200, { 'content-type': 'application/json' });
    response.end('{"indicator":"ok"}');
  });

  const challenge = await fetch(`${proxyUrl}/v1/indicator/198.51.100.9`);
  assert.equal(challenge.status, 402);
  assert.match(challenge.headers.get('www-authenticate'), /^L402 /);
  assert.match(challenge.headers.get('x-phase10-correlation-id'), /^[0-9a-f-]{36}$/);

  const authorized = await fetch(`${proxyUrl}/v1/indicator/198.51.100.9`, {
    headers: { authorization: 'L402 opaque:preimage' },
  });
  assert.equal(authorized.status, 200);
  assert.deepEqual(await authorized.json(), { indicator: 'ok' });
});

test('rejects unallowlisted paths and methods before they reach the payment backend', async (t) => {
  let calls = 0;
  const proxyUrl = await fixture(t, (_request, response) => { calls += 1; response.end('unexpected'); });
  assert.equal((await fetch(`${proxyUrl}/admin`)).status, 404);
  assert.equal((await fetch(`${proxyUrl}/v1/report/daily`, { method: 'POST' })).status, 405);
  assert.equal(calls, 0);
});

test('returns a correlated timeout without exposing backend details', async (t) => {
  const proxyUrl = await fixture(t, (_request, response) => setTimeout(() => response.end('late'), 150));
  const result = await fetch(`${proxyUrl}/v1/campaign/example`);
  assert.equal(result.status, 504);
  const body = await result.json();
  assert.equal(body.error, 'payment_backend_timeout');
  assert.match(body.correlationId, /^[0-9a-f-]{36}$/);
});

test('serves a local health check without contacting Aperture', async (t) => {
  let calls = 0;
  const proxyUrl = await fixture(t, (_request, response) => { calls += 1; response.end('unexpected'); });
  const result = await fetch(`${proxyUrl}/healthz`);
  assert.equal(result.status, 200);
  assert.equal(await result.text(), 'ok\n');
  assert.equal(calls, 0);
});

test('rejects invalid route and timeout configuration at startup', () => {
  assert.throws(() => createPhase10L402Proxy({
    backendUrl: 'http://127.0.0.1:8080', timeoutMs: 0,
  }), /positive integer/);
  assert.throws(() => createPhase10L402Proxy({
    backendUrl: 'file:///tmp/not-a-payment-backend', timeoutMs: 1,
  }), /must use http or https/);
});
