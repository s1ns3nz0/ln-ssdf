-- Phase 8: independently recompute the append-only evidence chain.  This is
-- intentionally a read-only check; Rekor remains authoritative for signatures.
CREATE OR REPLACE FUNCTION verify_evidence_chain()
RETURNS TABLE (
  valid boolean,
  checked_rows bigint,
  failure text,
  computed_head text
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE
  candidate evidence%ROWTYPE;
  prior_hash bytea;
  expected_hash bytea;
  checked bigint := 0;
  canonical_claim text;
BEGIN
  FOR candidate IN SELECT * FROM evidence ORDER BY created_at, evidence_id LOOP
    checked := checked + 1;
    canonical_claim := jsonb_strip_nulls(candidate.claim)::text;
    expected_hash := digest(
      coalesce(encode(prior_hash, 'hex'), '') || '|' || candidate.kind::text || '|' ||
      candidate.track::text || '|' || candidate.subject_kind || '|' || candidate.subject_ref || '|' ||
      candidate.issuer || '|' || candidate.source_uri || '|' || candidate.observed_at::text || '|' ||
      coalesce(candidate.expires_at::text, '') || '|' || candidate.policy_version || '|' || canonical_claim,
      'sha256'
    );
    IF candidate.previous_hash IS DISTINCT FROM prior_hash THEN
      RETURN QUERY SELECT false, checked, 'previous_hash mismatch at evidence ' || candidate.evidence_id,
        encode(prior_hash, 'hex');
      RETURN;
    END IF;
    IF candidate.row_hash IS DISTINCT FROM expected_hash THEN
      RETURN QUERY SELECT false, checked, 'row_hash mismatch at evidence ' || candidate.evidence_id,
        encode(prior_hash, 'hex');
      RETURN;
    END IF;
    prior_hash := candidate.row_hash;
  END LOOP;
  RETURN QUERY SELECT true, checked, NULL::text, encode(prior_hash, 'hex');
END;
$$;

REVOKE ALL ON FUNCTION verify_evidence_chain() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION verify_evidence_chain() TO postgres_monitor;

INSERT INTO schema_migrations (version) VALUES ('phase8-evidence-integrity-v1')
ON CONFLICT (version) DO NOTHING;
