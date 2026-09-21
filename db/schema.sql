-- ln-ssdf Phase 0 evidence projection schema.
-- Rekor remains the authority for attestations and signed checkpoints; this
-- database is an append-only operational projection, not an authority store.

CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TYPE ssdf_track AS ENUM ('first_party', 'third_party');
CREATE TYPE ssdf_status AS ENUM (
  'satisfied', 'not_satisfied', 'not_implemented', 'not_applicable', 'no_evidence'
);
CREATE TYPE evidence_kind AS ENUM (
  'sbom', 'vulnerability_report', 'vsa', 'signature', 'provenance',
  'scorecard', 'argocd_observation', 'policy_report', 'approval_bundle'
);

CREATE TABLE requirements (
  requirement_id text PRIMARY KEY,
  title text NOT NULL,
  track ssdf_track NOT NULL,
  required boolean NOT NULL DEFAULT true,
  source_uri text NOT NULL,
  source_version text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE requirement_practices (
  requirement_id text NOT NULL REFERENCES requirements(requirement_id),
  practice_id text NOT NULL,
  PRIMARY KEY (requirement_id, practice_id)
);

CREATE TABLE evidence (
  evidence_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  kind evidence_kind NOT NULL,
  track ssdf_track NOT NULL,
  subject_kind text NOT NULL,
  subject_ref text NOT NULL,
  issuer text NOT NULL,
  source_uri text NOT NULL,
  observed_at timestamptz NOT NULL,
  evaluated_at timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz,
  policy_version text NOT NULL,
  claim jsonb NOT NULL,
  previous_hash bytea,
  row_hash bytea NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (kind, subject_ref, source_uri, observed_at)
);

CREATE INDEX evidence_subject_idx ON evidence (subject_ref, observed_at DESC);
CREATE INDEX evidence_expiry_idx ON evidence (expires_at) WHERE expires_at IS NOT NULL;

CREATE TABLE evidence_links (
  evidence_id uuid NOT NULL REFERENCES evidence(evidence_id),
  related_evidence_id uuid NOT NULL REFERENCES evidence(evidence_id),
  relation text NOT NULL CHECK (relation IN ('derives_from', 'verifies', 'supersedes', 'records')),
  PRIMARY KEY (evidence_id, related_evidence_id, relation),
  CHECK (evidence_id <> related_evidence_id)
);

CREATE TABLE assessments (
  assessment_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  requirement_id text NOT NULL REFERENCES requirements(requirement_id),
  status ssdf_status NOT NULL,
  rationale text NOT NULL,
  assessed_at timestamptz NOT NULL DEFAULT now(),
  policy_version text NOT NULL,
  oscal_assessment_result_uri text,
  supersedes_assessment_id uuid REFERENCES assessments(assessment_id)
);

CREATE INDEX assessments_requirement_idx ON assessments (requirement_id, assessed_at DESC);

CREATE TABLE assessment_evidence (
  assessment_id uuid NOT NULL REFERENCES assessments(assessment_id),
  evidence_id uuid NOT NULL REFERENCES evidence(evidence_id),
  PRIMARY KEY (assessment_id, evidence_id)
);

CREATE TABLE deployment_approvals (
  approval_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  issued_by text NOT NULL,
  git_commit text NOT NULL,
  rendered_spec_hash text NOT NULL,
  image_digests jsonb NOT NULL,
  policy_version text NOT NULL,
  evidence_fresh_until timestamptz NOT NULL,
  execution_lease_expires_at timestamptz NOT NULL,
  trust_state text NOT NULL CHECK (trust_state IN ('trusted', 'revoked', 'unknown')),
  trust_state_expires_at timestamptz NOT NULL,
  approval_bundle_evidence_id uuid REFERENCES evidence(evidence_id),
  issued_at timestamptz NOT NULL DEFAULT now(),
  CHECK (jsonb_typeof(image_digests) = 'array'),
  CHECK (evidence_fresh_until > issued_at),
  CHECK (execution_lease_expires_at > issued_at),
  CHECK (execution_lease_expires_at <= issued_at + interval '10 minutes'),
  CHECK (trust_state_expires_at <= issued_at + interval '1 minute')
);

CREATE TABLE deployment_events (
  deployment_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  approval_id uuid NOT NULL REFERENCES deployment_approvals(approval_id),
  status text NOT NULL CHECK (status IN ('pending', 'running', 'succeeded', 'failed', 'recovery')),
  argocd_application text NOT NULL,
  started_at timestamptz NOT NULL DEFAULT now(),
  completed_at timestamptz,
  post_deploy_checked_at timestamptz,
  post_deploy_result jsonb,
  recovery_of_deployment_id uuid REFERENCES deployment_events(deployment_id)
);

CREATE TABLE hash_checkpoints (
  checkpoint_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  chain_head bytea NOT NULL,
  checkpointed_at timestamptz NOT NULL DEFAULT now(),
  rekor_log_index bigint,
  rekor_entry_uuid text,
  signature_ref text NOT NULL
);

CREATE OR REPLACE FUNCTION append_evidence(
  p_kind evidence_kind,
  p_track ssdf_track,
  p_subject_kind text,
  p_subject_ref text,
  p_issuer text,
  p_source_uri text,
  p_observed_at timestamptz,
  p_expires_at timestamptz,
  p_policy_version text,
  p_claim jsonb
) RETURNS evidence
LANGUAGE plpgsql
AS $$
DECLARE
  prior_hash bytea;
  new_row evidence;
  canonical_claim text;
BEGIN
  -- Serializing append operations preserves a single, auditable hash chain.
  PERFORM pg_advisory_xact_lock(hashtext('ln-ssdf-evidence-chain'));
  SELECT row_hash INTO prior_hash FROM evidence ORDER BY created_at DESC, evidence_id DESC LIMIT 1;
  canonical_claim := jsonb_strip_nulls(p_claim)::text;
  INSERT INTO evidence (
    kind, track, subject_kind, subject_ref, issuer, source_uri, observed_at,
    expires_at, policy_version, claim, previous_hash, row_hash
  ) VALUES (
    p_kind, p_track, p_subject_kind, p_subject_ref, p_issuer, p_source_uri,
    p_observed_at, p_expires_at, p_policy_version, p_claim, prior_hash,
    digest(coalesce(encode(prior_hash, 'hex'), '') || '|' || p_kind::text || '|' ||
      p_track::text || '|' || p_subject_kind || '|' || p_subject_ref || '|' ||
      p_issuer || '|' || p_source_uri || '|' || p_observed_at::text || '|' ||
      coalesce(p_expires_at::text, '') || '|' || p_policy_version || '|' || canonical_claim,
      'sha256')
  ) RETURNING * INTO new_row;
  RETURN new_row;
END;
$$;

CREATE OR REPLACE FUNCTION reject_evidence_mutation()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'evidence is append-only; create a superseding evidence record instead';
END;
$$;

CREATE TRIGGER evidence_append_only
BEFORE UPDATE OR DELETE ON evidence
FOR EACH ROW EXECUTE FUNCTION reject_evidence_mutation();

CREATE VIEW current_requirement_status AS
SELECT DISTINCT ON (requirement_id)
  requirement_id, status, rationale, assessed_at, policy_version, oscal_assessment_result_uri
FROM assessments
ORDER BY requirement_id, assessed_at DESC, assessment_id DESC;

CREATE TABLE schema_migrations (
  version text PRIMARY KEY,
  applied_at timestamptz NOT NULL DEFAULT now()
);

INSERT INTO schema_migrations (version) VALUES ('phase0-v1')
ON CONFLICT (version) DO NOTHING;
