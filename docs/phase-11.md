# Phase 11 — node operations observability

Phase 11 adds a local single-replica Loki, Tempo, and OpenTelemetry Collector
to the Phase 3 Prometheus/Grafana base. Loki and Tempo use their own 5Gi PVCs;
their local retention is 72 hours. The Phase 3 chart now configures Prometheus
with `--storage.tsdb.retention.time=7d`.

Run after Phase 10 on the named local kind cluster:

```sh
scripts/phase11-bootstrap.sh --context kind-ln-ssdf-phase0
```

The local build reuses the Phase 10 Node image so a repeated kind rebuild does
not depend on another registry lookup. The gate installs `charts/phase11`, waits for Loki, Tempo, and the Collector,
adds three Grafana dashboards through Grafana's authenticated local API, and
sends a synthetic OTLP log containing a unique fake credential. It passes only
when Loki stores `[REDACTED]` and never the probe value. The script does not
print a Grafana password or a received log payload.

## Live metrics and current limit

The marketplace dashboard reads the counters Phase 9 actually emits:
`ti_product_authorized_accesses_total` and `ti_product_failures_total`. Phase 11
adds a Prometheus scrape of the TI product API and alerts on its failure ratio.
The Phase 9 challenge, settlement, and authorized-access sequence is verified
by its acceptance script against the LND ledger and stored as three redacted
database evidence records. It is **not** yet a continuous Prometheus L402
counter series; revenue, endpoint-level latency, and payment-anomaly panels
must remain absent until instrumented. This is a local observability slice,
not a claim that the full payment funnel is monitored continuously.

The Phase 3 chart mounts and evaluates the Phase 11 rules whenever the Phase 11
bootstrap enables the feature. ArgoCD owns that chart: the bootstrap creates
an ephemeral commit in the in-cluster Git mirror with the local Phase 11 chart
and `phase11.enabled=true`, then waits for ArgoCD to sync it. It does not change
the host `main` branch. The overlay must be replayed after rebuilding the
cluster. A separate NetworkPolicy admits only the Prometheus Pod to the TI API
port for scraping. Alertmanager has one local webhook receiver,
`operator-context`; it has no external receiver.

## Boundaries

The Collector accepts OTLP at `otel-collector.ssdf-system:4317` (gRPC) and
`4318` (HTTP), strips common credential-bearing fields, and redacts matching
text in log bodies before export. Services must still avoid placing seeds,
macaroons, preimages, Authorization/L402 values, OpenRouter keys, or raw TI
documents in telemetry; Collector filtering is a backstop, not permission to
emit sensitive data.

The bootstrap builds and loads the local `operator-context` MCP service. Its
only tool is `operator_context`, which allows a fixed metric allowlist and
returns bounded alert summaries, workload identity, error class, runbook step,
and trace ID. It cannot query Loki or Tempo, read Kubernetes resources, or
return Secrets, payment material, raw logs, or TI documents.

The bootstrap is replayable: when Grafana is absent it calls the Phase 3
bootstrap first, then builds and loads its local service image, applies its
manifest, and publishes the temporary GitOps chart overlay idempotently. Run the completed
Phase 0–10 rebuild sequence first when starting with an empty cluster. No
external paging, archive, backup, or HA is claimed.
