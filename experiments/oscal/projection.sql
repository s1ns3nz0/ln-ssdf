CREATE TABLE IF NOT EXISTS oscal_requirement_projection (
  assessment_result_uuid uuid NOT NULL,
  requirement_id text NOT NULL,
  status text NOT NULL CHECK (status IN ('satisfied', 'not_satisfied', 'no_evidence', 'not_implemented', 'not_applicable')),
  policy_name text NOT NULL,
  source_document text NOT NULL,
  evaluated_at timestamptz NOT NULL,
  PRIMARY KEY (assessment_result_uuid, requirement_id, policy_name)
);

INSERT INTO oscal_requirement_projection
  (assessment_result_uuid, requirement_id, status, policy_name, source_document, evaluated_at)
VALUES
  ('d5df5532-94c5-4c7a-9ff2-5570909335ea', 'DEPLOY-REQ-4', 'satisfied',
   'experiment-1-require-sbom-and-vsa', 'experiments/oscal/c2p-assessment-results-linked.json',
   '2026-09-21T06:15:10Z')
ON CONFLICT (assessment_result_uuid, requirement_id, policy_name) DO UPDATE
SET status = EXCLUDED.status, source_document = EXCLUDED.source_document, evaluated_at = EXCLUDED.evaluated_at;
