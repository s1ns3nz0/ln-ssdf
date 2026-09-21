import { readFileSync, writeFileSync } from 'node:fs';

const [input, output] = process.argv.slice(2);
const document = JSON.parse(readFileSync(input, 'utf8'));
const result = document['assessment-results'].results[0];
document['assessment-results']['import-ap'] = { href: 'assessment-plan.json' };
result['reviewed-controls'] = { 'control-selections': [{ 'include-controls': [{ 'control-id': 'DEPLOY-REQ-4' }] }] };
writeFileSync(output, `${JSON.stringify(document, null, 2)}\n`);
