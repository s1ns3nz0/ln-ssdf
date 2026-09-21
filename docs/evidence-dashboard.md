# SSDF posture dashboard

The public dashboard is a read-only synthetic demonstration of NIST SSDF
posture for lnd and aperture. It is not an operational compliance
determination.

## Catalog and fixture contract

The fixture vendors the official NIST SP 800-218 OSCAL Catalog from
usnistgov/oscal-content release v1.5.0 at commit
78650f02ad9321bb7b817846f8fbd4f2bcd620de. The vendored minified Catalog has
SHA-256 5ec118109d7fca45785ed6cdad23e46bfc6dfb91cc23fd7140b702582f9da766
and contains all 42 SSDF tasks under PO, PS, PW, and RV.

Regenerate the source only with the pinned hash-verifying script:

    node scripts/vendor-nist-ssdf-catalog.mjs

Every non-Catalog artifact is deterministic synthetic data at scenario time
2026-09-21T12:00:00Z. The UI labels this boundary continuously.

## UI and API

The left rail is Overview, PO, PS, PW, RV. The center pane defaults to All
projects and provides Project, Scope, Implementation, Evidence freshness, and
search filters. The right inspector separates the implementation record from
scenario posture and provides Posture, Implementation record, Evidence,
Remediation, and Requirement source tabs. The demo boundary appears in the
top bar. Storage and Jira references are simulated; evidence links serve the
complete internal mock JSON records. Task rows show a short requirement summary,
status counts, and an action marker only when remediation is active. The
inspector keeps record links and assessment history collapsed until requested.

Each control's synthetic records include a linked requirement scope, system
implementation, assessment plan and results, and, when needed, a remediation
plan and Jira-style issue. The JSON includes stable identifiers, timestamps,
owners, findings, and simulated object keys. These are OSCAL-style examples,
not validated operational assessments. A remediation plan and Jira issue exist
only for Blocked, Partial, or Not Implemented scenario posture; assessment
findings are retained for every posture, including Passed.

The read-only API exposes:

- GET /lnd/api/health for service mode and scenario time.
- GET /lnd/api/dashboard for the full public posture projection.
- GET /lnd/api/controls/:taskId for both project details of one SSDF task.
- GET /lnd/api/raw/catalog for the vendored official source document.
Only the official Catalog source opens externally. Mock SSP, Assessment,
OpenTelemetry, and POA&M artifacts remain inside the dashboard as raw JSON.

## Local preview and OCI

Build a native ARM64 image for Oracle Cloud A1:

    docker buildx build --platform linux/arm64 -t ln-ssdf-evidence-dashboard:fixture-arm64 --load services/evidence-dashboard

The public container remains fixture-only behind the existing reverse proxy at
/lnd. Do not give it a database URL or replace synthetic artifacts with
operational evidence.
