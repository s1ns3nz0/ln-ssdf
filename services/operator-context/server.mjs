import { createServer } from 'node:http';
const port = Number(process.env.PORT || 8080), prometheus = process.env.PROMETHEUS_URL || 'http://prometheus:9090', maxBody = 32768;
const allowed = { critical_alerts: 'count(ALERTS{alertstate="firing",severity="critical"})', healthy_targets: 'sum(up == 1)', l402_failure_rate: 'sum(rate(l402_failures_total[15m])) / clamp_min(sum(rate(l402_authorized_accesses_total[15m])) + sum(rate(l402_failures_total[15m])), 1)' };
let alerts = [];
const json = (res, status, value) => { res.writeHead(status, { 'content-type': 'application/json', 'cache-control': 'no-store', 'x-content-type-options': 'nosniff' }); res.end(JSON.stringify(value)); };
async function read(req) { let value = ''; for await (const chunk of req) { value += chunk; if (Buffer.byteLength(value) > maxBody) throw Error(); } return JSON.parse(value || '{}'); }
function summary(a) { return { name: String(a.labels?.alertname || 'unknown').slice(0, 128), severity: String(a.labels?.severity || 'unknown').slice(0, 32), state: String(a.status || 'unknown').slice(0, 32), workload: String(a.labels?.pod || a.labels?.job || '').slice(0, 128), errorClass: String(a.labels?.reason || '').slice(0, 64), runbookStep: 'Inspect dashboard and trace ID; do not retrieve raw logs.', traceId: String(a.annotations?.trace_id || '').replace(/[^a-f0-9]/gi, '').slice(0, 32) }; }
async function metric(name) { if (!allowed[name]) throw Error(); const r = await fetch(`${prometheus}/api/v1/query?query=${encodeURIComponent(allowed[name])}`); if (!r.ok) throw Error(); const v = await r.json(); return { name, value: v.data?.result?.[0]?.value?.[1] ?? null }; }
createServer(async (req, res) => { try {
  if (req.method === 'GET' && req.url === '/healthz') return json(res, 200, { status: 'ok' });
  if (req.method === 'POST' && req.url === '/alertmanager') { const b = await read(req); alerts = Array.isArray(b.alerts) ? b.alerts.slice(0, 20).map(summary) : []; return json(res, 200, { accepted: alerts.length }); }
  if (req.method !== 'POST' || req.url !== '/mcp') return json(res, 404, { error: 'not found' }); const r = await read(req);
  if (r.method === 'initialize') return json(res, 200, { jsonrpc: '2.0', id: r.id, result: { protocolVersion: '2024-11-05', capabilities: { tools: {} }, serverInfo: { name: 'operator-context', version: '0.1.0' } } });
  if (r.method === 'tools/list') return json(res, 200, { jsonrpc: '2.0', id: r.id, result: { tools: [{ name: 'operator_context', description: 'Returns bounded operator context without logs or secrets.', inputSchema: { type: 'object', properties: { metric: { enum: Object.keys(allowed) } } } }] } });
  if (r.method === 'tools/call' && r.params?.name === 'operator_context') return json(res, 200, { jsonrpc: '2.0', id: r.id, result: { content: [{ type: 'text', text: JSON.stringify({ alerts, metric: await metric(r.params.arguments?.metric || 'critical_alerts') }) }] } });
  return json(res, 200, { jsonrpc: '2.0', id: r.id, error: { code: -32601, message: 'method not found' } });
} catch { return json(res, 400, { error: 'invalid bounded request' }); } }).listen(port, '0.0.0.0');
