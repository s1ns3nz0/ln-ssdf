# Phase 5 — CI and keyless source provenance

**Status: partial (GitHub OIDC provenance verified; protected-branch control is
not yet configured or verified).**

The workflow pins Actions, runs Node and Helm verification on Ubuntu 24.04, and
only grants `id-token: write` after a `main` push passes verification. It signs a
non-secret source provenance statement with Cosign keyless mode and retains the
bundle as a workflow artifact; it neither publishes nor claims an image signature.

On 2026-09-21, [run 35589420371](https://github.com/s1ns3nz0/ln-ssdf/actions/runs/35589420371)
completed for commit `d09bdcf7307840e6b78cf17e56d86e1988340de7`. Its downloaded
artifact verified cryptographically with the expected GitHub OIDC issuer and the
exact workflow identity
`https://github.com/s1ns3nz0/ln-ssdf/.github/workflows/ci.yml@refs/heads/main`.
The signed statement's repository, workflow, run ID, and commit all matched the
run. `scripts/verify-ci-provenance.sh` records the repeatable verifier; it needs
the downloaded artifact directory, commit, run ID, and repository as inputs.

This remains partial: branch protection for `main` was neither configured nor
observed, and this source statement is not an image signature or an SBOM/VSA.
Local keys and unsigned JSON are not a substitute.
