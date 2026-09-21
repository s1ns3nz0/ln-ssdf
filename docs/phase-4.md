# Phase 4 — ArgoCD GitOps cutover gate

**Status: not started.** This document is an implementation contract, not evidence
that ArgoCD or GitOps is running.

## Boundary

ArgoCD must become the reconciler for Git-managed deployment declarations in the
local verification cluster. Runtime-only values remain outside Git: the PostgreSQL
bootstrap password, bitcoind RPC password, Grafana administrator password, Vault
initialization material, and Vault-issued credentials. Their creation and recovery
are explicit bootstrap exceptions; neither their values nor a reversible encoding
of their values may be committed.

The cutover will use an app-of-apps layout. The required ordering is:

1. ArgoCD control plane and its namespace.
2. Vault/unsealer declarations.
3. PostgreSQL and bitcoind declarations.
4. VSO resource declarations and the Vault database-engine setup exception.
5. lnd declarations.
6. observability declarations.

Each child application needs an explicit sync-wave annotation. The application
source must pin a Git revision, rather than tracking an ambient filesystem path.

## Gate

Phase 4 is `passed` only when all of the following occur on a fresh
`ln-ssdf-phase0` cluster:

- ArgoCD is installed from a version-and-digest-pinned artifact.
- The root Application reads a local Git commit and creates the child
  Applications in the declared wave order.
- The applications reach `Synced` and `Healthy` after the approved runtime
  bootstrap exceptions are supplied.
- A committed benign declaration change is reconciled by ArgoCD; an equivalent
  out-of-band mutation is reported as drift and reconciled back to the committed
  state.
- The Phase 2 Lightning payment and Phase 3 four-target scrape gates still pass.
- A rebuild uses the documented Git revision plus fresh runtime bootstrap inputs;
  no developer-machine path is accepted as an application source.

Until a Git repository exists and this gate has passed, direct Helm invocations
remain the verified local bootstrap path, not a GitOps claim.
