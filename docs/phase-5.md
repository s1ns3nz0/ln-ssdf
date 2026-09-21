# Phase 5 — CI and keyless source provenance

**Status: complete for the source-provenance scope.** `main` requires the
`Repository verification` check, and administrators are subject to the same
rule. Image/SBOM/VSA evidence remains a separate Phase 7 concern.

The workflow pins Actions, runs Node and Helm verification on Ubuntu 24.04, and
only grants `id-token: write` after a `main` push passes verification. It signs a
non-secret source provenance statement with Cosign keyless mode and retains the
bundle as a workflow artifact; it neither publishes nor claims an image signature.

On 2026-09-21, [run 35591393479](https://github.com/s1ns3nz0/ln-ssdf/actions/runs/35591393479)
signed validated commit `dad63e1584206d0d9d55315f9daf75e425cbc32d`. Its downloaded
artifact verified cryptographically with the expected GitHub OIDC issuer and the
exact workflow identity
`https://github.com/s1ns3nz0/ln-ssdf/.github/workflows/attest-source-provenance.yml@refs/heads/main`.
The signed statement's repository, workflow, run ID, and commit all matched the
run. `scripts/verify-ci-provenance.sh` records the repeatable verifier; it needs
the downloaded artifact directory, commit, run ID, and repository as inputs.

The attestation workflow is triggered only after `Validate` succeeds on `main`,
then checks out that workflow's exact `head_sha` before generating the statement.
This source statement is not an image signature or an SBOM/VSA; local keys and
unsigned JSON are not substitutes for those controls.
