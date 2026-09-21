# Phase 3 — observability gate

The local stack uses Prometheus, Grafana, lndmon, and postgres-exporter. Grafana
is ClusterIP-only: anonymous access and sign-up are disabled, and its generated
administrator password stays in the Kubernetes `grafana-admin` Secret rather
than source control. Prometheus and Grafana each have a PVC so a pod reschedule
does not silently erase their local state.

Run:

```sh
scripts/phase3-bootstrap.sh --context kind-ln-ssdf-phase0
```

The gate passes only when the VSO-generated PostgreSQL credential contains just
`username` and `password`, all three deployments are ready, and Prometheus reports
`up == 1` for primary lnd, peer lnd, lndmon, and postgres-exporter. Container
readiness alone is not accepted as scrape evidence.

This establishes in-cluster collection and visualization plumbing; it does not
claim an external alerting, retention, or backup service. Those remain explicit
future gates until their own evidence exists.

After refreshing the Phase 1 Raft snapshots, the installation/recreation proof is:

```sh
scripts/phase1-backup.sh --context kind-ln-ssdf-phase0 --state-dir ABSOLUTE_PATH
scripts/phase3-rebuild-drill.sh --state-dir ABSOLUTE_PATH
```

The rebuild drill is intentionally destructive only to `ln-ssdf-phase0`. It
creates a new regtest chain and channel through the Phase 2 drill, then requires
the Phase 3 scrape gate again. It proves reproducible installation rather than
recovery of the deliberately destroyed regtest channel.
