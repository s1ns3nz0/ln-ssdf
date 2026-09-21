#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 --evidence-dir DIR --commit SHA --run-id ID --repository OWNER/REPO" >&2
  exit 64
}

evidence_dir=
commit=
run_id=
repository=
while (($#)); do
  case "$1" in
    --evidence-dir) evidence_dir=${2:-}; shift 2 ;;
    --commit) commit=${2:-}; shift 2 ;;
    --run-id) run_id=${2:-}; shift 2 ;;
    --repository) repository=${2:-}; shift 2 ;;
    *) usage ;;
  esac
done
[[ -n "$evidence_dir" && -n "$commit" && -n "$run_id" && -n "$repository" ]] || usage
for command in cosign jq; do command -v "$command" >/dev/null || { echo "missing $command" >&2; exit 69; }; done

statement="$evidence_dir/ci-provenance.json"
bundle="$evidence_dir/ci-provenance.bundle.json"
[[ -f "$statement" && -f "$bundle" ]] || { echo "missing provenance artifact files" >&2; exit 66; }

identity="https://github.com/${repository}/.github/workflows/attest-source-provenance.yml@refs/heads/main"
cosign verify-blob \
  --bundle "$bundle" \
  --certificate-identity "$identity" \
  --certificate-oidc-issuer 'https://token.actions.githubusercontent.com' \
  "$statement"

jq -e --arg commit "$commit" --arg run_id "$run_id" --arg repository "$repository" '
  ._type == "https://in-toto.io/Statement/v1" and
  .predicateType == "https://ln-ssdf.dev/ci-provenance/v1" and
  .predicate.commit == $commit and
  .predicate.repository == $repository and
  .predicate.workflow == "Attest Source Provenance" and
  .predicate.runId == $run_id
' "$statement" >/dev/null

echo "verified GitHub OIDC provenance for ${repository}@${commit}, run ${run_id}"
