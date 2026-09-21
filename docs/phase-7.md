# Phase 7 — image evidence enforcement readiness

**Status: diagnostic gate passed; production vulnerability Enforce remains
disabled.** The seven runtime images in `ssdf-system` are digest-pinned and
covered by Phase 6 Audit.
On 2026-09-21, [run 35591049749](https://github.com/s1ns3nz0/ln-ssdf/actions/runs/35591049749)
generated and keylessly signed CycloneDX SBOM and VSA attestations in the
dedicated GHCR evidence repository. Independent Cosign verification confirmed
the GitHub OIDC identity and transparency-log proof. All seven VSAs are
`FAILED` under the former vulnerability-blocking profile. The portfolio now
uses the explicitly documented `diagnostic` profile: scan completeness, SBOM
binding, keyless identity, transparency-log proof, and VSA freshness are the
gate; fixed High/Critical and unfixed Critical findings remain in signed
`observedFindings` rather than silently disappearing. The stricter `enforce`
profile remains available for an environment that intends vulnerability-based
deployment denial.

All seven current VSA attestations were independently verified with the exact
GitHub Actions OIDC identity and transparency-log proof, then promoted to
`verified` in the inventory. The workflow reissues the evidence daily, within
the 48-hour VSA lifetime.

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

`measure-upstream-scorecards.yml` separately measures the two agreed source
repositories, `lightningnetwork/lnd` and `lightninglabs/aperture`, daily and on
manual dispatch. Each result is a retained JSON artifact. Scorecard is a source
posture measurement; it does not make an image VSA pass and does not expand the
runtime-image evidence scope to aperture before it is deployed.

The initial measurement, [run 35591904489](https://github.com/s1ns3nz0/ln-ssdf/actions/runs/35591904489), completed on 2026-09-21. It reported 5.8/10 for
`lightningnetwork/lnd` and 4.7/10 for `lightninglabs/aperture`. These are
time-bound upstream observations, not ln-ssdf compliance verdicts; the retained
JSON artifacts contain the full check-level reasons.
