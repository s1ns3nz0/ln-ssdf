import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { createServer } from 'node:net';
import test from 'node:test';

async function availablePort() {
  const probe = createServer();
  probe.listen(0, '127.0.0.1');
  await once(probe, 'listening');
  const { port } = probe.address();
  await new Promise((resolve, reject) => probe.close((error) => error ? reject(error) : resolve()));
  return port;
}

async function startFixture() {
  const port = await availablePort();
  const child = spawn(process.execPath, ['services/evidence-dashboard/server.mjs'], {
    cwd: process.cwd(),
    env: { ...process.env, PORT: String(port), BASE_PATH: '/supply', DASHBOARD_MODE: 'fixture' },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  const origin = `http://127.0.0.1:${port}`;
  for (let attempt = 0; attempt < 30; attempt += 1) {
    try {
      const response = await fetch(`${origin}/supply/api/health`);
      if (response.ok) return { child, origin };
    } catch {}
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  child.kill('SIGTERM');
  throw new Error('fixture dashboard did not start');
}

test('fixture dashboard honors the path prefix and enforces its read-only API contract', async (t) => {
  const { child, origin } = await startFixture();
  t.after(() => child.kill('SIGTERM'));

  const page = await fetch(`${origin}/supply/`);
  const pageText = await page.text();
  assert.match(pageText, /window\.__DASHBOARD_BASE_PATH__ = '\/supply'/);
  assert.match(pageText, /Source document JSON/);
  const appResponse = await fetch(`${origin}/supply/app.js`);
  const appText = await appResponse.text();
  assert.match(appText, /project: params\.get\('project'\) \|\| 'all'/);
  assert.match(appText, /All projects/);
  assert.match(appText, /Evidence freshness/);
  assert.doesNotMatch(appText, /No remediation required/);
  assert.match(appText, /first\.summary/);
  assert.doesNotMatch(appText, /<h4>OTel evidence|<dt>Trace ID|<dt>Metric|<dt>Log/);
  assert.doesNotMatch(appText, /demo-banner|recovery-drills/);

  const wrongPrefix = await fetch(`${origin}/supply-chain/api/health`);
  assert.equal(wrongPrefix.status, 404);

  const head = await fetch(`${origin}/supply/api/health`, { method: 'HEAD' });
  assert.equal(head.status, 200);
  assert.equal(await head.text(), '');

  const filtered = await fetch(`${origin}/supply/api/dashboard`);
  assert.equal(filtered.status, 200);
  const body = await filtered.json();
  assert.equal(body.dataMode, 'fixture');
  assert.equal(body.catalog.taskCount, 42);
  assert.equal(body.records.length, 84);
  assert.deepEqual(body.groups.map((group) => group.id), ['PO', 'PS', 'PW', 'RV']);
  assert.equal('recoveryDrills' in body, false);
  const detail = await fetch(`${origin}/supply/api/controls/PW.8.1`);
  assert.equal(detail.status, 200);
  const detailBody = await detail.json();
  assert.equal(detailBody.projects.length, 2);
  assert.equal(detailBody.projects.find((project) => project.projectId === 'lnd').currentPosture, 'Blocked');
  assert.match(detailBody.projects.find((project) => project.projectId === 'lnd').artifacts.assessment.objectKey, /^s3:\/\/ssdf-demo-evidence\//);

  const artifact = await fetch(`${origin}/supply/api/artifacts/assessment/lnd/PW.8.1.json`);
  assert.equal(artifact.status, 200);
  const artifactBody = await artifact.json();
  assert.equal(artifactBody.artifact.label, 'Assessment Results JSON');
  assert.equal(artifactBody.document['assessment-results'].results.length, 3);
  assert.equal(artifactBody.document['assessment-results'].results.at(-1).result, 'Failed');
  const plan = await fetch(`${origin}/supply/api/artifacts/plan/lnd/PW.8.1.json`);
  assert.equal(plan.status, 200);
  const planBody = await plan.json();
  assert.equal(artifactBody.document['assessment-results']['import-ap'].href, planBody.artifact.objectKey);
  const profile = await fetch(`${origin}/supply/api/artifacts/profile/lnd/PW.8.1.json`);
  assert.equal(profile.status, 200);

  const jira = await fetch(origin + '/supply/api/artifacts/jira/lnd/PW.8.1.json');
  assert.equal(jira.status, 200);
  const jiraBody = await jira.json();
  assert.match(jiraBody.artifact.objectKey, /^jira:\/\/ssdf-demo\/browse\/SSDF-/);
  assert.equal(jiraBody.document.issue.fields.status.name, 'In Progress');

  const missing = await fetch(`${origin}/supply/api/controls/ZZ.9.9`);
  assert.equal(missing.status, 404);

  const write = await fetch(`${origin}/supply/api/dashboard`, { method: 'POST' });
  assert.equal(write.status, 405);
});
