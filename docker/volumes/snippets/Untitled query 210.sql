-- ── Schema Feature Permissions ────────────────────────────────────────────────
-- Controls which admin roles can read/write each schema management feature
-- (enums, functions, RLS policies).
-- Independent of the admin_permissions per-user override system — this table
-- drives the default role-level access that the UI enforces before any DDL.

CREATE TABLE IF NOT EXISTS admin_schema_permissions (
  role        text        NOT NULL,
  feature     text        NOT NULL CHECK (feature IN ('enums', 'functions', 'rls')),
  can_read    boolean     NOT NULL DEFAULT false,
  can_write   boolean     NOT NULL DEFAULT false,
  updated_by  text,
  updated_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (role, feature)
);

-- ── Defaults ──────────────────────────────────────────────────────────────────
-- super_admin  → full access to all three features
-- admin        → full access to all three features
-- developer    → read-only (can browse enums / functions / RLS, cannot mutate)
-- support      → no access (schema features are out of scope for support)

INSERT INTO admin_schema_permissions (role, feature, can_read, can_write) VALUES
  ('super_admin', 'enums',     true,  true),
  ('super_admin', 'functions', true,  true),
  ('super_admin', 'rls',       true,  true),
  ('admin',       'enums',     true,  true),
  ('admin',       'functions', true,  true),
  ('admin',       'rls',       true,  true),
  ('developer',   'enums',     true,  false),
  ('developer',   'functions', true,  false),
  ('developer',   'rls',       true,  false),
  ('support',     'enums',     false, false),
  ('support',     'functions', false, false),
  ('support',     'rls',       false, false)
ON CONFLICT (role, feature) DO NOTHING;

-- ── RLS (keep the table internal) ─────────────────────────────────────────────
ALTER TABLE admin_schema_permissions ENABLE ROW LEVEL SECURITY;

-- Only service_role accesses this table — anon/authenticated are blocked by RLS
CREATE POLICY "service_role only"
  ON admin_schema_permissions
  FOR ALL
  TO service_role
  USING (true)
  WITH CHECK (true);

GRANT SELECT, INSERT, UPDATE ON admin_schema_permissions TO service_role;

-- ── Helper RPC: get all schema permissions (used by the admin UI) ─────────────
CREATE OR REPLACE FUNCTION get_schema_permissions()
RETURNS TABLE (role text, feature text, can_read boolean, can_write boolean)
LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$
  SELECT role, feature, can_read, can_write
  FROM admin_schema_permissions
  ORDER BY role, feature;
$$;

GRANT EXECUTE ON FUNCTION get_schema_permissions() TO service_role;
