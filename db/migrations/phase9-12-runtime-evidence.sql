-- Extend the append-only evidence projection for local runtime drills.
SET client_min_messages = warning;
ALTER TYPE evidence_kind ADD VALUE IF NOT EXISTS 'runtime_observation';

INSERT INTO schema_migrations (version) VALUES ('phase9-12-runtime-evidence-v1')
ON CONFLICT (version) DO NOTHING;
