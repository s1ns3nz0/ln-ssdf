# Phase 7 — image evidence enforcement readiness

**Status: explicitly held; no production Enforce promotion.** The seven
runtime images in `ssdf-system` are digest-pinned and covered by Phase 6 Audit,
but each is `no_evidence` in the versioned inventory. Digest pinning alone does
not establish a passing, fresh VSA or a verified SBOM.

`scripts/phase7-readiness.sh --context kind-ln-ssdf-phase0` compares the live
Pod image set to that inventory and exits with status 3 while an entry remains
unverified. It exits 1 if an unreviewed image appears. Both outcomes block
promotion and make missing evidence visible rather than silently treating it as
an allow-list match.

Promotion requires, per image: a signed CycloneDX SBOM, a passing and unexpired
VSA whose input-attestation digest refers to that exact SBOM, trusted issuer
identity, and transparency-log verification. The local static-key experiment
proves a compatible admission fixture only; it does not supply this production
evidence. Phase 5 GitHub OIDC source provenance is verified, but it is neither an
image signature nor the SBOM/VSA evidence required for promotion.
