# Phase 7 — image evidence enforcement readiness

**Status: explicitly held; no production Enforce promotion.** The seven
runtime images in `ssdf-system` are digest-pinned and covered by Phase 6 Audit.
On 2026-09-21, [run 35591049749](https://github.com/s1ns3nz0/ln-ssdf/actions/runs/35591049749)
generated and keylessly signed CycloneDX SBOM and VSA attestations in the
dedicated GHCR evidence repository. Independent Cosign verification confirmed
the GitHub OIDC identity and transparency-log proof. All seven VSAs are
`FAILED`, however, because the current scanner found policy-blocking findings;
the versioned inventory records the per-image count. A signed failed VSA is
evidence to block deployment, not a promotion ticket.

`scripts/phase7-readiness.sh --context kind-ln-ssdf-phase0` compares the live
Pod image set to that inventory and exits with status 3 while an entry remains
unverified. It exits 1 if an unreviewed image appears. Both outcomes block
promotion and make missing evidence visible rather than silently treating it as
an allow-list match.

Promotion requires, per image: a signed CycloneDX SBOM, a passing and unexpired
VSA whose input-attestation digest refers to that exact SBOM, trusted issuer
identity, and transparency-log verification. The local static-key experiment
proves a compatible admission fixture only; it does not supply this production
evidence. Current remediation requires compatible image upgrades followed by a
fresh scan and VSA. Phase 5 GitHub OIDC source provenance is verified, but it is
neither an image signature nor the SBOM/VSA evidence required for promotion.
