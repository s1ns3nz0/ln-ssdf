#!/usr/bin/env bash
# Reports whether a Phase 7 enforcement promotion is evidenced. It deliberately
# exits nonzero for no_evidence; callers must not treat that state as a pass.
set -euo pipefail

[[ "${1:-}" == "--context" && "${2:-}" == "kind-ln-ssdf-phase0" ]] || {
  echo "usage: $0 --context kind-ln-ssdf-phase0" >&2
  exit 2
}
context="$2"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
inventory="$repo_root/manifests/phase7/image-evidence-inventory.yaml"

kubectl --context "$context" get validatingpolicy ssdf-audit-image-digest >/dev/null

# Keep this parser deliberately narrow: the checked-in inventory has one image
# and one status per item. This avoids making a convenience YAML CLI a hidden
# Phase 7 prerequisite.
expected="$(awk '/^    - image: / { print $3 }' "$inventory" | LC_ALL=C sort)"
observed="$(kubectl --context "$context" -n ssdf-system get pods -o json \
  | jq -r '[.items[].spec | (.containers[]?, .initContainers[]?, .ephemeralContainers[]?) | .image] | unique[]' \
  | LC_ALL=C sort)"

if [[ "$expected" != "$observed" ]]; then
  echo "Phase 7 hold: runtime image inventory differs from the reviewed evidence inventory." >&2
  diff -u <(printf '%s\n' "$expected") <(printf '%s\n' "$observed") >&2 || true
  exit 1
fi

missing="$(awk '
  /^    - image: / { image = $3 }
  /^      status: / && $2 != "verified" { print image }
' "$inventory")"
missing_count="$(printf '%s\n' "$missing" | awk 'NF { count++ } END { print count + 0 }')"
expected_count="$(printf '%s\n' "$expected" | awk 'NF { count++ } END { print count + 0 }')"
if [[ "$missing_count" -gt 0 ]]; then
  printf 'Phase 7 hold: %s of %s runtime images are not verified.\n' "$missing_count" "$expected_count" >&2
  printf '%s\n' "$missing" >&2
  exit 3
fi

echo "Phase 7 readiness gate passed: all runtime images are marked verified."
