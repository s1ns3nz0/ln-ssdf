import { randomBytes } from 'node:crypto';

export const ACTIONS = Object.freeze({
  restartDeployment: Object.freeze({
    kind: 'Deployment',
    targets: Object.freeze(['aperture', 'ti-api', 'otel-collector', 'opencti-application']),
  }),
  rollbackHelmRelease: Object.freeze({
    kind: 'HelmRelease',
    targets: Object.freeze(['ti-api']),
  }),
});

export const RUNBOOK = Object.freeze({
  'ti-api-5xx': Object.freeze({
    diagnosis: 'Inspect the redacted TI API availability and failure-rate summary; do not read logs, Secrets, or payment material.',
    action: 'restartDeployment', target: 'ti-api',
    recovery: 'If the restart does not recover the SLO, request operator approval for the declared ti-api Helm rollback.',
  }),
});

export const ALERT_RUNBOOKS = Object.freeze({
  TiProductFailureRateHigh: 'ti-api-5xx',
  TiApiAvailabilityLow: 'ti-api-5xx',
  TiApiScrapeDown: 'ti-api-5xx',
});

const requestTypes = new Set(['restartDeployment', 'rollbackHelmRelease']);
const namespaces = new Set(['ssdf-system', 'opencti-system']);
const safeName = /^[a-z0-9]([-a-z0-9]*[a-z0-9])?$/;
const operatorIdentity = /^[A-Za-z0-9._:@/-]{1,253}$/;
export const TARGETS = Object.freeze({
  aperture: Object.freeze({ namespace: 'ssdf-system', resource: 'aperture' }),
  'ti-api': Object.freeze({ namespace: 'opencti-system', resource: 'ti-product-api' }),
  'otel-collector': Object.freeze({ namespace: 'ssdf-system', resource: 'otel-collector' }),
  'opencti-application': Object.freeze({ namespace: 'opencti-system', resource: 'opencti-application' }),
});

export function requestId() { return randomBytes(16).toString('hex'); }

export function validateRemediationRequest(request, { now = new Date() } = {}) {
  const errors = [];
  if (!request || typeof request !== 'object' || Array.isArray(request)) return { valid: false, errors: ['request must be an object.'] };
  if (request.apiVersion !== 'aiops.ln-ssdf.io/v1alpha1') errors.push('apiVersion must be aiops.ln-ssdf.io/v1alpha1.');
  if (request.kind !== 'RemediationRequest') errors.push('kind must be RemediationRequest.');
  if (!safeName.test(request.metadata?.name || '')) errors.push('metadata.name must be a DNS label.');
  const spec = request.spec;
  if (!requestTypes.has(spec?.action)) errors.push('spec.action is not allowed.');
  if (!namespaces.has(spec?.namespace)) errors.push('spec.namespace is not allowed.');
  const action = ACTIONS[spec?.action];
  if (action && !action.targets.includes(spec?.target)) errors.push('spec.target is not allowed for this action.');
  if (spec?.target && TARGETS[spec.target] && spec.namespace !== TARGETS[spec.target].namespace) errors.push('spec.namespace does not match the target namespace.');
  if (spec?.action === 'rollbackHelmRelease' && (!safeName.test(spec?.release || '') || spec.release !== spec.target)) errors.push('rollback release must equal the declared target.');
  if (spec?.action === 'restartDeployment' && spec?.release) errors.push('restartDeployment cannot include a Helm release.');
  if (spec?.reason && (typeof spec.reason !== 'string' || spec.reason.length > 500)) errors.push('spec.reason must be at most 500 characters.');
  if (spec?.approved !== true) errors.push('spec.approved must be true.');
  if (!operatorIdentity.test(spec?.approvedBy || '')) errors.push('spec.approvedBy must be a bounded operator identity.');
  const expires = Date.parse(spec?.approvalExpiresAt || '');
  if (!Number.isFinite(expires) || expires <= new Date(now).getTime()) errors.push('approvalExpiresAt must be in the future.');
  return { valid: errors.length === 0, errors };
}

export function validateRemediationProposal(request, options) {
  return validateRemediationRequest({ ...request, spec: { ...request.spec, approved: true } }, options);
}

export function diagnose({ alert, observations = [], rounds = 0 } = {}) {
  const runbook = RUNBOOK[alert];
  const boundedRounds = Math.min(Math.max(Number(rounds) || 0, 0), 3);
  if (!runbook) return { status: 'NeedsHuman', rounds: boundedRounds, reason: 'alert has no approved read-only runbook.' };
  if (boundedRounds >= 3) return { status: 'NeedsHuman', rounds: 3, reason: 'diagnosis round limit reached.' };
  const safeObservations = Array.isArray(observations) ? observations.slice(0, 10).map((item) => ({
    signal: String(item?.signal || 'unknown').slice(0, 80), value: String(item?.value || '').slice(0, 160),
  })) : [];
  return { status: 'Proposed', rounds: boundedRounds + 1, alert, runbook, observations: safeObservations };
}

export function boundedAlert(payload) {
  const alert = Array.isArray(payload?.alerts) ? payload.alerts[0] : null;
  const alertName = alert?.labels?.alertname;
  const runbookAlert = ALERT_RUNBOOKS[alertName];
  if (!runbookAlert) return { accepted: false, reason: 'alert is outside the Phase 12 runbook allowlist.' };
  return {
    accepted: true,
    alert: alertName,
    status: alert?.status === 'resolved' ? 'resolved' : 'firing',
    severity: ['warning', 'critical'].includes(alert?.labels?.severity) ? alert.labels.severity : 'unknown',
    runbookAlert,
  };
}

export function planExecution(request) {
  const result = validateRemediationRequest(request);
  if (!result.valid) return { accepted: false, errors: result.errors };
  const { action, target, namespace, release } = request.spec;
  return { accepted: true, operation: action === 'restartDeployment' ? 'rollout restart' : 'deployment revision rollback', target, namespace, release: release || null };
}

// This is the cross-phase evidence contract. It intentionally contains no
// request body, token, Secret, log line, payment credential, or raw alert.
export function redactedEvidenceEvent({ event, request, outcome, endpoint, correlationId }) {
  return {
    event, subject: request?.spec?.target || 'aiops', outcome, endpoint,
    amount_sat: 0, correlation_id: correlationId,
  };
}
