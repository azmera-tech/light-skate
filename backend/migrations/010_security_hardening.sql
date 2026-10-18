-- 010: pin function search_path (prevents search_path hijacking) and move pg_trgm out of public.
-- Only meaningful on Supabase, which auto-lints for both; harmless no-op-equivalent elsewhere.
ALTER FUNCTION public.forbid_mutation() SET search_path = pg_catalog, public;
ALTER FUNCTION public.waiver_versions_guard() SET search_path = pg_catalog, public;

CREATE SCHEMA IF NOT EXISTS extensions;
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_trgm' AND extnamespace = 'public'::regnamespace) THEN
    ALTER EXTENSION pg_trgm SET SCHEMA extensions;
  END IF;
END $$;
