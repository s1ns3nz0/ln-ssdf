import { createServer } from 'node:http';
import { boundedAlert, diagnose, redactedEvidenceEvent, requestId, validateRemediationProposal, validateRemediationRequest } from './lib.mjs';
import { executeApprovedRequest, KubernetesApi } from './kube.mjs';

const port = Number(process.env.PORT || 8080);
const namespace = process.env.REMEDIATION_NAMESPACE || 'ssdf-system';
const api = new KubernetesApi();
const processed = new Set();
let diagnosisInFlight = false;
let activeDiagnosisAlert = '';

function json(response, status, body) {
  response.writeHead(status, { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store', 'x-content-type-options': 'nosniff' });
  response.end(JSON.stringify(body));
}

async function body(request) {
  let text = '';
  for await (const chunk of request) {
    text += chunk;
    if (Buffer.byteLength(text) > 32 * 1024) throw new Error('request body too large');
  }
  return JSON.parse(text || '{}');
}

async function mcpResponse(message) {
  if (message.method === 'initialize') return { jsonrpc: '2.0', id: message.id, result: { protocolVersion: '2024-11-05', capabilities: { tools: {} }, serverInfo: { name: 'remediation-controller', version: '0.2.0' } } };
  if (message.method === 'tools/list') return { jsonrpc: '2.0', id: message.id, result: { tools: [
    { name: 'diagnose_alert', description: 'Returns only the bounded Phase 12 runbook for an allowlisted alert.', inputSchema: { type: 'object', properties: { alert: { type: 'string' }, rounds: { type: 'integer', maximum: 3 } }, required: ['alert'] } },
    { name: 'propose_remediation', description: 'Creates an unapproved RemediationRequest proposal. It never executes an action.', inputSchema: { type: 'object', properties: { action: { enum: ['restartDeployment', 'rollbackHelmRelease'] }, target: { type: 'string' }, namespace: { type: 'string' }, release: { type: 'string' }, alert: { type: 'string' }, reason: { type: 'string', maxLength: 500 } }, required: ['action', 'target', 'namespace', 'reason'] } },
  ] } };
  if (message.method !== 'tools/call') return { jsonrpc: '2.0', id: message.id, error: { code: -32601, message: 'method not found' } };
  const name = message.params?.name;
  const args = message.params?.arguments || {};
  if (name === 'diagnose_alert') return { jsonrpc: '2.0', id: message.id, result: { content: [{ type: 'text', text: JSON.stringify(diagnose({ alert: args.alert, rounds: args.rounds })) }] } };
  if (name === 'propose_remediation') {
    const correlationId = requestId();
    const alertContext = activeDiagnosisAlert ? `alert=${activeDiagnosisAlert}; ` : (args.alert ? `alert=${String(args.alert).slice(0, 80)}; ` : '');
    const proposal = { apiVersion: 'aiops.ln-ssdf.io/v1alpha1', kind: 'RemediationRequest', metadata: { name: `aiops-${correlationId.slice(0, 20)}` }, spec: {
      action: args.action, target: args.target, namespace: args.namespace, release: args.release, reason: `${alertContext}${String(args.reason || '')}`.slice(0, 500), approved: false, approvedBy: 'pending', approvalExpiresAt: new Date(Date.now() + 10 * 60 * 1000).toISOString(),
    } };
    const valid = validateRemediationProposal(proposal);
    if (!valid.valid) return { jsonrpc: '2.0', id: message.id, error: { code: -32602, message: valid.errors.join(' ') } };
    await api.createRequest('ssdf-system', proposal);
    return { jsonrpc: '2.0', id: message.id, result: { content: [{ type: 'text', text: JSON.stringify({ proposal: proposal.metadata.name, approved: false, correlation_id: correlationId }) }] } };
  }
  return { jsonrpc: '2.0', id: message.id, error: { code: -32601, message: 'tool not found' } };
}

async function processApprovedRequests() {
  const list = await api.listRequests(namespace);
  for (const request of list.items || []) {
    if (request.spec?.approved !== true) continue;
    const key = `${request.metadata?.uid || request.metadata?.name}:${request.metadata?.generation}`;
    if (processed.has(key) || request.status?.phase === 'Succeeded') continue;
    const correlationId = requestId();
    const validation = validateRemediationRequest(request);
    const approvalEvidence = { operatorIdentity: request.spec.approvedBy, target: request.spec.target, action: request.spec.action };
    if (!validation.valid) {
      await api.patchRequestStatus(namespace, request.metadata.name, { phase: 'NeedsHuman', reason: validation.errors.join(' '), approvalEvidence });
      processed.add(key);
      continue;
    }
    try {
      await executeApprovedRequest(api, request, correlationId);
      await api.patchRequestStatus(namespace, request.metadata.name, { phase: 'Succeeded', correlationId, evidence: redactedEvidenceEvent({ event: 'remediation', request, outcome: 'passed', endpoint: 'kubernetes-api', correlationId }), approvalEvidence });
    } catch (error) {
      await api.patchRequestStatus(namespace, request.metadata.name, { phase: 'Failed', correlationId, reason: error.message.slice(0, 200), evidence: redactedEvidenceEvent({ event: 'remediation', request, outcome: 'failed', endpoint: 'kubernetes-api', correlationId }), approvalEvidence });
    }
    processed.add(key);
  }
}

const server = createServer(async (request, response) => {
  try {
    if (request.method === 'GET' && request.url === '/healthz') return json(response, 200, { status: 'ok', mode: 'kubernetes-api' });
    if (request.method === 'POST' && request.url === '/mcp') {
      const message = await body(request);
      if (message.id === undefined) {
        response.writeHead(202, { 'cache-control': 'no-store' });
        return response.end();
      }
      return json(response, 200, await mcpResponse(message));
    }
    if (request.method === 'POST' && request.url === '/v1/diagnose') {
      const correlationId = requestId();
      const result = diagnose(await body(request));
      return json(response, 200, { requestId: correlationId, ...result, evidence: redactedEvidenceEvent({ event: 'diagnosis', outcome: result.status === 'Proposed' ? 'pending' : 'needs_human', endpoint: 'controller', correlationId }) });
    }
    if (request.method === 'POST' && request.url === '/alertmanager') {
      const bounded = boundedAlert(await body(request));
      const correlationId = requestId();
      if (!bounded.accepted) return json(response, 202, { accepted: false, reason: bounded.reason, evidence: redactedEvidenceEvent({ event: 'diagnosis', outcome: 'needs_human', endpoint: 'alertmanager', correlationId }) });
      if (bounded.status === 'resolved') return json(response, 200, { accepted: true, status: 'resolved', evidence: redactedEvidenceEvent({ event: 'diagnosis', outcome: 'passed', endpoint: 'alertmanager', correlationId }) });
      if (diagnosisInFlight) return json(response, 429, { accepted: false, reason: 'one diagnosis is already in flight', evidence: redactedEvidenceEvent({ event: 'diagnosis', outcome: 'pending', endpoint: 'alertmanager', correlationId }) });
      if (!process.env.KAGENT_A2A_URL) return json(response, 503, { accepted: false, reason: 'KAGENT_A2A_URL is not configured', evidence: redactedEvidenceEvent({ event: 'diagnosis', outcome: 'needs_human', endpoint: 'alertmanager', correlationId }) });
      diagnosisInFlight = true;
      activeDiagnosisAlert = bounded.alert;
      void (async () => {
        const controller = new AbortController();
        const timeout = setTimeout(() => controller.abort(), 90_000);
        try {
          const prompt = `Diagnose firing alert ${bounded.alert}. First call diagnose_alert with alert=${bounded.runbookAlert}. If its status is Proposed, call propose_remediation exactly once with action=restartDeployment, target=ti-api, namespace=opencti-system, reason="bounded ${bounded.alert} runbook proposal". The proposal must remain approved:false and approvedBy:pending. Use at most 3 rounds, no raw logs or secrets, and never approve or execute a resource. If the runbook does not justify this action, return NeedsHuman without proposing.`;
          const result = await fetch(process.env.KAGENT_A2A_URL, { method: 'POST', headers: { 'content-type': 'application/json' }, signal: controller.signal, body: JSON.stringify({ jsonrpc: '2.0', id: correlationId, method: 'message/send', params: { message: { messageId: correlationId, role: 'user', parts: [{ kind: 'text', text: prompt }] } } }) });
          if (!result.ok) console.error(`kagent diagnosis failed: HTTP ${result.status}`);
        } catch (error) {
          console.error(error.name === 'AbortError' ? 'kagent diagnosis timed out' : 'kagent diagnosis unavailable');
        } finally {
          clearTimeout(timeout);
          activeDiagnosisAlert = '';
          diagnosisInFlight = false;
        }
      })();
      return json(response, 202, { accepted: true, status: 'diagnosis-dispatched', evidence: redactedEvidenceEvent({ event: 'diagnosis', outcome: 'pending', endpoint: 'alertmanager', correlationId }) });
    }
    return json(response, request.method === 'POST' ? 404 : 405, { error: 'remediation is accepted only as a Kubernetes RemediationRequest' });
  } catch (error) {
    return json(response, 400, { error: error.message === 'request body too large' ? error.message : 'invalid JSON request' });
  }
});

server.listen(port, '0.0.0.0', () => console.log(`remediation-controller listening on ${port}`));

if (process.env.CONTROLLER_DISABLE_WATCH !== 'true') {
  const tick = async () => {
    try { await processApprovedRequests(); } catch (error) { console.error(`controller reconciliation failed: ${error.message}`); }
    setTimeout(tick, Number(process.env.RECONCILE_INTERVAL_MS || 5000)).unref();
  };
  tick();
}

export { processApprovedRequests };
