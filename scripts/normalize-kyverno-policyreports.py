"""Adapt current Kyverno v1alpha2 PolicyReports for C2P 0.5.0.

C2P 0.5.0 reads result.resources, while current Kyverno reports the same
resource identity at item.scope. The original report remains immutable.
"""
import json
import sys

source = json.load(open(sys.argv[1]))
for item in source.get('items', []):
    scope = item.get('scope')
    for result in item.get('results', []):
        if scope and not result.get('resources'):
            result['resources'] = [scope]
json.dump(source, sys.stdout)
