-- 010: pin function search_path (prevents search_path hijacking) and move pg_trgm out of public.
-- The extension move only happens on Supabase, whose roles put the "extensions" schema on the search_path; on plain
-- Postgres it would make gin_trgm_ops unresolvable for later migrations, so there it is left in public.
ALTER FUNCTION public.forbid_mutation() SET search_path = pg_catalog, public;
ALTER FUNCTION public.waiver_versions_guard() SET search_path = pg_catalog, public;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'supabase_admin')
     AND EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_trgm' AND extnamespace = 'public'::regnamespace) THEN
    CREATE SCHEMA IF NOT EXISTS extensions;
    ALTER EXTENSION pg_trgm SET SCHEMA extensions;
  END IF;
END $$;
