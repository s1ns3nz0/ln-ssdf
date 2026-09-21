import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const chart = readFileSync('charts/observability/templates/stack.yaml', 'utf8');
const script = readFileSync('scripts/phase11-bootstrap.sh', 'utf8');
const service = readFileSync('services/operator-context/server.mjs', 'utf8');
test('Phase 11 mounts live rules, retains metrics, and sends alerts locally', () => {
  assert.match(chart, /storage\.tsdb\.retention\.time=7d/);
  assert.match(chart, /phase11-prometheus-rules/);
  assert.match(chart, /job_name: ti-product-api/);
  assert.match(chart, /ti_product_authorized_accesses_total/);
  assert.match(chart, /operator-context:8080\/alertmanager/);
});
test('Phase 11 bootstrap is replayable and proves redaction', () => {
  assert.match(script, /phase3-bootstrap\.sh/);
  assert.match(script, /BASE_IMAGE=phase10-l402-adapter:local/);
  assert.match(script, /git-daemon-export-ok/);
  assert.match(script, /ti-api-metrics-ingress\.yaml/);
  assert.match(script, /up\{job="ti-product-api"\}/);
  assert.match(script, /! rg -q 'phase11-secret'/);
});
test('operator context exposes a bounded MCP surface only', () => {
  assert.match(service, /operator_context/);
  assert.match(service, /allowed/);
  assert.doesNotMatch(service, /loki|tempo|\/api\/v1\/secrets/);
});
