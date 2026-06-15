-- ── Enum introspection ────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION get_public_enums()
RETURNS TABLE (enum_name text, enum_values text[])
LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$
  SELECT t.typname::text,
         array_agg(e.enumlabel ORDER BY e.enumsortorder)::text[]
  FROM pg_type t
  JOIN pg_enum e ON t.oid = e.enumtypid
  JOIN pg_namespace n ON t.typnamespace = n.oid
  WHERE n.nspname = 'public'
  GROUP BY t.typname
  ORDER BY t.typname;
$$;

-- ── Function introspection ────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION get_public_functions()
RETURNS TABLE (
  func_name          text,
  func_args          text,
  return_type        text,
  func_lang          text,
  definition         text,
  is_strict          boolean,
  is_security_definer boolean
)
LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$
  SELECT
    p.proname::text,
    pg_get_function_arguments(p.oid)::text,
    pg_get_function_result(p.oid)::text,
    l.lanname::text AS func_lang,
    pg_get_functiondef(p.oid)::text,
    p.proisstrict,
    p.prosecdef
  FROM pg_proc p
  JOIN pg_namespace n ON p.pronamespace = n.oid
  JOIN pg_language l ON p.prolang = l.oid
  WHERE n.nspname = 'public'
    AND p.prokind = 'f'
  ORDER BY p.proname;
$$;

-- ── RLS status per table ──────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION get_rls_status()
RETURNS TABLE (table_name text, rls_enabled boolean, force_rls boolean)
LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$
  SELECT c.relname::text, c.relrowsecurity, c.relforcerowsecurity
  FROM pg_class c
  JOIN pg_namespace n ON c.relnamespace = n.oid
  WHERE n.nspname = 'public' AND c.relkind = 'r'
  ORDER BY c.relname;
$$;

-- ── Policies for a table ──────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION get_table_policies(p_table_name text)
RETURNS TABLE (
  policy_name    text,
  command        text,
  permissive     text,
  roles          text[],
  using_expr     text,
  with_check_expr text
)
LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$
  SELECT
    p.polname::text,
    CASE p.polcmd
      WHEN 'r' THEN 'SELECT'
      WHEN 'a' THEN 'INSERT'
      WHEN 'w' THEN 'UPDATE'
      WHEN 'd' THEN 'DELETE'
      ELSE 'ALL'
    END::text,
    CASE WHEN p.polpermissive THEN 'PERMISSIVE' ELSE 'RESTRICTIVE' END::text,
    ARRAY(SELECT rolname FROM pg_roles WHERE oid = ANY(p.polroles))::text[],
    COALESCE(pg_get_expr(p.polqual, p.polrelid), '')::text,
    COALESCE(pg_get_expr(p.polwithcheck, p.polrelid), '')::text
  FROM pg_policy p
  JOIN pg_class c ON p.polrelid = c.oid
  JOIN pg_namespace n ON c.relnamespace = n.oid
  WHERE n.nspname = 'public' AND c.relname = p_table_name
  ORDER BY p.polname;
$$;

GRANT EXECUTE ON FUNCTION get_public_enums()            TO service_role;
GRANT EXECUTE ON FUNCTION get_public_functions()        TO service_role;
GRANT EXECUTE ON FUNCTION get_rls_status()              TO service_role;
GRANT EXECUTE ON FUNCTION get_table_policies(text)      TO service_role;
