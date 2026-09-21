# Phase 6 — Kyverno Audit and isolated enforcement

**Status: implemented and runtime-verified.** `ValidatingPolicy` (the current
Kyverno policy API) audits only the label-selected `ssdf-system` namespace.
The isolated `ssdf-policy-test` namespace uses the same check with `Deny`.

The policy requires a full `@sha256:<64 lowercase hex>` reference for every
ordinary, init, and ephemeral container. The bootstrap test proves rejection of
both a mutable ordinary container and a mutable init container using server-side
admission dry-runs. Existing `ssdf-system` resources have PolicyReport PASS
evidence from the Audit policy.

This is deliberately not the Phase 7 signed-SBOM/VSA enforcement policy. Until
that binding exists, `ssdf-system` remains audit-only; a mutable image cannot be
mistakenly promoted as verified merely because it has a digest.
