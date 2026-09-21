# Phase 9: paid threat-intelligence product API and buyer

This phase adds a deliberately small local regtest slice. `ti-product-api` is a
read-only Rust API over a pinned public STIX 2.1 fixture. It has only indicator
(10 sat), campaign (25 sat), and report (50 sat) product routes. Pinned
Aperture is the L402 payment boundary: it issues seller (`lnd-primary`) invoices
and validates route-bound, five-minute credentials before requests reach the API.

`payment-buyer` is the only workload that receives a payment-only
`lnd-peer` macaroon. It accepts only those three GET route families, rejects
amountless or over-50-sat invoices, limits a process run to 100 sats and a UTC
day to 200 sats, uses a one-at-a-time lock, sets a one-sat routing-fee limit,
and makes exactly one credential retry. It does not log or emit invoices,
macaroons, Authorization values, raw TI responses, seeds, or preimages.

The buyer trusts only its mounted `lnd-peer` TLS certificate for LND REST. It
uses vendored native TLS because LND's generated self-signed certificate is
CA-capable and Rustls/WebPKI rejects that certificate shape as a server leaf.
Hostname and certificate verification remain enabled; there is no insecure TLS
fallback.

## Local installation and acceptance

Run the full [Phase 0–8 fresh local bootstrap](../scripts/fresh-local-bootstrap.sh)
first; this creates the required named kind context, Vault/VSO, regtest LND
pair, and Phase 8 evidence chain. The state directory is the external Phase 1
recovery-material directory created by that command:

```bash
scripts/phase9-bootstrap.sh --context kind-ln-ssdf-phase0 --state-dir /absolute/state-dir
```

The bootstrap creates a fresh `offchain:read`, `offchain:write` macaroon inside `lnd-peer`,
copies it directly to the buyer's Kubernetes Secret, and removes the temporary
in-pod file. It also bakes `lnd-primary`'s invoice-only macaroon
(`invoices:read`, `invoices:write`), stores it in Vault KV, and lets VSO project
it only into Aperture in the same `ssdf-system` namespace. The pinned Aperture
deployment protects the exact three route families and forwards only to
`ti-product-api.opencti-system.svc:8080`.

The deployable resources are [Phase 9 runtime](../manifests/phase9/runtime.yaml)
and [network policies](../manifests/phase9/network-policies.yaml). The minimal,
public STIX 2.1 fixture is the `phase9-public-stix-2.1` ConfigMap in the runtime
manifest; it contains no private TI source or credential.

The published Aperture v0.5.0 image digest
`sha256:29e03e2c38dca0314f748cc07f483f03615dbf9876620c8e15b94b904fa16114`
has no arm64 manifest. The bootstrap instead builds the exact v0.5.0 upstream
source commit `311220b15b04c06ecabd52c78fde8f5d6ea73c82` locally and loads that
image into kind; it never pushes an image.

`offchain:read` is limited to reconciling a just-submitted payment by its BOLT11
payment hash after an ambiguous streaming response. The buyer never retries an
unresolved invoice and records that condition as pending rather than failed.

Then run the real drill against that proxy:

```bash
scripts/phase9-acceptance.sh --context kind-ln-ssdf-phase0 \
  --subject threat-research-buyer
```

Successful output contains exactly three redacted JSON records, in order:
`challenge`, `settlement`, `authorized_access`. Each has only `event`,
`subject`, `outcome`, `endpoint`, `amount_sat`, and `correlation_id`. Before
writing them to the evidence chain, the acceptance script normalizes successful
records to `payment-buyer`, `passed`, a product name, and a fresh 32-hex-digit
correlation ID. Caller-selected subjects, lookup paths, and buyer correlations
are not durable evidence.

Before normalization, the buyer protocol must contain exactly `challenge`
(`received`), `settlement` (`settled`), and `authorized_access` (`authorized`),
each for 10 sats with the caller-selected subject and a single shared
correlation ID. Any additional line or mismatch is rejected without evidence
write.

Before appending evidence, the acceptance gate independently verifies that
`lnd-peer` has exactly one new 10-sat `SUCCEEDED` payment and that the protected
TI API's authorized-access counter, read from the Aperture pod, increased by
exactly one. If either read is unavailable or mismatches, no evidence is
appended. This avoids treating buyer stdout as proof of settlement or access.

## Metrics contract

Phase 9 uses safe counters only. The product API exports
`ti_product_authorized_accesses_total` and `ti_product_failures_total`; the
payment boundary/evidence recorder must export `l402_challenges_total`,
`l402_settlements_total`, `l402_authorized_accesses_total`, and
`l402_failures_total`, each labelled only with the fixed route product name
(`indicator`, `campaign`, or `report`) and failure class where applicable.
No metric label may contain a subject, correlation ID, document, credential,
invoice, or preimage.

## OpenCTI integration status

This repository does **not** yet bootstrap OpenCTI and its Elasticsearch,
Redis, object-storage, and worker dependencies. Consequently its default local
source is a pinned public STIX 2.1 fixture and Phase 9 is partial with respect
to the planned `TI API -> OpenCTI GraphQL` hop. The Rust API has an adapter for
a real deployment: set `OPENCTI_GRAPHQL_URL` and mount the API token at the
path named by `OPENCTI_API_TOKEN_FILE`. The token is read only by the API,
never logged or made a metric label. This phase makes no mainnet, testnet, MPP,
session-mode, or production availability claim.
