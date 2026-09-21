# Phase 8 — evidence integrity operational gate

**Status: runtime-verified (2026-09-21, local kind).** The PostgreSQL verifier
recomputes each projection-row hash and predecessor link. The postgres exporter
exposes ssdf_evidence_chain_tamper_detected; Prometheus evaluates it every 15
seconds and fires SsdfEvidenceTamperDetected when it is one.

Run scripts/phase4-bootstrap.sh first so Argo CD supplies the same Git revision,
then run scripts/phase8-bootstrap.sh --context kind-ln-ssdf-phase0 and
scripts/phase8-tamper-drill.sh --context kind-ln-ssdf-phase0. The drill creates
a dedicated local fixture, bypasses its append-only trigger to model a manual
PostgreSQL mutation, proves verifier → metric → firing alert, then restores the
original fixture claim and waits for the firing alert to resolve.

The bootstrap performs a controlled Prometheus restart after Argo CD sync,
because the base Prometheus process does not watch mounted rule files. The
chart's Recreate strategy prevents two writers from opening the single TSDB PVC
during that restart.

The alert is visible in Prometheus only. No Alertmanager receiver or external
notification channel is configured, so this does not claim paging delivery.
Rekor remains authoritative for signed attestations: a database superuser who
rewrites an entire chain can defeat this local detector unless its signed
checkpoint is compared to Rekor.
