# Phase 9–12: AI-native TI marketplace and operations plan

## Goal

Extend the completed Phase 0–8 local regtest environment with a paid threat
intelligence API, agent-mediated purchases, gateway policy, and a deliberately
bounded AIOps workflow. Every phase remains local-kind first, reproducible, and
separate from the Phase 0–8 mandatory bootstrap.

## Non-negotiable boundaries

- `lnd-primary` is the seller; `lnd-peer` is the buyer.
- The official acceptance environment is regtest. Testnet and mainnet are out
  of scope.
- L402 is the only paid-API protocol in this plan. Neither Lightning
  multi-path payment experiments nor Aperture Payment-HTTP MPP/session mode are
  implemented or claimed.
- All agent-originated LLM and tool traffic goes through AgentGateway. Network
  policy blocks direct egress from kagent workloads.
- No workload other than the narrow payment backend receives a wallet-related
  credential. AgentGateway never receives an LND macaroon, seed, preimage, or
  OpenCTI API key.
- Metrics, logs, and traces never retain seeds, macaroons, payment preimages,
  Authorization headers, complete L402 credentials, OpenRouter keys, or raw TI
  responses.

## Phase 9 — paid TI API and AI buyer

### Runtime

```text
kagent threat-research-buyer
  -> payment-aware MCP tool
  -> AgentGateway
  -> Aperture
  -> Rust TI product API
  -> OpenCTI GraphQL

lnd-peer -> Lightning payment -> lnd-primary
```

- OpenCTI and its dependencies are an optional `opencti-system` namespace.
  It receives only version-pinned public STIX 2.1 fixtures.
- Aperture protects three read-only product endpoints: indicator (10 sats),
  campaign (25 sats), and report (50 sats).
- A completed L402 grants endpoint-bound access for five minutes. Grafana
  reports paid transactions separately from authorized accesses.
- The Rust MCP payment tool alone performs `402 -> invoice -> lnd-peer payment
  -> credential retry`. The LLM decides what to query but cannot inspect a
  wallet or credential.
- Buyer policy: max 50 sats/request, 100 sats/run, 200 sats/day, one concurrent
  payment, allowlisted read endpoints, and at most one retry with a new invoice.
- Local service images are built and loaded with `kind load docker-image`; no
  registry is required for the local acceptance path.

### Acceptance

1. The buyer agent selects an allowlisted TI lookup.
2. The first request receives HTTP 402.
3. `lnd-peer` settles the seller invoice.
4. The bounded credential retry returns HTTP 200.
5. A redacted structured record and metrics identify challenge, settlement, and
   authorized access without retaining a bearer credential or preimage.

## Phase 10 — AgentGateway L402 contribution

- Work in a dedicated AgentGateway fork and follow its Rust, schema, security,
  formatter, clippy, and integration-test conventions.
- Add the smallest useful native HTTP-route L402 policy. It owns route/method
  caveats, timeouts, failure behavior, correlation, and telemetry.
- Invoice issuance and macaroon validation remain delegated to an
  Aperture-compatible payment backend. This prevents gateway ownership of LND
  credentials.
- Deploy AgentGateway first as the OpenAI-compatible egress proxy for kagent to
  OpenRouter, then route the TI purchase path through it as well.
- OpenRouter is configured as a BYO OpenAI-compatible provider. Its API key is
  stored in Vault and injected only into AgentGateway. Free models only; model
  selection is configuration, not hard-coded application logic.
- Before an upstream PR: run the upstream-required formatter, clippy, schema
  validation, focused integration tests, and full relevant test suite.

## Phase 11 — node operations observability

### Stack and data handling

- Prometheus and Grafana remain the metrics base.
- Add Loki, Tempo, and one OpenTelemetry Collector.
- Retention: metrics 7 days; logs and traces 72 hours; each new local store
  starts with a 5Gi PVC. No long-term archive or backup is claimed.
- LND/Bitcoind contribute existing metrics and redacted structured logs.
  Aperture, TI API, payment tool, AgentGateway, and remediation controller emit
  OpenTelemetry traces.
- An internal `operator-context` MCP service returns summaries only: alert,
  metric values, pod/deployment identity, error class, runbook step, and trace
  ID. It never returns raw logs, Secrets, payment material, or TI documents.

### Grafana and alerting

- `Node Operations / Overview`: node health, liquidity, paid API health, and
  critical alerts.
- `Node Operations / L402 Marketplace`: 402 challenges, settlements,
  authorized access, revenue, failure reasons, and latency by endpoint.
- `Node Operations / Service Investigation`: trace-linked, redacted logs and
  service investigation.
- Alertmanager sends to a local webhook receiver only. Initial alerts cover
  chain/peer/channel health, liquidity below 100,000 sats, L402 failure rate,
  TI API 5xx or p95 latency, OpenCTI upstream failures, and telemetry export or
  redaction failures.
- Initial objectives: 95% API and settlement success over 15 minutes, API p95
  below 2 seconds, and immediate alerts for chain-sync loss or zero active
  peer/channel.
- Detection-only anomaly signals: repeated unpaid 402 challenges for a
  pseudonymous client hash, payment failure spikes, anomalous authorized-access
  to paid-transaction ratio, and invalid/expired/wrong-endpoint credentials.

## Phase 12 — kagent AIOps and controlled chaos

- Use kagent 0.x stable with an OpenRouter free model through AgentGateway.
- An alert starts a read-only diagnosis with at most three reasoning/tool rounds
  and one concurrent run. Failure becomes `NeedsHuman`.
- The agent proposes a typed `RemediationRequest`; it cannot act without
  `spec.approved: true` from the operator.
- A restricted remediation controller may restart Aperture, the TI API, the
  OTel Collector, or an OpenCTI application service, and may roll back only a
  declared Helm release. It cannot execute arbitrary shell, read Secrets,
  restart LND/Bitcoind/Vault/Postgres, modify channels, or change RBAC/network
  policy.
- First recovery drill: deploy a deliberately faulty TI API Helm revision,
  trigger the API SLO alert, diagnose from the runbook, approve the request,
  roll back, and prove recovery through metrics, logs, traces, and evidence.
- Optional Chaos Mesh experiments run in `chaos-testing` only: TI API pod
  failure and TI API-to-OpenCTI latency/failure. LND, Bitcoind, Vault, and
  Postgres are prohibited targets.

## Evidence

Phase 9–12 acceptance, redaction, alert, remediation approval/execution, and
chaos drill outcomes are appended to the existing evidence chain. Each record
references the pinned fixture or release revision and redacted correlation IDs,
not secret material.
