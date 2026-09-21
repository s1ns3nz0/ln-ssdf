import { readFileSync, existsSync } from 'node:fs';
import { resolve, dirname } from 'node:path';

const root = resolve('experiments/oscal');
const load = (name) => JSON.parse(readFileSync(resolve(root, name), 'utf8'));
const required = ['catalog.json', 'profile.json', 'component-definition.json', 'ssp.json', 'assessment-plan.json', 'assessment-results.json'];
for (const name of required) if (!existsSync(resolve(root, name))) throw new Error(`missing OSCAL document: ${name}`);

const catalog = load('catalog.json').catalog;
const profile = load('profile.json').profile;
const component = load('component-definition.json')['component-definition'];
const ssp = load('ssp.json')['system-security-plan'];
const plan = load('assessment-plan.json')['assessment-plan'];
const results = load('assessment-results.json')['assessment-results'];
const control = 'DEPLOY-REQ-4';
if (!catalog.groups.flatMap((g) => g.controls ?? []).some((c) => c.id === control)) throw new Error('catalog control missing');
if (profile.imports[0].href !== 'catalog.json') throw new Error('profile does not import catalog');
if (component.components[0]['control-implementations'][0]['implemented-requirements'][0]['control-id'] !== control) throw new Error('component trace missing');
if (ssp['import-profile'].href !== 'profile.json') throw new Error('SSP does not import profile');
if (plan['import-ssp'].href !== 'ssp.json' || results['import-ap'].href !== 'assessment-plan.json') throw new Error('assessment trace is broken');
const evidence = results.results[0].observations[0]['relevant-evidence'][0].href;
if (!existsSync(resolve(dirname(resolve(root, 'assessment-results.json')), evidence))) throw new Error('external VSA evidence missing');
const statuses = new Set(load('project-status-map.json').mapping.map((x) => x.projectStatus));
for (const value of ['satisfied', 'not_satisfied', 'no_evidence', 'not_implemented', 'not_applicable']) if (!statuses.has(value)) throw new Error(`missing project status: ${value}`);
console.log('OSCAL trace and project-status mapping are valid.');
