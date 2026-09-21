# Phase 1 Vault chart

This chart deliberately creates one persistent Raft node per release. Install it twice:

- `unsealer` without `transit.enabled`; this Vault requires manual Shamir unseal.
- `main` with `transit.enabled`; it gets only a scoped transit token from a runtime Kubernetes Secret and auto-unseals after initialization.

The chart never creates initialization keys, root tokens, or transit tokens. The Phase 1 bootstrap procedure must receive a Git-external state directory and place those values there with mode `0700`.
