# Phase 8 — evidence integrity operational gate

**Status: runtime-verified (2026-09-21, local kind).** The PostgreSQL verifier
recomputes each projection-row hash and predecessor link. The postgres exporter
exposes ssdf_evidence_chain_tamper_detected; Prometheus evaluates it every 15
seconds and fires SsdfEvidenceTamperDetected when it is one.

Run scripts/phase4-bootstrap.sh first so Argo CD supplies the same Git revision,
then run scripts/phase8-bootstrap.sh --context kind-ln-ssdf-phase0 and
scripts/phase8-tamper-drill.sh --context kind-ln-ssdf-phase0
--confirm-local-tamper-drill. Both scripts fail closed unless the context,
running Docker control-plane, and every Kubernetes node identify as the local
ln-ssdf-phase0 kind cluster. The drill creates
a dedicated local fixture, bypasses its append-only trigger to model a manual
PostgreSQL mutation, proves verifier → metric → firing alert, then restores the
original fixture claim and waits for the firing alert to resolve.

The bootstrap performs a controlled Prometheus restart after Argo CD sync,
because the base Prometheus process does not watch mounted rule files. The
chart's Recreate strategy prevents two writers from opening the single TSDB PVC
during that restart. It also confirms the allowed Prometheus scrape of the
exporter and denied exporter-to-Prometheus egress; the policies are additive,
not a namespace-wide default deny.

The alert is visible in Prometheus only. No Alertmanager receiver or external
notification channel is configured, so this does not claim paging delivery.
Rekor remains authoritative for signed attestations: a database superuser who
rewrites an entire chain can defeat this local detector unless its signed
checkpoint is compared to Rekor.

Coverage is intentionally narrow: an update or predecessor-link mismatch is
detected; a database superuser who rewrites a complete chain, rolls the database
back, or deletes/replaces its external checkpoint is not. Rekor checkpoint
comparison is the compensating control still required for that attacker model.
