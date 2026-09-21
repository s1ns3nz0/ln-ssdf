# Appendix B — current exceptions and bounded limitations

This local-kind evidence is deliberately not presented as a production
deployment.

| Scope | Current state | Bound / follow-up |
|---|---|---|
| Phase 5 keyless provenance | Complete for source provenance | `main` requires `Repository verification`; the OIDC identity, exact workflow, commit, run ID, and transparency-log bundle were independently verified in [run 35591393479](https://github.com/s1ns3nz0/ln-ssdf/actions/runs/35591393479). This is source provenance, not image/SBOM/VSA evidence. |
| Phase 7 VSA enforcement | Explicitly held | All seven digest-pinned images have keylessly signed SBOM/VSA evidence from [run 35591049749](https://github.com/s1ns3nz0/ln-ssdf/actions/runs/35591049749), but each VSA is `FAILED` under the configured vulnerability policy. Production Enforce remains disabled pending compatible remediated images and fresh passing evidence. |
| NetworkPolicy | Partial | The exporter→Postgres/DNS and Prometheus←Grafana paths are restricted and runtime-tested. There is no namespace-wide default deny: LND and bitcoind peer traffic need a separately tested policy design. |
| Evidence tamper alert | Local detection only | Prometheus fires and resolves the alert, but no Alertmanager receiver or paging integration is configured. Rekor checkpoint comparison is also not yet implemented. |
| Availability | Local single-node services | PostgreSQL, Prometheus, Grafana and Vault are single-instance local fixtures; this does not prove HA, backup RPO, or disaster recovery beyond the documented rebuild drills. |
| Local Git source | Test fixture only | The in-cluster Git daemon has no production authentication or remote SCM protections. |

Runtime bootstrap passwords and Vault recovery material are never committed.
The static-key/insecure-registry Experiment 1 fixture is a compatibility test,
not a substitute for the missing keyless evidence above.
