# LND / Vault dynamic PostgreSQL credential rotation handoff

Status on 2026-09-22: **the LND credential renewal and rotation fix passed a fresh Phase 0–8 rebuild and a bounded VSO lifecycle drill**. Phase 9–11 and the local Phase 12 approval gate also passed. The Phase 12 A2A AI call is limited by the external free-tier quota, so the whole AIOps path is not revalidated.

## What failed

The original `lnd-primary-0` process retained an old `DB_USERNAME`/`DB_PASSWORD` from a Kubernetes Secret-backed environment variable while VSO had already placed a new Vault-issued role in the Secret. The Pod's PostgreSQL role had expired. In addition, the live Vault `database/roles/lnd` had no `renew_statements`, so a renewed Vault lease did not extend PostgreSQL `rolvaliduntil`. A `Ready` Pod or VSO `Ready=True` was insufficient to detect this.

`postgres-exporter` had the same Secret-as-environment-variable pattern. It received the equivalent renewal SQL and rollout target.

## Source changes

- Commit `1300c4e` adds PostgreSQL `renew_statements` to the `lnd` and `postgres-observability` role definitions in `scripts/phase1-bootstrap.sh` and `scripts/phase1-rebuild-drill.sh`.
- The same commit adds VSO `rolloutRestartTargets` for `StatefulSet/lnd-primary` and `Deployment/postgres-exporter` in `manifests/phase1/vso-resources.yaml`.
- `gitops/applications/30-platform.yaml` ignores only VSO's `vso.secrets.hashicorp.com/restartedAt` Pod-template annotation on those workloads and sets `RespectIgnoreDifferences=true`, so Argo CD does not undo the restart. Other drift remains visible.
- `scripts/phase2-payment-drill.sh` now fails if the running LND role differs from the Secret or is expired in PostgreSQL.
- Commit `70e7148` adds `scripts/phase2-db-rotation-drill.sh`. It temporarily shortens the live `lnd` role TTL, checks automatic lease renewal extends PostgreSQL expiry, checks max-TTL rotation changes the Secret and restarts LND, restores normal TTL and a one-hour lease, then pays a 1,000-sat invoice. It prints no credential values. The same commit updates `docs/phase-1.md` and `docs/phase-2.md`.

## Evidence obtained

1. On the pre-rebuild cluster, an explicit Vault lease renewal advanced the same PostgreSQL role's `rolvaliduntil`; VSO Secret rotation restarted LND, and a post-restart payment succeeded.
2. On that cluster, the bounded VSO drill exited 0: VSO renewed the same 90-second role, PostgreSQL expiry advanced, VSO issued a new role near max TTL, LND restarted with the new Secret, and normal TTL was restored. A further payment succeeded after a normal one-hour lease was reissued.
3. `scripts/fresh-local-bootstrap.sh --confirm-recreate` deleted **only** `ln-ssdf-phase0`, created new Vault/chain/wallet/channel state, and passed Phase 0–8 from source at `1300c4e`. The existing `ln-ssdf-e1` cluster and old recovery material were preserved. New recovery material is under `/Users/s1ns3nz0/.local/state/ln-ssdf-vault-rotation-20260922-fresh` (outside Git, mode 0600 files).
4. On the freshly rebuilt cluster, the Phase 2 bidirectional payment drill passed, including the new DB-role checks. The live Vault role read showed 3600/7200-second TTL and the expected renewal statement. Argo CD's LND and VSO applications were Synced at `1300c4e`; both VSO rollout targets persisted.
5. On the fresh cluster, the new bounded drill exited 0 with: `VSO renewal extended the same PostgreSQL role expiry`, `VSO rotation issued a new role and restarted LND with it`, `Normal one-hour lease restored and LND restarted ready`, and `Post-rotation LND payment settled`.
6. Phase 9 cached-image deployment and 10-sat L402 payment acceptance passed. Phase 10 source build and AgentGateway live gate passed. Phase 11 Loki/Tempo/Collector and redaction gate passed. Phase 12 local contract, approved Kubernetes restart, kagent readiness, and Argo CD-owned alert routing passed. The A2A acceptance failed because OpenRouter returned HTTP 429 `free-models-per-day`; no new pending request was created. No paid credits were added or model/provider changed.
7. After these later phases, the running LND and exporter usernames still matched their respective Secrets, both PostgreSQL roles were unexpired, and a further 1,000-sat LND payment succeeded. Argo CD kept the VSO targets present.

These checks prove the local LND credential path across renewal and rotation, including after a fresh install and after the later-phase deployments above. They do not prove a complete Phase 12 AI/A2A path or that the setup runs unattended for days. A transient `client token expired` VSO log was observed before the fix, but VSO subsequently reauthenticated and issued new leases; long-duration observation should watch for recurrence.

## Next steps

1. When the OpenRouter free-model daily quota resets, rerun the Phase 12 A2A acceptance and related AIOps gate. Do not purchase credits or change provider/model without user direction.
2. Preserve the unrelated edit in `services/evidence-dashboard/model.mjs`. The scoped fix and drill are committed locally; do not push unless requested. `bash -n`, ShellCheck on the new drill, `git diff --check`, and the fresh-cluster drill passed. The older scripts have existing ShellCheck SC2016 notices for intentional in-container variable expansion; `shellcheck -e SC2016` passed across the edited shell scripts.
3. Observe at least one normal one-hour VSO renewal and later max-TTL rotation if claiming long-duration readiness. Inspect the running Pod username, current Secret username, PostgreSQL `rolvaliduntil`, VSO events, and a post-rotation LND RPC/payment. The bounded short-TTL drill already covers the mechanism but not prolonged operation.
4. Consider removing the network dependency in `charts/lnd/templates/statefulset.yaml`: the `fetch-lndinit` init container downloaded a pinned release archive on each restart and took about a minute on the fresh cluster. This did not fail the drill, but could delay rotation recovery if the release endpoint is unavailable.

Official API references: [Vault PostgreSQL renewal SQL](https://developer.hashicorp.com/vault/api-docs/secret/databases/postgresql), [VSO rollout restart targets](https://developer.hashicorp.com/vault/docs/deploy/kubernetes/vso/api-reference), [Argo CD ignored differences during sync](https://argo-cd.readthedocs.io/en/latest/user-guide/sync-options/).
