# Phase 12 — bounded AIOps and controlled chaos

Phase 12 is a local, approval-gated recovery slice. The controller diagnoses
only from a small, redacted observation summary and a declared runbook. It does
not execute shell commands, inspect Secrets, read raw logs, handle payment
credentials, or delegate an arbitrary tool call to an agent.

## Contract

`RemediationRequest` is a typed `aiops.ln-ssdf.io/v1alpha1` resource. The only
actions are `restartDeployment` for `aperture`, `ti-api`, `otel-collector`, or
`opencti-application`, and `rollbackHelmRelease` for the declared `ti-api`
release. A request is created pending approval. A ValidatingAdmissionPolicy
rejects approved-on-create requests and freezes the complete spec after
approval. The controller service account can read requests and patch only
status; it cannot patch request approval. The separate approver Role is the
only Phase 12 permission intended to patch approval.

The controller reconciles approved requests from the Kubernetes API. Restarts
are merge patches to an allowlisted Deployment template annotation. Rollback
uses the Kubernetes Apps API to copy the immediately previous allowlisted
Deployment revision; it does not run shell commands or a user-supplied Helm
command.

The RBAC manifests grant only `get` and `patch` on named Deployments/Helm
resources. They grant no Secret, Pod exec, LND, Bitcoind, Vault, Postgres,
RBAC, NetworkPolicy, channel, or arbitrary workload access. Diagnosis is capped
at three rounds; unknown alerts and exhausted diagnosis become `NeedsHuman`.

Each diagnosis/remediation response emits a redacted JSON evidence event with
the shared fields `event`, `subject`, `outcome`, `endpoint`, `amount_sat`, and
`correlation_id`. Approval evidence additionally carries only the operator
identity and target/action. No request body or secret material is emitted.

## kagent and alert path

`manifests/phase12/kagent-aiops.yaml` targets kagent 0.x `v1alpha2` resources.
The `phase12-aiops` agent uses the OpenAI-compatible
`phase10-agentgateway` Service with the local Ollama `gpt-oss:20b` model.
Phase 10 checks the host Ollama endpoint; no provider credential is needed.
The agent can inspect only the redacted operator-context MCP tool
and the controller's bounded diagnosis/proposal MCP tools. Creating a pending
proposal creation is allowed to produce only a pending Kubernetes request; the
resulting request still requires a separate RBAC-authorized operator approval
before any controller action.

kagent 0.6.3 requires a non-null Helm `providers.default` during chart
rendering. The bootstrap supplies a no-secret OpenAI-compatible provider entry
pointing at AgentGateway; the Phase12 `ModelConfig` remains the resource used by
the agent. The required nonempty client key is a public placeholder, not a credential.

Run Phase 10 first so it configures the Ollama route, then prepare kagent:

```sh
scripts/phase12-kagent-bootstrap.sh --context kind-ln-ssdf-phase0 --confirm-local-kagent
scripts/phase12-alertmanager-bootstrap.sh --context kind-ln-ssdf-phase0 --confirm-local-alert-routing
```

The Phase 12 bootstrap only checks Secret existence and never prints or reads
its value. The alert-routing script publishes a temporary combined Phase 11 +
Phase 12 chart revision to the in-cluster Git server and waits for ArgoCD to
sync it; it does not patch the live ConfigMap. Alertmanager sends the two
Phase 11 TI API alerts, `TiProductFailureRateHigh` and
`TiApiAvailabilityLow`, plus the Phase12-overlay `TiApiScrapeDown` rule to the
controller, which forwards a bounded
sanitized task to the kagent A2A endpoint. The webhook acknowledges immediately;
the controller enforces one in-flight diagnosis and a 90-second background
deadline so a slow free-model response does not block Alertmanager delivery.

The live-loop audit is: Phase 11/Phase12 rule → ArgoCD-owned Alertmanager route →
bounded controller alert allowlist → kagent A2A dispatch → newly created pending
RemediationRequest → RBAC-authorized operator approval → controller Kubernetes
API action → status and six-field evidence. The verified local evidence is one
synthetic `TiApiAvailabilityLow` path and
the real Chaos-triggered `TiApiScrapeDown` path. The TI API-only pod-failure
and latency drills recovered locally; no real `TiProductFailureRateHigh`,
latency-to-alert/AIOps, or OpenCTI-upstream alert is claimed.

The primary live acceptance explicitly opts into approval only after the real
Chaos-driven path has produced a new pending request and the Chaos drill has
recovered:

```sh
scripts/phase12-aiops-acceptance.sh --context kind-ln-ssdf-phase0 \
  --confirm-local-aiops --confirm-local-approval
```

This requires the Phase12 Alertmanager overlay, kagent, controller, and Chaos
Mesh to be installed. This mode creates only the scoped
`phase12-aiops-operator` ServiceAccount/RoleBinding, approves only the newly
detected pending request, and verifies `Succeeded`, the matching TI API
`ln-ssdf.io/last-remediation` correlation annotation, operator/target/action
approval evidence, and the six-field redacted remediation evidence. It does not
approve preexisting requests.

To observe the same real trigger path without approval or execution, omit the
approval flag:

```sh
scripts/phase12-aiops-acceptance.sh --context kind-ln-ssdf-phase0 --confirm-local-aiops
```

## Chaos Mesh drill

`manifests/phase12/chaos-pod-failure.yaml` and
`manifests/phase12/chaos-latency.yaml` define the two experiments: a 90-second
TI API pod failure and a 120-second TI API network delay. Both selectors are
fixed to `opencti-system` and `app=ti-product-api`; no LND, Bitcoind, Vault,
Postgres, kagent, or controller selector is present.

The drill first installs or upgrades the pinned Chaos Mesh 2.7.2 Helm release,
including its CRDs, controller manager, and daemon. The installer explicitly
configures the daemon for kind's containerd runtime at
`/run/containerd/containerd.sock`; the chart's Docker defaults are not valid for
kind. It then runs one experiment at a time:

```sh
scripts/phase12-chaos-drill.sh --context kind-ln-ssdf-phase0 \
  --experiment pod-failure --confirm-local-chaos
scripts/phase12-chaos-drill.sh --context kind-ln-ssdf-phase0 \
  --experiment latency --confirm-local-chaos
```

## Local acceptance

Run:

```sh
scripts/phase12-local-drill.sh
  node --test tests/phase12-controller.test.mjs
  scripts/phase12-kind-acceptance.sh --context kind-ln-ssdf-phase0 --confirm-local-approval
```

The local contract drill does not contact a cluster or third party. The kind
acceptance builds and loads the image, applies the CRD/admission/RBAC policy,
creates a pending request, approves it through a dedicated operator Service
Account, and proves an actual allowlisted Kubernetes API restart. The verified
real local gate has also exercised Chaos Mesh → Prometheus → Alertmanager →
kagent → pending request → scoped operator approval → controller action; the
TI API-only pod-failure and latency drills both recovered. These are local
verification results, not a production reliability claim.

The separate synthetic alert/A2A gate is optional. It assumes those owned
bootstraps have already run and does not install or change charts, controller
manifests, or chaos resources:

```sh
scripts/phase12-a2a-e2e-acceptance.sh --context kind-ln-ssdf-phase0 \
  --confirm-local-a2a-acceptance
```

It posts one bounded synthetic `TiApiAvailabilityLow` alert to Alertmanager,
waits for a newly created unapproved A2A proposal, approves only that resource
through a scoped ServiceAccount, verifies the actual `ti-product-api` restart
annotation, and appends the controller's six-field redacted evidence event.
Its free-model dependency makes response time and proposal completion variable;
it is not deterministic and is not required for the real Chaos-driven gate.
