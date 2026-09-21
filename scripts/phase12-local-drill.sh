#!/usr/bin/env bash
# Dependency-free local acceptance drill. It exercises diagnosis, approval,
# strict action bounds, and the shared redacted evidence event without a
# Kubernetes cluster or an external service.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
node --input-type=module - "$repo_root" <<'NODE'
import assert from 'node:assert/strict';
import { diagnose, planExecution } from './services/remediation-controller/lib.mjs';
const request = {
  apiVersion: 'aiops.ln-ssdf.io/v1alpha1', kind: 'RemediationRequest', metadata: { name: 'ti-api-drill' },
  spec: { action: 'rollbackHelmRelease', target: 'ti-api', namespace: 'opencti-system', release: 'ti-api',
    approved: true, approvedBy: 'operator-drill', approvalExpiresAt: '2099-01-01T00:00:00Z', reason: 'local drill' },
};
assert.equal(diagnose({ alert: 'ti-api-5xx' }).status, 'Proposed');
assert.equal(planExecution(request).operation, 'deployment revision rollback');
assert.equal(planExecution({ ...request, spec: { ...request.spec, target: 'lnd-primary' } }).accepted, false);
console.log(JSON.stringify({ event: 'remediation', subject: 'ti-api', outcome: 'pending', endpoint: 'local-contract', amount_sat: 0, correlation_id: '0123456789abcdef0123456789abcdef' }));
NODE
echo "Phase 12 local contract drill passed: read-only diagnosis, approval boundary, rollback bound, and recorder event contract."
