#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
for command in helm node; do command -v "$command" >/dev/null || { echo "missing $command" >&2; exit 1; }; done
npm test
for chart in charts/*; do helm lint "$chart"; helm template "$(basename "$chart")" "$chart" >/dev/null; done
git diff --check
