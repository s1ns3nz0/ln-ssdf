# Phase 5 — CI and keyless source provenance

**Status: partial (workflow implemented; GitHub OIDC execution unverified).**

The workflow pins Actions, runs Node and Helm verification on Ubuntu 24.04, and
only grants `id-token: write` after a `main` push passes verification. It signs a
non-secret source provenance statement with Cosign keyless mode and retains the
bundle as a workflow artifact; it neither publishes nor claims an image signature.

The gate remains partial until an authorized GitHub remote runs this workflow on a
protected `main` push and the resulting bundle is verified for the expected OIDC
issuer, workflow identity, and commit. Local keys and unsigned JSON are not a
substitute.
