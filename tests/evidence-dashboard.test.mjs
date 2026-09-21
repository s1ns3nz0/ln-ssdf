import assert from 'node:assert/strict';
import test from 'node:test';
import { readFileSync } from 'node:fs';
import { evidenceRow, normalizeBasePath, publicClaims, signalFor } from '../services/evidence-dashboard/lib.mjs';
import { artifactFor, buildDashboard, detailFor, publicDashboard } from '../services/evidence-dashboard/model.mjs';

test('dashboard normalizes a path-prefix reverse proxy base path', () => {
  assert.equal(normalizeBasePath(' /lnd/ '), '/lnd');
  assert.equal(normalizeBasePath('/'), '');
  assert.throws(() => normalizeBasePath('/lnd/../unsafe'), /unsupported characters/);
});

test('dashboard signal distinguishes diagnostic findings from blocked and stale data', () => {
  assert.equal(signalFor({ rawStatus: 'not_satisfied', required: true }), 'Blocked');
  assert.equal(signalFor({ rawStatus: 'satisfied', observedFindings: 1 }), 'Attention');
  assert.equal(signalFor({ rawStatus: 'satisfied', expiresAt: '2020-01-01T00:00:00Z' }), 'Unknown');
});

test('dashboard returns only a claim allowlist', () => {
  assert.deepEqual(publicClaims('vsa', { result: 'PASSED', verificationMode: 'diagnostic', token: 'never-public' }), { result: 'PASSED', verificationMode: 'diagnostic' });
  const row = evidenceRow({ evidence_id:'id', kind:'scorecard', track:'third_party', subject_kind:'run', subject_ref:'subject', issuer:'issuer', source_uri:'uri', observed_at:'2026-01-01T00:00:00Z', evaluated_at:'2026-01-01T00:00:00Z', expires_at:null, policy_version:'v1', claim:{lndScore:5.8, secret:'nope'} });
  assert.deepEqual(row.claims, { lndScore: 5.8 });
});

test('public fixture contains no real source URLs or credential-shaped keys', () => {
  const fixture = readFileSync('services/evidence-dashboard/fixtures/dashboard.json', 'utf8');
  assert.doesNotMatch(fixture, /https?:\/\//i);
  assert.doesNotMatch(fixture, /(?:password|token|secret|private[_-]?key)/i);
});

test('generated mock records keep posture, telemetry, and remediation evidence consistent', () => {
  const catalog = JSON.parse(readFileSync('services/evidence-dashboard/fixtures/nist-sp800-218-v1.catalog.json', 'utf8'));
  const dashboard = buildDashboard(catalog);
  const jiraKeys = dashboard.records.flatMap((record) => record.poam ? [record.poam.ticket.key] : []);
  assert.equal(new Set(jiraKeys).size, jiraKeys.length);
  assert.equal(dashboard.records.length, dashboard.projects.length * dashboard.catalog.taskCount);
  const projection = publicDashboard(dashboard);
  assert.equal(projection.records.length, dashboard.records.length);
  for (const record of dashboard.records) {
    const label = `${record.projectId}/${record.id}`;
    const reviewerText = [record.telemetryReason, ...record.blockers.flatMap((blocker) => [blocker.type, blocker.detail]), record.otel?.log.message || ''].join(' ');
    assert.doesNotMatch(reviewerText, /\b(?:telemetry|otel|trace|metric|logs?|collector|instrumented|SSP)\b/i, label);
    const detail = detailFor(dashboard, record.id);
    assert.equal(detail.task.statement, record.statement, label);
    assert.ok(detail.task.summary.length <= 110, label);
    assert.ok(detail.task.summary.length > 10, label);
    assert.equal(detail.projects.find((item) => item.projectId === record.projectId).currentPosture, record.currentPosture, label);
    assert.equal(record.assessments.at(-1).observedAt, dashboard.scenarioTime, label);
    const expectedAssessment = { Blocked: 'Failed', Partial: 'Partial', 'Not Implemented': 'Not Assessed', 'Not Applicable': 'Not Applicable', Implemented: 'Passed' }[record.currentPosture];
    assert.equal(record.assessments.at(-1).result, expectedAssessment, label);
    for (const kind of ['profile', 'ssp', 'plan', 'assessment']) assert.ok(artifactFor(dashboard, kind, record.projectId, record.id)?.document, `${label}/${kind}`);
    const profile = artifactFor(dashboard, 'profile', record.projectId, record.id);
    const ssp = artifactFor(dashboard, 'ssp', record.projectId, record.id);
    const plan = artifactFor(dashboard, 'plan', record.projectId, record.id);
    const assessment = artifactFor(dashboard, 'assessment', record.projectId, record.id);
    assert.equal(ssp.document['system-security-plan']['import-profile'].href, profile.artifact.objectKey, label);
    assert.equal(plan.document['assessment-plan']['import-ssp'].href, ssp.artifact.objectKey, label);
    assert.equal(assessment.document['assessment-results']['import-ap'].href, plan.artifact.objectKey, label);
    const latestResult = assessment.document['assessment-results'].results.at(-1);
    const finding = latestResult.findings[0];
    assert.equal(finding.target['target-id'], record.id, label);
    assert.equal(finding['related-observations'][0]['observation-uuid'], latestResult.observations[0].uuid, label);
    assert.equal(assessment.document['assessment-results'].metadata['last-modified'], dashboard.scenarioTime, label);
    if (['Not Applicable', 'No Signal'].includes(record.telemetryStatus)) assert.equal(record.otel, null, `${record.projectId}/${record.id}`);
    assert.equal(Boolean(artifactFor(dashboard, 'otel', record.projectId, record.id)), Boolean(record.otel), `${label}/otel`);
    if (record.currentPosture === 'Not Implemented') assert.equal(record.telemetryStatus, 'No Signal');
    if (record.currentPosture === 'Blocked') assert.ok(record.poam, `${record.projectId}/${record.id}`);
    assert.equal(Boolean(artifactFor(dashboard, 'poam', record.projectId, record.id)), Boolean(record.poam), `${label}/poam`);
    assert.equal(Boolean(artifactFor(dashboard, 'jira', record.projectId, record.id)), Boolean(record.poam), `${label}/jira`);
    if (record.poam) {
      const poam = artifactFor(dashboard, 'poam', record.projectId, record.id);
      const jira = artifactFor(dashboard, 'jira', record.projectId, record.id);
      assert.equal(poam.document['plan-of-action-and-milestones']['import-ssp'].href, ssp.artifact.objectKey, label);
      assert.equal(poam.document['plan-of-action-and-milestones']['poam-items'][0]['related-findings'][0]['finding-uuid'], finding.uuid, label);
      assert.equal(jira.document.issue.links.poamId, record.poam.id, label);
      assert.equal(jira.document.issue.links.findingId, finding.uuid, label);
      assert.equal(jira.document.issue.links.assessmentObjectKey, assessment.artifact.objectKey, label);
      assert.equal(jira.document.issue.links.poamObjectKey, poam.artifact.objectKey, label);
      assert.equal(jira.document.issue.fields.assignee.displayName, record.poam.owner, label);
      assert.equal(jira.document.issue.fields.updated, dashboard.scenarioTime, label);
      assert.ok(Date.parse(jira.document.issue.fields.created) <= Date.parse(jira.document.issue.fields.updated), label);
    }
  }
});
