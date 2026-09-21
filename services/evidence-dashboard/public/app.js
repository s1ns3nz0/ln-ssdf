const base = window.__DASHBOARD_BASE_PATH__ || '/lnd';
const root = document.querySelector('#app');
const dialog = document.querySelector('#raw-dialog');
const params = new URLSearchParams(location.search);
const state = { data: null, detail: null, group: params.get('group') || 'overview', project: params.get('project') || 'all', scope: params.get('scope') || 'all', implementation: params.get('implementation') || 'all', telemetry: params.get('telemetry') || 'all', q: params.get('q') || '', control: params.get('control') || '', tab: params.get('tab') || 'posture', inspectorProject: '' };
const implementationOrder = ['Blocked', 'Not Implemented', 'Partial', 'Implemented', 'Not Applicable'];
const telemetryOrder = ['No Signal', 'Stale', 'Degraded', 'Healthy', 'Not Applicable'];
const evidenceLabels = { 'No Signal': 'No evidence', Stale: 'Out of date', Degraded: 'Needs review', Healthy: 'Current', 'Not Applicable': 'Not needed' };
let selectionRequest = 0;
const esc = (value = '') => String(value).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);
const slug = (value) => String(value).toLowerCase().replaceAll(/[^a-z]+/g, '-');
const badge = (value) => '<span class="status ' + slug(value) + '">' + esc(value) + '</span>';
const worst = (rows, key, order) => rows.reduce((current, row) => order.indexOf(row[key]) < order.indexOf(current) ? row[key] : current, order.at(-1));

function saveUrl() {
  const next = new URLSearchParams();
  for (const key of ['group', 'project', 'scope', 'implementation', 'telemetry', 'q', 'control', 'tab']) if (state[key] && state[key] !== 'all' && state[key] !== 'overview' && state[key] !== 'posture') next.set(key, state[key]);
  history.replaceState({}, '', base + '/' + (next.size ? '?' + next : ''));
}

function rows() {
  return state.data.records.filter((row) => (state.group === 'overview' || row.groupId === state.group) && (state.project === 'all' || row.projectId === state.project) && (state.scope === 'all' || statusKind(row) === state.scope) && (state.implementation === 'all' || row.currentPosture === state.implementation) && (state.telemetry === 'all' || row.telemetryStatus === state.telemetry) && (!state.q || (row.id + row.statement + row.component).toLowerCase().includes(state.q.toLowerCase())));
}

function statusKind(row) {
  if (['Blocked', 'Not Implemented'].includes(row.currentPosture)) return 'needs-attention';
  if (row.currentPosture === 'Partial' || ['No Signal', 'Stale', 'Degraded'].includes(row.telemetryStatus)) return 'in-progress';
  return 'covered';
}

function rollup(items) {
  const counts = { 'needs-attention': 0, 'in-progress': 0, covered: 0 };
  items.forEach((row) => { counts[statusKind(row)] += 1; });
  return counts;
}

function statusBar(counts, compact = false) {
  const total = counts['needs-attention'] + counts['in-progress'] + counts.covered || 1;
  const labels = [['needs-attention', 'Needs attention'], ['in-progress', 'In progress'], ['covered', 'Covered']];
  return '<div class="status-summary">' + labels.filter(([key]) => !compact || counts[key]).map(([key, label]) => '<span class="' + key + '">' + label + ' <b>' + counts[key] + '</b></span>').join('') + '</div><div class="status-bar" aria-label="Status distribution">' + labels.map(([key]) => '<i class="' + key + '" style="width:' + (counts[key] / total * 100) + '%"></i>').join('') + '</div>';
}

function options(values, selected, labels = {}) {
  return '<option value="all">All</option>' + values.map((value) => '<option value="' + esc(value) + '"' + (value === selected ? ' selected' : '') + '>' + esc(labels[value] || value) + '</option>').join('');
}

function scopeOptions() {
  return '<option value="all"' + (state.scope === 'all' ? ' selected' : '') + '>All scoped systems</option><option value="needs-attention"' + (state.scope === 'needs-attention' ? ' selected' : '') + '>Systems needing attention</option><option value="in-progress"' + (state.scope === 'in-progress' ? ' selected' : '') + '>Systems in progress</option><option value="covered"' + (state.scope === 'covered' ? ' selected' : '') + '>Covered systems</option>';
}

function projectOptions() {
  return '<option value="all"' + (state.project === 'all' ? ' selected' : '') + '>All projects</option>' + state.data.projects.map((project) => '<option value="' + esc(project.id) + '"' + (state.project === project.id ? ' selected' : '') + '>' + esc(project.name) + ' — ' + esc(project.description) + '</option>').join('');
}

function shell() {
  const navigation = state.data.groups.map((group) => { const counts = rollup(state.data.records.filter((row) => row.groupId === group.id)); return '<button class="nav-item ' + (state.group === group.id ? 'active' : '') + '" data-group="' + group.id + '"><b>' + group.id + '</b><small>' + esc(group.title) + '</small><em>Needs attention: ' + counts['needs-attention'] + '</em></button>'; }).join('');
  root.innerHTML = '<header class="topbar"><div><p class="eyebrow">SSDF POSTURE · DEMO</p><h1>Software security posture</h1><p class="topbar-notice">NIST task text is official; project assessments and evidence are synthetic. Storage and Jira references are simulated. Fixed scenario time: ' + new Date(state.data.scenarioTime).toUTCString() + '</p></div><div class="catalog-meta"><strong>NIST SSDF source</strong><span>' + esc(state.data.catalog.release) + ' · ' + state.data.catalog.taskCount + ' tasks</span><a href="' + esc(state.data.catalog.url) + '" target="_blank" rel="noreferrer">Open source ↗</a></div></header><main class="layout' + (state.control ? ' inspector-open' : '') + '"><aside class="rail"><button class="nav-item ' + (state.group === 'overview' ? 'active' : '') + '" data-group="overview"><b>Overview</b><small>Portfolio posture</small></button><p class="nav-caption">NIST SSDF practices</p>' + navigation + '</aside><section class="workspace"><div class="filters"><label>Project<select data-field="project">' + projectOptions() + '</select></label><label>Scope<select data-field="scope">' + scopeOptions() + '</select></label><label>Implementation<select data-field="implementation">' + options(implementationOrder, state.implementation) + '</select></label><label>Evidence freshness<select data-field="telemetry">' + options(telemetryOrder, state.telemetry) + '</select></label><label class="search">Search<input data-field="q" value="' + esc(state.q) + '" placeholder="Control ID, requirement, component"></label><button class="reset" data-reset>Reset</button></div><div id="content"></div></section><aside id="inspector" class="inspector"></aside></main>';
  root.querySelectorAll('[data-group]').forEach((button) => button.onclick = () => { state.group = button.dataset.group; state.control = ''; state.detail = null; saveUrl(); render(); });
  root.querySelectorAll('[data-field]').forEach((input) => input.oninput = () => { state[input.dataset.field] = input.value; state.control = ''; state.detail = null; saveUrl(); render(); });
  root.querySelector('[data-reset]').onclick = () => { Object.assign(state, { project: 'all', scope: 'all', implementation: 'all', telemetry: 'all', q: '', control: '', detail: null }); saveUrl(); render(); };
}

function overview() {
  const target = document.querySelector('#content');
  const visible = rows();
  const selectedProject = state.data.projects.find((project) => project.id === state.project);
  const cards = state.data.groups.map((group) => {
    const groupRows = visible.filter((row) => row.groupId === group.id);
    const counts = rollup(groupRows);
    return '<button class="posture-card" data-group="' + group.id + '"><p class="eyebrow">' + group.id + '</p><h3>' + esc(group.title) + '</h3><p>' + groupRows.length + ' scoped control implementations</p>' + statusBar(counts) + '</button>';
  }).join('');
  target.innerHTML = '<section class="page-heading"><div><p class="eyebrow">' + (selectedProject ? esc(selectedProject.name) : 'ALL SCOPED PROJECTS') + '</p><h2>SSDF posture</h2><p>' + (selectedProject ? esc(selectedProject.description) + '. ' : '') + 'Each practice is summarized by what needs attention, what is in progress, and what is covered. No single compliance score is used.</p></div></section><section class="posture-cards">' + cards + '</section><section class="blocker-list"><h3>Work needing attention</h3>' + visible.filter((row) => statusKind(row) === 'needs-attention').slice(0, 8).map((row) => '<button class="gap-row" data-control="' + row.id + '">' + badge('Needs attention') + '<b>' + row.id + '</b><p>' + esc(row.statement) + '</p></button>').join('') + '</section>';
  target.querySelectorAll('[data-group]').forEach((button) => button.onclick = () => { state.group = button.dataset.group; saveUrl(); render(); });
  target.querySelectorAll('[data-control]').forEach((button) => button.onclick = () => selectControl(button.dataset.control));
}

function explorer() {
  const target = document.querySelector('#content');
  const group = state.data.groups.find((item) => item.id === state.group);
  const matching = rows();
  const practices = group.practices.map((practice) => {
    const taskIds = [...new Set(matching.filter((row) => row.practiceId === practice.id).map((row) => row.id))];
    if (!taskIds.length) return '';
    const taskRows = taskIds.map((id) => {
      const related = matching.filter((row) => row.id === id);
      const first = related[0];
      const counts = rollup(related);
      const activeCount = related.filter((row) => row.poamId).length;
      const activeWork = activeCount ? '<small class="active-action">Remediation · ' + activeCount + ' project' + (activeCount === 1 ? '' : 's') + '</small>' : '';
      return '<button class="task-row ' + (state.control === id ? 'selected' : '') + '" data-control="' + id + '"><div><b>' + id + '</b><span>' + esc(first.summary) + '</span></div><div class="task-status">' + statusBar(counts, true) + '</div>' + activeWork + '</button>';
    }).join('');
    return '<details open class="practice"><summary><span><b>' + practice.id + '</b> ' + esc(practice.title) + '</span><em>' + taskIds.length + ' tasks</em></summary><p>' + esc(practice.statement) + '</p>' + taskRows + '</details>';
  }).join('');
  target.innerHTML = '<section class="page-heading"><div><p class="eyebrow">' + group.id + ' · ' + esc(group.title) + '</p><h2>' + esc(group.title) + '</h2><p>Every row shows the actual NIST requirement and the current portfolio work state.</p></div></section><section class="control-list">' + (practices || '<p class="empty">No matching controls. Reset filters to restore the list.</p>') + '</section>';
  target.querySelectorAll('[data-control]').forEach((button) => button.onclick = () => selectControl(button.dataset.control));
}

function inspector() {
  const target = document.querySelector('#inspector');
  if (!state.control || !state.detail) { target.innerHTML = ''; return; }
  const projects = state.project === 'all' ? state.detail.projects : state.detail.projects.filter((project) => project.projectId === state.project);
  if (!state.inspectorProject || !projects.some((row) => row.projectId === state.inspectorProject)) state.inspectorProject = projects.find((row) => row.currentPosture === 'Blocked')?.projectId || projects[0].projectId;
  const selected = projects.find((row) => row.projectId === state.inspectorProject);
  const tabs = ['posture', 'ssp', 'evidence', 'remediation', 'catalog'];
  const tabLabels = { posture: 'Posture', ssp: 'Implementation record', evidence: 'Evidence', remediation: 'Remediation', catalog: 'Requirement source' };
  const artifactLabels = { profile: 'Requirement scope', ssp: 'Implementation record', plan: 'Assessment plan', assessment: 'Assessment record', poam: 'Remediation plan', otel: 'Runtime evidence', jira: 'Jira record' };
  let body = '';
  const jiraHref = base + '/api/artifacts/jira/' + selected.projectId + '/' + state.detail.task.id + '.json';
  const currentWork = selected.poam ? '<section class="current-work"><b>Active remediation</b><span>' + esc(selected.poam.nextAction) + ' · ' + esc(selected.poam.owner) + ' · ' + esc(selected.poam.targetDate) + '</span><a class="jira-link" href="' + jiraHref + '" target="_blank" rel="noreferrer">' + esc(selected.poam.ticket.key) + '</a></section>' : '';
  const artifactLinks = Object.values(selected.artifacts).filter(Boolean).map((artifact) => '<a class="artifact-link" href="' + base + '/api/artifacts/' + artifact.kind + '/' + selected.projectId + '/' + state.detail.task.id + '.json" target="_blank" rel="noreferrer" title="Simulated reference: ' + esc(artifact.objectKey) + '">' + esc(artifactLabels[artifact.kind] || artifact.label) + '</a>').join('');
  const recordsPanel = '<details class="record-details"><summary>Source records</summary><div class="artifact-links">' + artifactLinks + '</div></details>';
  if (state.tab === 'posture') body = '<div class="split-status"><div>Implementation' + badge(selected.declaredStatus) + '</div><div>Current posture' + badge(selected.currentPosture) + '</div><div>Evidence freshness' + badge(selected.telemetryStatus) + '</div></div><p class="muted">' + esc(selected.telemetryReason) + '</p>' + (selected.blockers[0] ? '<div class="reason"><b>' + esc(selected.blockers[0].type) + '</b><p>' + esc(selected.blockers[0].detail) + '</p></div>' : '') + recordsPanel;
  if (state.tab === 'ssp') body = '<p><b>' + esc(selected.component) + '</b> · ' + esc(selected.declaredStatus) + '</p><p class="muted">' + esc(state.detail.task.statement) + '</p>' + recordsPanel;
  if (state.tab === 'evidence') body = '<p><b>Runtime evidence:</b> ' + (selected.otel ? esc(selected.otel.log.message) : esc(selected.telemetryStatus)) + '</p><p><b>Latest assessment:</b> ' + esc(selected.assessments.at(-1).result) + ' · ' + esc(selected.assessments.at(-1).summary) + '</p><details class="record-details"><summary>Assessment history</summary>' + selected.assessments.map((assessment) => '<p class="assessment-row">' + badge(assessment.result) + '<b>' + esc(assessment.assessor) + '</b> ' + esc(assessment.summary) + '</p>').join('') + '</details>' + recordsPanel;
  if (state.tab === 'remediation') body = selected.poam ? '<p><b>' + esc(selected.poam.id) + '</b> · ' + esc(selected.poam.milestone) + '</p><p>' + esc(selected.poam.nextAction) + '</p>' + recordsPanel : '<p class="muted">No active remediation.</p>';
  if (state.tab === 'catalog') body = '<p>' + esc(state.detail.task.statement) + '</p><details class="record-details"><summary>Examples and source details</summary><ol>' + state.detail.task.examples.map((example) => '<li>' + esc(example) + '</li>').join('') + '</ol><dl><dt>Commit</dt><dd class="mono">' + esc(state.detail.catalog.commit) + '</dd><dt>SHA-256</dt><dd class="mono">' + esc(state.detail.catalog.sha256) + '</dd></dl></details><button class="secondary" data-raw="catalog">View source document</button>';
  target.innerHTML = '<div class="inspector-header"><button class="close-inspector" data-close-inspector aria-label="Close control inspector">×</button><p class="eyebrow">' + state.detail.task.groupId + ' · ' + state.detail.task.practiceId + '</p><h2>' + state.detail.task.id + '</h2><p>' + esc(state.detail.task.summary) + '</p><div class="inspector-projects">' + (projects.length > 1 ? projects.map((project) => '<button class="' + (project.projectId === selected.projectId ? 'active' : '') + '" data-project-tab="' + project.projectId + '">' + esc(project.projectName) + badge(project.currentPosture) + '</button>').join('') : '') + '</div></div>' + currentWork + '<div class="tabs">' + tabs.map((tab) => '<button class="' + (tab === state.tab ? 'active' : '') + '" data-tab="' + tab + '">' + tabLabels[tab] + '</button>').join('') + '</div><div class="inspector-body">' + body + '</div>';
  target.querySelector('[data-close-inspector]').onclick = () => { Object.assign(state, { control: '', detail: null, inspectorProject: '' }); saveUrl(); render(); };
  target.querySelectorAll('[data-tab]').forEach((button) => button.onclick = () => { state.tab = button.dataset.tab; saveUrl(); inspector(); });
  target.querySelectorAll('[data-project-tab]').forEach((button) => button.onclick = () => { state.inspectorProject = button.dataset.projectTab; inspector(); });
  target.querySelectorAll('[data-raw]').forEach((button) => button.onclick = () => openRaw(button.dataset.raw));
}

async function openRaw(kind) {
  let artifact = kind === 'catalog' ? await fetch(base + '/api/raw/catalog').then((response) => response.ok ? response.json() : null).then((payload) => payload?.document) : kind === 'ssp' ? state.detail.raw.ssps[state.inspectorProject] : state.detail.raw.assessments[state.inspectorProject];
  artifact = artifact || state.detail.raw.profile;
  window.document.querySelector('#raw-title').textContent = 'Source document JSON';
  window.document.querySelector('#raw-content').textContent = JSON.stringify(artifact, null, 2);
  dialog.showModal();
}

async function selectControl(control) {
  const request = ++selectionRequest;
  const changedControl = state.control !== control;
  state.control = control; if (changedControl) state.tab = 'posture'; state.detail = null; document.querySelector('.layout')?.classList.add('inspector-open'); saveUrl(); inspector();
  const response = await fetch(base + '/api/controls/' + encodeURIComponent(control));
  if (!response.ok || request !== selectionRequest || control !== state.control) return;
  state.detail = await response.json(); inspector();
}

function render() { shell(); if (state.group === 'overview') overview(); else explorer(); inspector(); if (state.control) selectControl(state.control); }
try { const response = await fetch(base + '/api/dashboard'); if (!response.ok) throw new Error('API unavailable'); state.data = await response.json(); if (state.group !== 'overview' && !state.data.groups.some((group) => group.id === state.group)) state.group = 'overview'; if (state.project !== 'all' && !state.data.projects.some((project) => project.id === state.project)) state.project = 'all'; if (!['all', 'needs-attention', 'in-progress', 'covered'].includes(state.scope)) state.scope = 'all'; render(); } catch (error) { root.innerHTML = '<div class="fatal"><h1>Data unavailable</h1><p>' + esc(error.message) + '</p></div>'; }
