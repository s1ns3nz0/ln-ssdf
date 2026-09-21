-- Phase 9: dashboard has query-only access to the operational projection.
-- A runtime credential may inherit dashboard_reader, but no Git-managed Secret
-- or role password is created here.
DO $$ BEGIN
  CREATE ROLE dashboard_reader NOLOGIN;
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

GRANT CONNECT ON DATABASE ssdf TO dashboard_reader;
GRANT USAGE ON SCHEMA public TO dashboard_reader;
GRANT SELECT ON TABLE evidence, current_requirement_status, deployment_events TO dashboard_reader;

-- OSCAL projection is installed by the experiment bootstrap, so grant it only
-- when this migration is used with that verified schema present.
DO $$ BEGIN
  IF to_regclass('public.oscal_requirement_projection') IS NOT NULL THEN
    GRANT SELECT ON TABLE oscal_requirement_projection TO dashboard_reader;
  END IF;
END $$;

INSERT INTO schema_migrations (version) VALUES ('phase9-dashboard-reader-v1')
ON CONFLICT (version) DO NOTHING;
