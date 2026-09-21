# Appendix B — current exceptions and bounded limitations

This local-kind evidence is deliberately not presented as a production
deployment.

| Scope | Current state | Bound / follow-up |
|---|---|---|
| Phase 5 keyless provenance | Partial | GitHub OIDC issuer, exact workflow identity, commit, and transparency-log bundle were verified in [run 35589420371](https://github.com/s1ns3nz0/ln-ssdf/actions/runs/35589420371). `main` branch protection is not configured or verified, and the proof is source provenance rather than image/SBOM/VSA evidence. |
| Phase 7 VSA enforcement | Explicitly held | All seven runtime images are digest-pinned but have no verified SBOM/VSA evidence; production Enforce remains disabled. |
| NetworkPolicy | Partial | The exporter→Postgres/DNS and Prometheus←Grafana paths are restricted and runtime-tested. There is no namespace-wide default deny: LND and bitcoind peer traffic need a separately tested policy design. |
| Evidence tamper alert | Local detection only | Prometheus fires and resolves the alert, but no Alertmanager receiver or paging integration is configured. Rekor checkpoint comparison is also not yet implemented. |
| Availability | Local single-node services | PostgreSQL, Prometheus, Grafana and Vault are single-instance local fixtures; this does not prove HA, backup RPO, or disaster recovery beyond the documented rebuild drills. |
| Local Git source | Test fixture only | The in-cluster Git daemon has no production authentication or remote SCM protections. |

Runtime bootstrap passwords and Vault recovery material are never committed.
The static-key/insecure-registry Experiment 1 fixture is a compatibility test,
not a substitute for the missing keyless evidence above.
