import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createHash } from 'node:crypto';
import { artifactFor, buildDashboard, catalogSource, detailFor, publicDashboard } from './model.mjs';
import { normalizeBasePath } from './lib.mjs';

const root = dirname(fileURLToPath(import.meta.url));
const mode = process.env.DASHBOARD_MODE || 'fixture';
if (mode !== 'fixture') throw new Error('Only DASHBOARD_MODE=fixture is implemented for this public SSP posture dashboard');
const basePath = normalizeBasePath(process.env.BASE_PATH || '/lnd');
if (!basePath) throw new Error('BASE_PATH must not be empty');
const port = Number(process.env.PORT || 8080);
if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error('PORT must be a valid TCP port');
const catalogBytes = await readFile(join(root, 'fixtures', 'nist-sp800-218-v1.catalog.json'));
if (createHash('sha256').update(catalogBytes).digest('hex') !== catalogSource.sha256) throw new Error('Vendored NIST SSDF Catalog hash does not match pinned provenance');
const catalogDocument = JSON.parse(catalogBytes.toString('utf8'));
const dashboard = buildDashboard(catalogDocument);

function send(response, status, contentType, body, headOnly = false) {
  response.writeHead(status, { 'content-type': `${contentType}; charset=utf-8`, 'cache-control': 'no-store', 'x-content-type-options': 'nosniff' });
  response.end(headOnly ? undefined : body);
}

function json(response, status, body, headOnly) {
  send(response, status, 'application/json', JSON.stringify(body), headOnly);
}

function escapedPath(path) {
  return path.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

function staticFile(pathname) {
  const relative = pathname.slice(basePath.length) || '/';
  if (relative === '/' || relative === '/index.html') return join(root, 'public', 'index.html');
  if (relative === '/app.js') return join(root, 'public', 'app.js');
  if (relative === '/style.css') return join(root, 'public', 'style.css');
  return null;
}

const server = createServer(async (request, response) => {
  const headOnly = request.method === 'HEAD';
  try {
    if (!['GET', 'HEAD'].includes(request.method || 'GET')) return json(response, 405, { error: 'method not allowed' }, false);
    const url = new URL(request.url, `http://${request.headers.host || 'localhost'}`);
    if (url.pathname !== basePath && !url.pathname.startsWith(`${basePath}/`)) return json(response, 404, { error: 'not found' }, headOnly);
    if (url.pathname === `${basePath}/api/health`) return json(response, 200, { status: 'ok', dataMode: 'fixture', basePath, scenarioTime: dashboard.scenarioTime }, headOnly);
    if (url.pathname === `${basePath}/api/dashboard`) return json(response, 200, publicDashboard(dashboard), headOnly);
    if (url.pathname === `${basePath}/api/raw/catalog`) return json(response, 200, { dataMode: 'fixture', document: catalogDocument }, headOnly);
    const artifact = url.pathname.match(new RegExp('^' + escapedPath(basePath) + '/api/artifacts/(profile|ssp|plan|assessment|poam|otel|jira)/(lnd|aperture)/([A-Z]{2}\\.\\d+\\.\\d+)\\.json$'));
    if (artifact) {
      const payload = artifactFor(dashboard, artifact[1], artifact[2], artifact[3]);
      return payload ? json(response, 200, payload, headOnly) : json(response, 404, { error: 'artifact not found' }, headOnly);
    }
    const detail = url.pathname.match(new RegExp(`^${escapedPath(basePath)}/api/controls/([A-Z]{2}\\.\\d+\\.\\d+)$`));
    if (detail) {
      const payload = detailFor(dashboard, detail[1]);
      return payload ? json(response, 200, payload, headOnly) : json(response, 404, { error: 'control not found' }, headOnly);
    }
    const file = staticFile(url.pathname);
    if (!file) return json(response, 404, { error: 'not found' }, headOnly);
    let content = await readFile(file, 'utf8');
    if (file.endsWith('index.html')) content = content.replaceAll('__BASE_PATH__', basePath);
    const contentType = file.endsWith('.css') ? 'text/css' : file.endsWith('.js') ? 'application/javascript' : 'text/html';
    send(response, 200, contentType, content, headOnly);
  } catch (error) {
    console.error('dashboard request failed:', error.message);
    json(response, 503, { error: 'dashboard data is unavailable' }, headOnly);
  }
});

server.listen(port, '0.0.0.0', () => console.log(`SSDF posture dashboard (${mode}) listening on ${port}${basePath}`));
