import { createHash } from 'node:crypto';

export const scenarioTime = '2026-09-21T12:00:00.000Z';
export const catalogSource = {
  title: 'NIST SP 800-218 SSDF OSCAL Catalog',
  release: 'oscal-content v1.5.0',
  commit: '78650f02ad9321bb7b817846f8fbd4f2bcd620de',
  sha256: '5ec118109d7fca45785ed6cdad23e46bfc6dfb91cc23fd7140b702582f9da766',
  url: 'https://github.com/usnistgov/oscal-content/blob/78650f02ad9321bb7b817846f8fbd4f2bcd620de/nist.gov/SP800-218/ver1/json/NIST_SP800-218_ver1_catalog-min.json',
};

export const implementationOrder = ['Blocked', 'Not Implemented', 'Partial', 'Implemented', 'Not Applicable'];
export const telemetryOrder = ['No Signal', 'Stale', 'Degraded', 'Healthy', 'Not Applicable'];

const projects = [
  { id: 'lnd', name: 'lnd', description: 'Lightning node application', maturity: 'Mature core service' },
  { id: 'aperture', name: 'aperture', description: 'Lightning service and API component', maturity: 'Expanding service' },
];

const components = [
  'Source repository',
  'CI pipeline',
  'Artifact registry / SBOM',
  'Kubernetes deployment',
  'Runtime service',
];

const organizationPolicies = [
  ['ORG-POL-01', 'Secure Development Policy'],
  ['ORG-POL-02', 'Source and Access Management Policy'],
  ['ORG-POL-03', 'Build and Release Integrity Policy'],
  ['ORG-POL-04', 'Vulnerability Response Policy'],
  ['ORG-POL-05', 'Observability and Incident Response Policy'],
].map(([id, title]) => ({ id, title, status: 'Satisfied', artifactType: 'Demo artifact' }));

const documentTasks = new Set(['PO.1.1', 'PO.1.2', 'PO.1.3', 'PO.2.1', 'PO.2.2', 'PO.2.3', 'PO.4.1', 'PO.4.2']);
const lndBlocked = new Map([
  ['PW.8.1', ['Failed assessment', 'Executable vulnerability test found an unresolved critical finding.']],
  ['PW.8.2', ['Evidence stale or absent', 'Required release-verification evidence is older than the scenario freshness window.']],
  ['RV.1.1', ['Evidence threshold breached', 'Vulnerability-identification latency exceeded the organization policy threshold.']],
  ['RV.2.1', ['Policy violation', 'A critical remediation ticket exceeded its policy target date.']],
]);
const apertureBlocked = new Map([
  ['PS.2.1', ['Evidence link missing', 'The release-integrity attestation is not linked to the current artifact.']],
  ['PW.6.1', ['Failed assessment', 'Build-hardening assessment failed for the current compiler configuration.']],
  ['PW.8.1', ['Evidence threshold breached', 'Runtime security-test error rate exceeded its configured threshold.']],
  ['RV.1.1', ['Evidence stale or absent', 'No recent vulnerability observation is available for this component.']],
  ['RV.2.1', ['Policy violation', 'A high-severity finding was accepted without a valid remediation milestone.']],
  ['RV.3.1', ['Missing implementation', 'Root-cause analysis workflow has not been implemented for this service.']],
]);

function descendants(controls, accumulator = []) {
  for (const control of controls || []) {
    if (control.class === 'task') accumulator.push(control);
    descendants(control.controls, accumulator);
  }
  return accumulator;
}

function statement(control) {
  return control.parts?.find((part) => part.name === 'statement')?.prose || 'No statement supplied by source catalog.';
}

function shortSummary(value) {
  const normalized = value.replace(/\s+/g, ' ').trim();
  if (normalized.length <= 110) return normalized;
  return normalized.slice(0, 107).replace(/\s+\S*$/, '') + '…';
}

function fixtureUuid(value) {
  const hex = createHash('sha256').update(`ln-ssdf-fixture:${value}`).digest('hex');
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-4${hex.slice(13, 16)}-a${hex.slice(17, 20)}-${hex.slice(20, 32)}`;
}

function pickStatus(projectId, taskId, index) {
  const blocked = projectId === 'lnd' ? lndBlocked : apertureBlocked;
  if (blocked.has(taskId)) return 'Blocked';
  if (taskId === 'PO.5.2') return 'Not Applicable';
  const notImplemented = projectId === 'lnd'
    ? new Set(['PW.4.2', 'RV.3.3'])
    : new Set(['PO.5.1', 'PS.3.2', 'PW.4.2', 'PW.7.2', 'PW.9.2', 'RV.3.3']);
  if (notImplemented.has(taskId)) return 'Not Implemented';
  const partial = projectId === 'lnd'
    ? new Set(['PO.3.2', 'PS.3.1', 'PW.1.3', 'PW.7.2', 'PW.9.1', 'RV.3.2'])
    : new Set(['PO.3.1', 'PO.3.2', 'PS.1.1', 'PS.3.1', 'PW.1.2', 'PW.1.3', 'PW.4.1', 'PW.5.1', 'PW.7.1', 'PW.9.1']);
  if (partial.has(taskId)) return 'Partial';
  return index % 17 === 0 && projectId === 'aperture' ? 'Partial' : 'Implemented';
}

function telemetryFor(task, projectId, posture, index) {
  if (posture === 'Not Applicable') return { status: 'Not Applicable', reason: 'This task is outside the declared project scope in the synthetic scenario.' };
  if (documentTasks.has(task.id)) return { status: 'Not Applicable', reason: 'Policy and implementation records provide the evidence for this task; runtime evidence is not needed.' };
  if (posture === 'Blocked') {
    const reason = (projectId === 'lnd' ? lndBlocked : apertureBlocked).get(task.id)?.[0];
    if (reason === 'Evidence stale or absent') return { status: 'Stale', reason: 'Required evidence is outside the scenario freshness window.' };
    if (reason === 'Evidence threshold breached') return { status: 'Degraded', reason: 'Observed activity exceeded its configured threshold.' };
    if (reason === 'Missing implementation') return { status: 'No Signal', reason: 'The required workflow does not exist.' };
  }
  if (posture === 'Partial') return { status: index % 2 ? 'Degraded' : 'Healthy', reason: 'Evidence is present but the implementation scope is incomplete.' };
  if (posture === 'Not Implemented') return { status: 'No Signal', reason: 'No runtime evidence is expected until the implementation exists.' };
  return { status: 'Healthy', reason: 'Recent evidence meets the scenario threshold.' };
}

function declaredStatus(posture, taskId, projectId) {
  if (posture === 'Blocked' && (projectId === 'lnd' ? lndBlocked : apertureBlocked).get(taskId)?.[0] === 'Missing implementation') return 'Not Implemented';
  if (posture === 'Blocked') return 'Implemented';
  return posture;
}

function assessmentFor(task, project, posture, index) {
  const current = posture === 'Blocked' ? 'Failed' : posture === 'Partial' ? 'Partial' : posture === 'Not Implemented' ? 'Not Assessed' : posture === 'Not Applicable' ? 'Not Applicable' : 'Passed';
  if (posture === 'Not Implemented' || posture === 'Not Applicable') {
    const summary = posture === 'Not Implemented' ? 'No implementation exists to assess in the fixed demo scenario.' : 'This task is outside the declared project scope in the fixed demo scenario.';
    return ['2026-09-07T10:00:00.000Z', '2026-09-14T10:00:00.000Z', scenarioTime].map((observedAt, assessmentIndex) => ({ id: project.id + '-' + task.id + '-assessment-0' + (assessmentIndex + 1), observedAt, result: current, assessor: assessmentIndex === 2 ? 'Security Assurance' : 'Application Security', summary }));
  }
  return [
    { id: `${project.id}-${task.id}-assessment-01`, observedAt: '2026-09-07T10:00:00.000Z', result: 'Partial', assessor: 'Application Security', summary: 'Baseline review captured an initial implementation gap.' },
    { id: `${project.id}-${task.id}-assessment-02`, observedAt: '2026-09-14T10:00:00.000Z', result: index % 3 === 0 ? 'Passed' : 'Partial', assessor: 'Platform Engineering', summary: 'Follow-up assessment checked the project component mapping.' },
    { id: `${project.id}-${task.id}-assessment-03`, observedAt: scenarioTime, result: current, assessor: 'Security Assurance', summary: `${current} in the fixed demo scenario.` },
  ];
}

function otelFor(task, project, telemetry, index) {
  if (['Not Applicable', 'No Signal'].includes(telemetry.status)) return null;
  const traceId = createHash('sha256').update(`${project.id}:${task.id}:trace`).digest('hex').slice(0, 32);
  const spanId = createHash('sha256').update(`${project.id}:${task.id}:span`).digest('hex').slice(0, 16);
  const component = components[index % components.length];
  const outcome = telemetry.status === 'Healthy' ? 'STATUS_CODE_OK' : 'STATUS_CODE_ERROR';
  return {
    serviceName: `${project.id}-${component.toLowerCase().replaceAll(/[^a-z]+/g, '-')}`.replace(/-$/, ''),
    component,
    trace: { traceId, spanId, operation: `ssdf.${task.id.toLowerCase()}.verification`, statusCode: outcome, observedAt: '2026-09-21T11:48:00.000Z' },
    metric: { name: telemetry.status === 'Healthy' ? 'ssdf.control.evidence.freshness' : 'ssdf.control.assurance.failures', value: telemetry.status === 'Healthy' ? 98.7 : 1 + (index % 4), unit: telemetry.status === 'Healthy' ? '%' : 'events', threshold: telemetry.status === 'Healthy' ? '>= 95%' : '= 0' },
    log: { severity: telemetry.status === 'Healthy' ? 'INFO' : 'WARN', eventName: telemetry.status === 'Healthy' ? 'ssdf.evidence.verified' : 'ssdf.assurance.exception', message: telemetry.reason, attributes: { 'service.name': project.id, 'ssdf.task.id': task.id, 'deployment.environment': 'demo' } },
  };
}

function poamFor(task, project, posture, index) {
  if (!['Blocked', 'Partial', 'Not Implemented'].includes(posture)) return null;
  const owner = ['Platform Engineering', 'Application Security', 'Service Team'][index % 3];
  return {
    id: `POAM-${project.id.toUpperCase()}-${task.id.replace('.', '-')}`,
    owner,
    targetDate: posture === 'Blocked' ? '2026-09-28' : '2026-10-12',
    milestone: posture === 'Blocked' ? 'Immediate corrective action' : 'Implementation completion',
    nextAction: posture === 'Not Implemented' ? 'Define and implement the required control workflow.' : 'Validate corrective evidence in the next assessment.',
    riskAcceptance: false,
    ticket: {
      key: 'SSDF-' + (120 + index),
      system: 'Jira (simulated)',
      status: posture === 'Blocked' ? 'In Progress' : 'To Do',
      summary: 'Remediate ' + task.id + ' for ' + project.name,
    },
  };
}

function artifactReferences(record) {
  const root = 's3://ssdf-demo-evidence/2026-09-21/' + record.projectId + '/' + record.id.replace('.', '-');
  return {
    profile: { kind: 'profile', label: 'Profile JSON', objectKey: root + '/oscal-profile.json' },
    ssp: { kind: 'ssp', label: 'SSP JSON', objectKey: root + '/oscal-ssp.json' },
    plan: { kind: 'plan', label: 'Assessment Plan JSON', objectKey: root + '/oscal-assessment-plan.json' },
    assessment: { kind: 'assessment', label: 'Assessment Results JSON', objectKey: root + '/oscal-assessment-results.json' },
    poam: record.poam ? { kind: 'poam', label: 'POA&M JSON', objectKey: root + '/oscal-poam.json' } : null,
    otel: record.otel ? { kind: 'otel', label: 'OTel evidence JSON', objectKey: root + '/otel-evidence.json' } : null,
    jira: record.poam ? { kind: 'jira', label: 'Jira ticket JSON', objectKey: 'jira://ssdf-demo/browse/' + record.poam.ticket.key } : null,
  };
}

function artifactMetadata(record, title) {
  return {
    title: `${title} — ${record.projectName} ${record.id}`,
    'last-modified': scenarioTime,
    version: '1.0.0-fixture',
    'oscal-version': '1.1.3',
    props: [{ name: 'data-mode', ns: 'https://ln-ssdf.example/ns/fixture', value: 'synthetic' }],
  };
}

function mockDocuments(record) {
  const refs = artifactReferences(record);
  const findingId = fixtureUuid(`${record.projectId}:${record.id}:finding`);
  const latest = record.assessments.at(-1);
  const evidenceLinks = [refs.ssp, refs.otel].filter(Boolean).map((ref) => ({ href: ref.objectKey, rel: 'evidence', mediaType: 'application/json' }));
  const assessmentState = { Passed: 'satisfied', Failed: 'not-satisfied', Partial: 'not-satisfied', 'Not Assessed': 'not-assessed', 'Not Applicable': 'not-applicable' }[latest.result];
  const profile = { profile: {
    uuid: fixtureUuid(`${record.projectId}:${record.id}:profile`),
    metadata: artifactMetadata(record, 'Requirement scope'),
    imports: [{ href: catalogSource.url, 'include-controls': [{ 'with-ids': [record.id] }] }],
    merge: { 'as-is': true },
  } };
  const finding = {
    uuid: findingId,
    title: `${record.id} ${latest.result.toLowerCase()} assessment`,
    description: record.blockers[0]?.detail || latest.summary,
    target: { 'target-id': record.id, type: 'objective-id', status: { state: assessmentState } },
    'related-observations': [{ 'observation-uuid': fixtureUuid(`${record.projectId}:${record.id}:observation:${record.assessments.length - 1}`) }],
    links: evidenceLinks,
  };
  const ssp = {
    'system-security-plan': {
      uuid: fixtureUuid(`${record.projectId}:${record.id}:ssp`),
      metadata: artifactMetadata(record, 'Implementation record'),
      'import-profile': { href: refs.profile.objectKey },
      'system-characteristics': { 'system-name': record.projectName, description: record.projectDescription, 'security-sensitivity-level': 'moderate' },
      'system-implementation': { components: [{ uuid: fixtureUuid(`${record.projectId}:${record.id}:component`), type: 'software', title: record.component, description: `Synthetic ${record.component.toLowerCase()} boundary for ${record.projectName}.`, status: { state: 'operational' } }] },
      'control-implementation': { 'implemented-requirements': [{ uuid: fixtureUuid(`${record.projectId}:${record.id}:requirement`), 'control-id': record.id, description: record.statement, props: [{ name: 'declared-status', ns: 'https://ln-ssdf.example/ns/fixture', value: record.declaredStatus }], 'by-components': [{ 'component-uuid': fixtureUuid(`${record.projectId}:${record.id}:component`), description: `Scenario implementation for ${record.component}.` }] }] },
      'back-matter': { resources: [{ uuid: fixtureUuid(`${record.projectId}:${record.id}:catalog`), title: 'Official NIST SSDF task source', rlinks: [{ href: catalogSource.url }] }] },
    },
  };
  const plan = { 'assessment-plan': {
    uuid: fixtureUuid(`${record.projectId}:${record.id}:assessment-plan`),
    metadata: artifactMetadata(record, 'Assessment plan'),
    'import-ssp': { href: refs.ssp.objectKey },
    'reviewed-controls': { 'control-selections': [{ 'include-controls': [{ 'control-id': record.id }] }] },
    'assessment-subjects': [{ type: 'component', 'include-subjects': [{ 'subject-uuid': fixtureUuid(`${record.projectId}:${record.id}:component`) }] }],
    tasks: [{ uuid: fixtureUuid(`${record.projectId}:${record.id}:assessment-task`), type: 'action', title: `Review ${record.id}`, description: record.statement }],
  } };
  const assessment = {
    'assessment-results': {
      uuid: fixtureUuid(`${record.projectId}:${record.id}:assessment-results`),
      metadata: artifactMetadata(record, 'Assessment record'),
      'import-ap': { href: refs.plan.objectKey },
      results: record.assessments.map((item, index) => ({
        uuid: fixtureUuid(`${record.projectId}:${record.id}:result:${index}`),
        id: item.id, observedAt: item.observedAt, result: item.result,
        title: `${item.result} — ${record.id}`, description: item.summary,
        'start': item.observedAt, 'end': item.observedAt,
        'reviewed-controls': { 'control-selections': [{ 'include-controls': [{ 'control-id': record.id }] }] },
        observations: [{ uuid: fixtureUuid(`${record.projectId}:${record.id}:observation:${index}`), title: 'Scenario observation', description: item.summary, 'collected': item.observedAt, 'relevant-evidence': evidenceLinks }],
        findings: index === record.assessments.length - 1 ? [finding] : [],
      })),
    },
  };
  const poam = record.poam ? {
    'plan-of-action-and-milestones': {
      uuid: fixtureUuid(`${record.projectId}:${record.id}:poam`),
      metadata: artifactMetadata(record, 'Remediation plan'),
      'import-ssp': { href: refs.ssp.objectKey },
      'poam-items': [{ uuid: fixtureUuid(`${record.projectId}:${record.id}:poam-item`), title: record.poam.ticket.summary, description: record.poam.nextAction, 'related-findings': [{ 'finding-uuid': findingId }], 'associated-risks': [], props: [{ name: 'plan-id', ns: 'https://ln-ssdf.example/ns/fixture', value: record.poam.id }, { name: 'owner', ns: 'https://ln-ssdf.example/ns/fixture', value: record.poam.owner }], links: [{ href: refs.assessment.objectKey, rel: 'assessment' }, { href: refs.jira.objectKey, rel: 'tracking' }], 'milestones': [{ title: record.poam.milestone, description: record.poam.nextAction, 'scheduled-completion-date': record.poam.targetDate }] }],
    },
  } : null;
  const jira = record.poam ? {
    issue: {
      id: String(10000 + Number(record.poam.ticket.key.slice(5))), key: record.poam.ticket.key,
      fields: { summary: record.poam.ticket.summary, description: `${record.blockers[0]?.detail || latest.summary}\nAction: ${record.poam.nextAction}`, issuetype: { name: 'Task' }, status: { name: record.poam.ticket.status }, assignee: { displayName: record.poam.owner }, created: '2026-09-21T09:00:00.000Z', updated: scenarioTime, dueDate: record.poam.targetDate, labels: ['ssdf', record.projectId, record.id.toLowerCase(), 'fixture'], priority: { name: record.currentPosture === 'Blocked' ? 'High' : 'Medium' } },
      links: { poamId: record.poam.id, findingId, assessmentObjectKey: refs.assessment.objectKey, poamObjectKey: refs.poam.objectKey, implementationObjectKey: refs.ssp.objectKey },
    },
  } : null;
  const otel = record.otel ? { resourceSpans: [{ resource: { attributes: record.otel.log.attributes }, scopeSpans: [{ spans: [record.otel.trace] }] }], metrics: [record.otel.metric], logs: [record.otel.log] } : null;
  return { profile, ssp, plan, assessment, poam, jira, otel };
}

function reasonFor(taskId, projectId, posture) {
  if (posture !== 'Blocked') return [];
  const [type, detail] = (projectId === 'lnd' ? lndBlocked : apertureBlocked).get(taskId);
  return [{ type, detail }];
}

function countBy(rows, field, order) {
  return Object.fromEntries(order.map((value) => [value, rows.filter((row) => row[field] === value).length]));
}

function worst(rows, field, order) {
  return rows.reduce((current, row) => order.indexOf(row[field]) < order.indexOf(current) ? row[field] : current, order.at(-1));
}

export function buildDashboard(catalogDocument) {
  const catalog = catalogDocument.catalog;
  const groups = catalog.groups.map((group) => ({
    id: group.id,
    title: group.title,
    practices: (group.controls || []).map((practice) => ({
      id: practice.id,
      title: practice.title,
      statement: statement(practice),
      tasks: descendants(practice.controls).map((task) => ({ id: task.id, title: task.title, statement: statement(task), summary: shortSummary(statement(task)), examples: (task.parts || []).filter((part) => part.name === 'example').map((part) => part.prose) })),
    })),
  }));
  const tasks = groups.flatMap((group) => group.practices.flatMap((practice) => practice.tasks.map((task) => ({ ...task, groupId: group.id, groupTitle: group.title, practiceId: practice.id, practiceTitle: practice.title }))));
  const records = projects.flatMap((project) => tasks.map((task, index) => {
    const posture = pickStatus(project.id, task.id, index);
    const telemetry = telemetryFor(task, project.id, posture, index);
    return {
      ...task,
      projectId: project.id,
      projectName: project.name,
      projectDescription: project.description,
      maturity: project.maturity,
      component: components[index % components.length],
      declaredStatus: declaredStatus(posture, task.id, project.id),
      currentPosture: posture,
      telemetryStatus: telemetry.status,
      telemetryReason: telemetry.reason,
      blockers: reasonFor(task.id, project.id, posture),
      policies: organizationPolicies.filter((_, policyIndex) => (index + policyIndex) % 2 === 0).slice(0, 2),
      assessments: assessmentFor(task, project, posture, index),
      otel: otelFor(task, project, telemetry, index),
      poam: poamFor(task, project, posture, index + projects.findIndex((item) => item.id === project.id) * tasks.length),
    };
  }));
  return {
    scenarioTime,
    catalog: { ...catalogSource, title: catalog.metadata.title, oscalVersion: catalog.metadata['oscal-version'], taskCount: tasks.length },
    projects,
    organizationPolicies,
    groups,
    records,
  };
}

export function overview(dashboard) {
  return dashboard.groups.map((group) => {
    const rows = dashboard.records.filter((row) => row.groupId === group.id);
    return {
      id: group.id,
      title: group.title,
      implementation: countBy(rows, 'currentPosture', implementationOrder),
      telemetry: countBy(rows, 'telemetryStatus', telemetryOrder),
      projects: Object.fromEntries(dashboard.projects.map((project) => {
        const scoped = rows.filter((row) => row.projectId === project.id);
        return [project.id, { currentPosture: worst(scoped, 'currentPosture', implementationOrder), telemetryStatus: worst(scoped, 'telemetryStatus', telemetryOrder), implementation: countBy(scoped, 'currentPosture', implementationOrder) }];
      })),
    };
  });
}

export function publicDashboard(dashboard) {
  return {
    dataMode: 'fixture',
    scenarioTime: dashboard.scenarioTime,
    catalog: dashboard.catalog,
    projects: dashboard.projects,
    organizationPolicies: dashboard.organizationPolicies,
    groups: dashboard.groups.map((group) => ({ id: group.id, title: group.title, practices: group.practices.map(({ tasks, ...practice }) => ({ ...practice, taskCount: tasks.length })) })),
    overview: overview(dashboard),
    records: dashboard.records.map(({ assessments, otel, policies, poam, blockers, examples, ...row }) => ({ ...row, blockerCount: blockers.length, poamId: poam?.id || null })),
  };
}

export function detailFor(dashboard, taskId) {
  const records = dashboard.records.filter((row) => row.id === taskId);
  if (!records.length) return null;
  const base = records[0];
  return {
    dataMode: 'fixture',
    scenarioTime: dashboard.scenarioTime,
    catalog: dashboard.catalog,
    task: { id: base.id, title: base.title, statement: base.statement, summary: base.summary, examples: base.examples, groupId: base.groupId, groupTitle: base.groupTitle, practiceId: base.practiceId, practiceTitle: base.practiceTitle },
    projects: records.map((record) => ({ ...record, artifacts: artifactReferences(record) })),
    organizationPolicies: dashboard.organizationPolicies,
    raw: {
      profile: { 'profile-id': 'org-ssdf-profile-demo', imports: [catalogSource.url], policies: organizationPolicies },
      ssps: Object.fromEntries(records.map((record) => [record.projectId, mockDocuments(record).ssp])),
      assessments: Object.fromEntries(records.map((record) => [record.projectId, mockDocuments(record).assessment])),
    },
  };
}

export function artifactFor(dashboard, kind, projectId, taskId) {
  const record = dashboard.records.find((row) => row.id === taskId && row.projectId === projectId);
  if (!record || !['profile', 'ssp', 'plan', 'assessment', 'poam', 'otel', 'jira'].includes(kind)) return null;
  const references = artifactReferences(record);
  const reference = references[kind];
  if (!reference) return null;
  const document = mockDocuments(record)[kind];
  return { dataMode: 'fixture', artifact: reference, document };
}
