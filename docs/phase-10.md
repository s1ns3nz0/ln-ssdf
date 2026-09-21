# Phase 10: AgentGateway L402 local integration

Phase 10 provides a local-kind integration of AgentGateway with an
Aperture-compatible L402 backend. It is local-only: no AgentGateway fork was
created, and no upstream push or pull request is claimed.

```text
kagent -> AgentGateway -> phase10 L402 adapter -> Aperture -> TI API
           /v1 -> OpenRouter             /v1 -> L402-protected endpoints
```

## Native policy and adapter boundary

`integrations/agentgateway/native-l402.patch` is a native Rust AgentGateway
patch pinned to upstream commit `91182a58528fee5dd8d6f86906716281d8c45c3f`.
It adds the route-level `l402` policy with configured method/path caveats and a
generated correlation header. It does not parse, mint, log, or persist an L402
credential. The selected Aperture backend still issues `402` challenges and
validates authorized retries.

The Node adapter remains part of the integration boundary. It permits only the
configured TI GET paths, proxies L402 challenge and retry headers unchanged,
adds `x-phase10-correlation-id`, and returns redacted backend failures. It has
no LND macaroon, seed, preimage, OpenRouter key, or OpenCTI key.

## Build and deploy locally

```bash
scripts/phase10-build-local.sh --context kind-ln-ssdf-phase0
scripts/phase10-bootstrap.sh --context kind-ln-ssdf-phase0
```

The build script creates a temporary checkout of the pinned upstream commit,
applies the native patch, builds `phase10-agentgateway:local` with the Phase 10
headless Dockerfile, and loads it along with `phase10-l402-adapter:local` into
kind. The headless build compiles only the `agentgateway-app` binary with
the upstream `quick-release` profile and
`--no-default-features --features jemalloc,crypto-aws-lc`; it does not build the
upstream UI. Set
`AGENTGATEWAY_PHASE10_CHECKOUT` only to use an already prepared equivalent
checkout. Both Deployments use `imagePullPolicy: Never`.

Bootstrap creates the `phase10-system` namespace, then creates or updates the
`phase10-openrouter` Secret, and only afterward applies the Phase 10 manifest.
It reads the authorized root `.env` variable `LLM_MODEL_API` without printing,
staging, or writing its value to source. The Secret is injected only into the
AgentGateway container; the adapter receives no provider credential.

The Phase 10 route configuration sends `/v1/` OpenAI-compatible traffic to
OpenRouter and `/ti/` traffic through native `l402` caveats, rewrites it to
the adapter's `/v1/` endpoint, and then reaches Aperture at
`aperture.ssdf-system.svc:8080`. NetworkPolicies permit the adapter-to-Aperture
path, DNS, and AgentGateway TLS egress to OpenRouter.

## Verification

```bash
scripts/phase10-test.sh
scripts/phase10-acceptance.sh --context kind-ln-ssdf-phase0
kubectl apply --dry-run=client -f manifests/phase10/l402-adapter.yaml
```

The focused proxy test proves `402 -> authorized retry`, route/method rejection
before the backend, timeout redaction, health behavior, and invalid-config
rejection. The native patch was validated in the dedicated local AgentGateway
checkout with formatter, `cargo check -p agentgateway`, clippy with warnings as
errors, schema generation, and the focused `l402` Rust test.

## Live gate

Run the live gate only after the coordinated Phase 0-9 fresh rebuild confirms
that Aperture is healthy at `aperture.ssdf-system.svc:8080`. Then build, load,
and bootstrap Phase 10; verify both deployments become Ready; and exercise an
allowlisted `/ti/` request through AgentGateway to observe the L402 `402`
challenge and reject an unallowlisted route. Phase 9 separately verifies one
authorized retry and settlement against the LND ledger; the Phase 10 live gate
does not claim that the buyer itself routes through AgentGateway. Do not treat a local image, Secret,
or adapter deployment as an upstream release or production deployment.
