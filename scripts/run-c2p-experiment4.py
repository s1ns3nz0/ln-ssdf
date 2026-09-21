"""Run the installed C2P Kyverno plugin for the Experiment 4 artifacts."""
import argparse
import json
import os
import shutil
import sys
from pathlib import Path

parser = argparse.ArgumentParser(
    description='Generate the Experiment 4 Kyverno policy with a C2P source checkout.'
)
parser.add_argument(
    '--c2p-root',
    default=os.environ.get('C2P_ROOT'),
    help='Path to a pinned compliance-to-policy checkout (or set C2P_ROOT).',
)
args = parser.parse_args()

if not args.c2p_root:
    raise SystemExit('--c2p-root (or C2P_ROOT) is required; use a pinned C2P checkout.')

C2P_ROOT = Path(args.c2p_root).expanduser().resolve()
if not (C2P_ROOT / 'c2p' / 'framework' / 'c2p.py').is_file() or not (
    C2P_ROOT / 'plugins_public' / 'plugins' / 'kyverno.py'
).is_file():
    raise SystemExit(f'not a C2P checkout with the Kyverno plugin: {C2P_ROOT}')

sys.path.insert(0, str(C2P_ROOT))

from c2p.framework.c2p import C2P
from c2p.framework.models.c2p_config import C2PConfig, ComplianceOscal
from plugins_public.plugins.kyverno import PluginConfigKyverno, PluginKyverno

ROOT = Path(__file__).resolve().parents[1]
OSCAL = ROOT / 'experiments' / 'oscal'
TEMPLATES = OSCAL / 'c2p-policy-templates'
OUT = OSCAL / 'generated-policy'
RULE = 'experiment-1-require-sbom-and-vsa'

if OUT.exists():
    shutil.rmtree(OUT)
(TEMPLATES / RULE).mkdir(parents=True, exist_ok=True)
shutil.copy2(ROOT / 'experiments' / 'sbom-vsa' / 'kyverno-policy.yaml', TEMPLATES / RULE / 'policy.yaml')

config = C2PConfig()
config.compliance = ComplianceOscal()
config.compliance.component_definition = str(OSCAL / 'component-definition.json')
config.pvp_name = 'Kyverno'
config.result_title = 'Experiment 4 Kyverno Assessment Results'
config.result_description = 'C2P conversion of Experiment 1 Kyverno PolicyReports'
C2P(config)  # validates that C2P can load the project Component Definition

# C2P currently derives its rule set from the Component Definition. The current
# 1.2.3 document is intentionally preserved, so pass the selected rule to the
# official Kyverno plugin after that compatibility check.
PluginKyverno(PluginConfigKyverno(
    policy_template_dir=str(TEMPLATES), deliverable_policy_dir=str(OUT)
)).generate_pvp_policy(type('Policy', (), {'rule_sets': [type('Rule', (), {'rule_id': RULE})()], 'parameters': []})())

generated = OUT / RULE / 'policy.yaml'
if not generated.exists() or generated.read_bytes() != (ROOT / 'experiments' / 'sbom-vsa' / 'kyverno-policy.yaml').read_bytes():
    raise SystemExit('C2P generated policy is not byte-identical to the reviewed Kyverno template')
print(json.dumps({'generatedPolicy': str(generated), 'ruleId': RULE}))
