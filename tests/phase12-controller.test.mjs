import assert from 'node:assert/strict';
import test from 'node:test';

import {
  boundedAlert, diagnose, planExecution, redactedEvidenceEvent, validateRemediationRequest,
} from '../services/remediation-controller/lib.mjs';
import { executeApprovedRequest } from '../services/remediation-controller/kube.mjs';
import { readFile } from 'node:fs/promises';

function request(overrides = {}) {
  const base = {
    apiVersion: 'aiops.ln-ssdf.io/v1alpha1', kind: 'RemediationRequest',
    metadata: { name: 'ti-api-recovery' },
    spec: {
      action: 'restartDeployment', target: 'ti-api', namespace: 'opencti-system',
      reason: 'TI API SLO alert', approved: true, approvedBy: 'operator-alice',
      approvalExpiresAt: '2099-01-01T00:00:00Z',
    },
  };
  const result = { ...base, ...overrides, spec: { ...base.spec, ...overrides.spec } };
  return result;
}

test('accepts only a typed, approved, unexpired restart request and returns a dry-run plan', () => {
  const result = request();
  assert.deepEqual(validateRemediationRequest(result), { valid: true, errors: [] });
  assert.deepEqual(planExecution(result), {
    accepted: true, operation: 'rollout restart', target: 'ti-api', namespace: 'opencti-system', release: null,
  });
});

test('rejects missing approval, arbitrary actions, protected targets, and stale digest', () => {
  for (const spec of [
    { approved: false }, { action: 'execShell' }, { target: 'lnd-primary' },
  ]) {
    assert.equal(validateRemediationRequest(request({ spec })).valid, false);
  }
  assert.equal(validateRemediationRequest(request({ spec: { approvalExpiresAt: '2020-01-01T00:00:00Z' } })).valid, false);
});

test('rollback is limited to the declared ti-api Helm release', () => {
  const result = request({ spec: { action: 'rollbackHelmRelease', namespace: 'opencti-system', release: 'ti-api' } });
  assert.equal(validateRemediationRequest(result).valid, true);
  assert.equal(planExecution(result).operation, 'deployment revision rollback');
  assert.equal(validateRemediationRequest(request({ spec: { action: 'rollbackHelmRelease', target: 'aperture', release: 'aperture' } })).valid, false);
});

test('aperture is bound to ssdf-system in the controller allowlist', async () => {
  const aperture = request({ spec: { target: 'aperture', namespace: 'ssdf-system' } });
  assert.equal(validateRemediationRequest(aperture).valid, true);
  assert.equal(planExecution(aperture).namespace, 'ssdf-system');
  assert.equal(validateRemediationRequest(request({ spec: { target: 'aperture', namespace: 'opencti-system' } })).valid, false);
  const crd = await readFile(new URL('../manifests/phase12/remediation-request-crd.yaml', import.meta.url), 'utf8');
  const rbac = await readFile(new URL('../manifests/phase12/remediation-controller.yaml', import.meta.url), 'utf8');
  assert.match(crd, /self\.target in \['aperture', 'otel-collector'\] \? self\.namespace == 'ssdf-system'/);
  assert.match(rbac, /name: remediation-controller-aperture[\s\S]*?namespace: ssdf-system[\s\S]*?resourceNames: \[aperture\]/);
  assert.match(rbac, /runAsNonRoot: true, runAsUser: 1000, runAsGroup: 1000/);
});

test('diagnosis is read-only, runbook-bound, and capped at three rounds', () => {
  assert.equal(diagnose({ alert: 'ti-api-5xx', rounds: 0 }).status, 'Proposed');
  assert.equal(diagnose({ alert: 'unknown-alert' }).status, 'NeedsHuman');
  assert.equal(diagnose({ alert: 'ti-api-5xx', rounds: 3 }).reason, 'diagnosis round limit reached.');
});

test('alert intake is allowlisted and discards raw alert content', () => {
  assert.deepEqual(boundedAlert({ alerts: [{ labels: { alertname: 'TiProductFailureRateHigh', severity: 'warning', pod: 'secret-looking' }, annotations: { description: 'raw log body' } }] }), {
    accepted: true, alert: 'TiProductFailureRateHigh', status: 'firing', severity: 'warning', runbookAlert: 'ti-api-5xx',
  });
  assert.equal(boundedAlert({ alerts: [{ labels: { alertname: 'TiApiAvailabilityLow', severity: 'critical' } }] }).accepted, true);
  assert.equal(boundedAlert({ alerts: [{ labels: { alertname: 'TiApiScrapeDown', severity: 'critical' } }] }).accepted, true);
  assert.equal(boundedAlert({ alerts: [{ labels: { alertname: 'NodeFilesystemFull' } }] }).accepted, false);
});

test('emits the shared redacted event and carries operator identity plus target/action only', () => {
  const event = redactedEvidenceEvent({ event: 'remediation', request: request(), outcome: 'passed', endpoint: 'kubernetes-api', correlationId: 'c'.repeat(32) });
  assert.deepEqual(event, {
    event: 'remediation', subject: 'ti-api', outcome: 'passed', endpoint: 'kubernetes-api',
    amount_sat: 0, correlation_id: 'c'.repeat(32),
  });
  assert.equal(JSON.stringify(event).includes('approvalExpiresAt'), false);
});

test('execution is delegated to the Kubernetes API allowlist and never accepts an HTTP remediation body', async () => {
  const calls = [];
  const fakeApi = {
    restartDeployment: async (...args) => calls.push(['restart', ...args]),
    rollbackDeploymentRevision: async (...args) => calls.push(['rollback', ...args]),
  };
  await executeApprovedRequest(fakeApi, request(), 'a'.repeat(32));
  await executeApprovedRequest(fakeApi, request({ spec: { action: 'rollbackHelmRelease', namespace: 'opencti-system', release: 'ti-api' } }), 'b'.repeat(32));
  assert.deepEqual(calls, [['restart', 'ti-api', 'a'.repeat(32)], ['rollback', 'ti-api', 'b'.repeat(32)]]);
  const serverSource = await readFile(new URL('../services/remediation-controller/server.mjs', import.meta.url), 'utf8');
  assert.equal(serverSource.includes("request.url === '/v1/remediate'"), false);
  assert.equal(serverSource.includes('listRequests'), true);
  assert.match(serverSource, /activeDiagnosisAlert/);
  assert.match(serverSource, /alertContext/);
});

test('kagent and Chaos Mesh definitions keep diagnosis bounded and target only TI API', async () => {
  const kagent = await readFile(new URL('../manifests/phase12/kagent-aiops.yaml', import.meta.url), 'utf8');
  const chaos = await readFile(new URL('../manifests/phase12/chaos-experiments.yaml', import.meta.url), 'utf8');
  const bootstrap = await readFile(new URL('../scripts/phase12-kagent-bootstrap.sh', import.meta.url), 'utf8');
  assert.match(kagent, /model: gpt-oss:20b/);
  assert.doesNotMatch(kagent, /requireApproval: \[propose_remediation\]/);
  assert.match(kagent, /At most three tool\/reasoning rounds/);
  assert.match(kagent, /apiKeySecret: phase12-gateway-placeholder/);
  assert.doesNotMatch(kagent, /OPENROUTER_API_KEY/);
  assert.doesNotMatch(bootstrap, /phase10-openrouter/);
  assert.match(bootstrap, /kagent-crds/);
  assert.match(bootstrap, /providers\.default=openAI/);
  assert.match(bootstrap, /providers\.openAI\.apiKeySecretRef=/);
  assert.match(bootstrap, /phase10-agentgateway\.phase10-system\.svc\.cluster\.local:3000\/v1/);
  assert.match(bootstrap, /providers\.openAI\.config\.baseUrl/);
  assert.doesNotMatch(bootstrap, /providers\.openAI\.config\.openAI\.baseUrl/);
  assert.doesNotMatch(bootstrap, /providers=null/);
  assert.match(bootstrap, /agents\.k8s-agent\.enabled=false/);
  assert.match(bootstrap, /--from-literal=OPENAI_API_KEY=phase12-gateway-managed-placeholder/);
  assert.doesNotMatch(bootstrap, /OPENROUTER_API_KEY|from-file/);
  assert.match(kagent, /TiProductFailureRateHigh.*TiApiAvailabilityLow.*TiApiScrapeDown/);
  assert.doesNotMatch(kagent, /TiApiLatencyHigh|OpenCtiUpstreamFailures/);
  assert.match(kagent, /apiVersion: kagent\.dev\/v1alpha2/);
  assert.match(kagent, /kind: ModelConfig[\s\S]*?openAI:\n    baseUrl:/);
  assert.match(kagent, /kind: RemoteMCPServer[\s\S]*?protocol: STREAMABLE_HTTP/);
  assert.match(kagent, /kind: Agent[\s\S]*?type: Declarative[\s\S]*?modelConfig: phase12-agentgateway-ollama/);
  assert.match(kagent, /declarative:[\s\S]*?a2aConfig:[\s\S]*?skills:/);
  assert.equal((chaos.match(/namespace: chaos-testing/g) || []).length, 2);
  assert.equal((chaos.match(/app: ti-product-api/g) || []).length, 2);
  assert.doesNotMatch(chaos, /lnd|bitcoind|vault|postgres/i);
  const chaosScript = await readFile(new URL('../scripts/phase12-chaos-drill.sh', import.meta.url), 'utf8');
  const chaosInstall = await readFile(new URL('../scripts/phase12-chaos-install.sh', import.meta.url), 'utf8');
  const alertBootstrap = await readFile(new URL('../scripts/phase12-alertmanager-bootstrap.sh', import.meta.url), 'utf8');
  const acceptance = await readFile(new URL('../scripts/phase12-kind-acceptance.sh', import.meta.url), 'utf8');
  const aiopsAcceptance = await readFile(new URL('../scripts/phase12-aiops-acceptance.sh', import.meta.url), 'utf8');
  const dockerfile = await readFile(new URL('../services/remediation-controller/Dockerfile', import.meta.url), 'utf8');
  assert.match(chaosScript, /manifest="chaos-pod-failure\.yaml"/);
  assert.match(chaosScript, /manifest="chaos-latency\.yaml"/);
  assert.match(chaosScript, /phase12-chaos-install\.sh/);
  assert.match(chaosScript, /wait_condition AllInjected 60/);
  assert.match(chaosScript, /wait_condition AllRecovered 60/);
  assert.match(chaosScript, /\.status\.conditions\[\]\?/);
  assert.match(chaosInstall, /--version 2\.7\.2/);
  assert.match(chaosInstall, /chaosDaemon\.runtime=containerd/);
  assert.match(chaosInstall, /chaosDaemon\.socketPath=\/run\/containerd\/containerd\.sock/);
  assert.match(chaosInstall, /chaos-controller-manager/);
  assert.match(alertBootstrap, /in-cluster Git server/);
  assert.match(alertBootstrap, /TiProductFailureRateHigh\|TiApiAvailabilityLow\|TiApiScrapeDown/);
  assert.match(alertBootstrap, /alert: TiApiScrapeDown/);
  assert.match(alertBootstrap, /group_interval: 5s/);
  assert.match(alertBootstrap, /repeat_interval: 30s/);
  assert.match(alertBootstrap, /alertmanager-config: \\"v2\\"/);
  assert.match(alertBootstrap, /phase12\.ln-ssdf\.io\/prometheus-rules/);
  assert.match(alertBootstrap, /prometheus-rules: \\"v2\\"/);
  assert.match(alertBootstrap, /rollout status deployment\/prometheus/);
  assert.doesNotMatch(alertBootstrap, /TiApiLatencyHigh|OpenCtiUpstreamFailures/);
  assert.doesNotMatch(alertBootstrap, /create configmap|rollout restart/);
  assert.match(acceptance, /get service kubernetes -o jsonpath/);
  assert.match(acceptance, /get endpoints kubernetes -o json/);
  assert.match(acceptance, /\.subsets\[\]\? as \$subset/);
  assert.match(acceptance, /\$subset\.addresses/);
  assert.match(acceptance, /\$subset\.ports/);
  assert.match(acceptance, /endpoint_port/);
  assert.match(acceptance, /api_service_ip\/32/);
  assert.match(acceptance, /ipBlock/);
  assert.match(dockerfile, /ARG BASE_IMAGE=/);
  assert.match(aiopsAcceptance, /api\/v1\/alerts/);
  assert.match(aiopsAcceptance, /api\/v2\/alerts/);
  assert.match(aiopsAcceptance, /port-forward --address 127\.0\.0\.1 service\/prometheus/);
  assert.match(aiopsAcceptance, /port-forward --address 127\.0\.0\.1 service\/alertmanager/);
  assert.match(aiopsAcceptance, /report_readiness_failure/);
  assert.match(aiopsAcceptance, /kill -0 "\$chaos_pid"/);
  assert.match(aiopsAcceptance, /chaos\.log/);
  assert.match(aiopsAcceptance, /approved == false/);
  assert.match(aiopsAcceptance, /before_names/);
  assert.match(aiopsAcceptance, /--argjson before/);
  assert.doesNotMatch(aiopsAcceptance, /split\("\\\\n"\)/);
  assert.match(aiopsAcceptance, /contains\("TiApiScrapeDown"\)/);
  assert.match(aiopsAcceptance, /--confirm-local-approval/);
  assert.match(aiopsAcceptance, /approval_enabled=false/);
  assert.match(aiopsAcceptance, /phase12-aiops-operator/);
  assert.match(aiopsAcceptance, /create token phase12-aiops-operator/);
  assert.match(aiopsAcceptance, /status\.phase/);
  assert.match(aiopsAcceptance, /approvalEvidence/);
  assert.match(aiopsAcceptance, /last-remediation/);
  assert.match(aiopsAcceptance, /status\.evidence/);
});

test('real AIOps acceptance excludes a preexisting pending proposal', () => {
  const before = { items: [{ metadata: { name: 'existing-pending' }, spec: { approved: false, approvedBy: 'pending', target: 'ti-api', reason: 'alert=TiApiScrapeDown; old run' } }] };
  const after = { items: [...before.items, { metadata: { name: 'new-pending' }, spec: { approved: false, approvedBy: 'pending', target: 'ti-api', reason: 'alert=TiApiScrapeDown; new run' } }] };
  const beforeNames = new Set(before.items.map((item) => item.metadata.name));
  const candidates = after.items.filter((item) => !beforeNames.has(item.metadata.name)
    && item.spec.approved === false && item.spec.approvedBy === 'pending'
    && item.spec.target === 'ti-api' && item.spec.reason.includes('TiApiScrapeDown'));
  assert.deepEqual(candidates.map((item) => item.metadata.name), ['new-pending']);
});
