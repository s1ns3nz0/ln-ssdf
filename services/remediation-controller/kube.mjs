import { readFile } from 'node:fs/promises';
import { TARGETS } from './lib.mjs';

const serviceAccountToken = '/var/run/secrets/kubernetes.io/serviceaccount/token';

export class KubernetesApi {
  constructor({ fetchImpl = fetch, baseUrl = process.env.KUBERNETES_API_URL || 'https://kubernetes.default.svc' } = {}) {
    this.fetch = fetchImpl;
    this.baseUrl = baseUrl.replace(/\/$/, '');
    this.token = null;
  }

  async authHeaders() {
    if (!this.token) this.token = await readFile(process.env.KUBERNETES_TOKEN_FILE || serviceAccountToken, 'utf8');
    return { authorization: `Bearer ${this.token.trim()}`, accept: 'application/json' };
  }

  async request(path, { method = 'GET', body, contentType = 'application/json' } = {}) {
    const headers = await this.authHeaders();
    if (body !== undefined) headers['content-type'] = contentType;
    const response = await this.fetch(`${this.baseUrl}${path}`, { method, headers, body: body === undefined ? undefined : JSON.stringify(body) });
    const text = await response.text();
    let payload;
    try { payload = text ? JSON.parse(text) : {}; } catch { payload = { raw: text.slice(0, 200) }; }
    if (!response.ok) throw new Error(`Kubernetes API ${method} ${path} returned ${response.status}`);
    return payload;
  }

  listRequests(namespace = 'ssdf-system') { return this.request(`/apis/aiops.ln-ssdf.io/v1alpha1/namespaces/${namespace}/remediationrequests`); }

  createRequest(namespace, request) {
    return this.request(`/apis/aiops.ln-ssdf.io/v1alpha1/namespaces/${namespace}/remediationrequests`, { method: 'POST', body: request });
  }

  patchRequestStatus(namespace, name, status) {
    return this.request(`/apis/aiops.ln-ssdf.io/v1alpha1/namespaces/${namespace}/remediationrequests/${name}/status`, { method: 'PATCH', body: { status }, contentType: 'application/merge-patch+json' });
  }

  restartDeployment(target, correlationId) {
    const definition = TARGETS[target];
    return this.request(`/apis/apps/v1/namespaces/${definition.namespace}/deployments/${definition.resource}`, {
      method: 'PATCH', body: { spec: { template: { metadata: { annotations: { 'ln-ssdf.io/last-remediation': correlationId } } } } }, contentType: 'application/merge-patch+json',
    });
  }

  async rollbackDeploymentRevision(target, correlationId) {
    const definition = TARGETS[target];
    const deploymentPath = `/apis/apps/v1/namespaces/${definition.namespace}/deployments/${definition.resource}`;
    const deployment = await this.request(deploymentPath);
    const revision = Number(deployment.metadata?.annotations?.['deployment.kubernetes.io/revision']);
    if (!Number.isInteger(revision) || revision < 2) throw new Error('no previous Deployment revision is available');
    const selector = Object.entries(deployment.spec?.selector?.matchLabels || {}).map(([key, value]) => `${encodeURIComponent(key)}=${encodeURIComponent(value)}`).join(',');
    const replicasets = await this.request(`/apis/apps/v1/namespaces/${definition.namespace}/replicasets?labelSelector=${selector}`);
    const previous = (replicasets.items || []).find((item) => Number(item.metadata?.annotations?.['deployment.kubernetes.io/revision']) === revision - 1);
    if (!previous?.spec?.template) throw new Error('previous Deployment template is unavailable');
    const template = structuredClone(previous.spec.template);
    template.metadata = { ...(template.metadata || {}), annotations: { ...(template.metadata?.annotations || {}), 'ln-ssdf.io/last-remediation': correlationId } };
    return this.request(deploymentPath, { method: 'PATCH', body: { spec: { template } }, contentType: 'application/merge-patch+json' });
  }
}

export async function executeApprovedRequest(api, request, correlationId) {
  if (request.spec.action === 'restartDeployment') return api.restartDeployment(request.spec.target, correlationId);
  if (request.spec.action === 'rollbackHelmRelease') return api.rollbackDeploymentRevision(request.spec.target, correlationId);
  throw new Error('unsupported remediation action');
}
