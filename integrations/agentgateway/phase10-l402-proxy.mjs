import { createServer } from 'node:http';
import { randomUUID } from 'node:crypto';

const HOP_BY_HOP_HEADERS = new Set([
  'connection', 'keep-alive', 'proxy-authenticate', 'proxy-authorization',
  'te', 'trailer', 'transfer-encoding', 'upgrade', 'host', 'content-length',
]);

export const DEFAULT_ALLOWED_ROUTES = [
  'GET:/v1/indicator/*',
  'GET:/v1/campaign/*',
  'GET:/v1/report/*',
];

function parseAllowedRoutes(routes) {
  return routes.map((route) => {
    const match = /^([A-Z]+):((?:\/[^*]*)?\*)$/.exec(route);
    if (!match) throw new Error(`invalid allowed route: ${route}`);
    return { method: match[1], prefix: match[2].slice(0, -1) };
  });
}

function requestHeaders(headers) {
  const forwarded = new Headers();
  for (const [name, value] of Object.entries(headers)) {
    if (value !== undefined && !HOP_BY_HOP_HEADERS.has(name.toLowerCase())) {
      forwarded.set(name, Array.isArray(value) ? value.join(', ') : value);
    }
  }
  return forwarded;
}

function responseHeaders(headers) {
  const forwarded = {};
  for (const [name, value] of headers.entries()) {
    if (!HOP_BY_HOP_HEADERS.has(name.toLowerCase())) forwarded[name] = value;
  }
  return forwarded;
}

function send(response, status, headers, body = '') {
  response.writeHead(status, headers);
  response.end(body);
}

/**
 * Reverse proxy for an Aperture-compatible L402 backend.
 *
 * It does not mint or validate L402 credentials. The caller's Authorization
 * header and the backend's WWW-Authenticate challenge are forwarded verbatim.
 */
export function createPhase10L402Proxy({
  backendUrl,
  allowedRoutes = DEFAULT_ALLOWED_ROUTES,
  timeoutMs = 5_000,
  fetchImpl = fetch,
}) {
  const backend = new URL(backendUrl);
  if (!['http:', 'https:'].includes(backend.protocol)) {
    throw new Error('L402 backend URL must use http or https');
  }
  if (!Number.isInteger(timeoutMs) || timeoutMs < 1) {
    throw new Error('payment backend timeout must be a positive integer');
  }
  const routes = parseAllowedRoutes(allowedRoutes);

  return createServer(async (request, response) => {
    const path = new URL(request.url, 'http://phase10.invalid').pathname;
    if (request.method === 'GET' && path === '/healthz') {
      send(response, 200, { 'cache-control': 'no-store' }, 'ok\n');
      return;
    }

    const route = routes.find((candidate) =>
      candidate.method === request.method && path.startsWith(candidate.prefix));
    if (!route) {
      const methodMatchesPath = routes.some((candidate) => path.startsWith(candidate.prefix));
      send(response, methodMatchesPath ? 405 : 404,
        methodMatchesPath ? { allow: 'GET', 'cache-control': 'no-store' } : { 'cache-control': 'no-store' });
      return;
    }

    const correlationId = randomUUID();
    const target = new URL(request.url, backend);
    // URL(request.url, backend) treats a leading slash as an absolute backend path.
    target.protocol = backend.protocol;
    target.host = backend.host;
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), timeoutMs);
    const headers = requestHeaders(request.headers);
    headers.set('x-phase10-correlation-id', correlationId);

    try {
      const upstream = await fetchImpl(target, {
        method: request.method,
        headers,
        redirect: 'manual',
        signal: controller.signal,
      });
      const headersOut = responseHeaders(upstream.headers);
      headersOut['x-phase10-correlation-id'] = correlationId;
      send(response, upstream.status, headersOut, Buffer.from(await upstream.arrayBuffer()));
    } catch (error) {
      const timeout = error?.name === 'AbortError';
      send(response, timeout ? 504 : 502, {
        'cache-control': 'no-store',
        'content-type': 'application/json',
        'x-phase10-correlation-id': correlationId,
      }, JSON.stringify({ error: timeout ? 'payment_backend_timeout' : 'payment_backend_unavailable', correlationId }));
    } finally {
      clearTimeout(timer);
    }
  });
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const backendUrl = process.env.L402_BACKEND_URL;
  if (!backendUrl) throw new Error('L402_BACKEND_URL is required');
  const allowedRoutes = process.env.L402_ALLOWED_ROUTES
    ? process.env.L402_ALLOWED_ROUTES.split(',')
    : DEFAULT_ALLOWED_ROUTES;
  const port = Number.parseInt(process.env.PORT ?? '8080', 10);
  if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error('PORT must be a valid TCP port');
  const timeoutMs = Number.parseInt(process.env.L402_BACKEND_TIMEOUT_MS ?? '5000', 10);
  const server = createPhase10L402Proxy({
    backendUrl,
    allowedRoutes,
    timeoutMs,
  });
  server.listen(port, '0.0.0.0', () => console.log(`phase10 L402 adapter listening on ${port}`));
}
