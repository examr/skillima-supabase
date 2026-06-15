-- ============================================================
-- SKILLIMA: Complete Admin Schema Migration
-- Run entirely in Supabase SQL Editor in one go
-- ============================================================


-- ------------------------------------------------------------
-- STEP 1: Create admin schema
-- ------------------------------------------------------------
CREATE SCHEMA IF NOT EXISTS admin;


-- ------------------------------------------------------------
-- STEP 2: Create new ENUM types in admin schema
-- ------------------------------------------------------------

CREATE TYPE admin.admin_role AS ENUM (
  'super_admin', 'admin', 'developer', 'support'
);

CREATE TYPE admin.admin_permission AS ENUM (
  'config.read','config.write',
  'tables.read','tables.write',
  'users.read','users.write',
  'tickets.read','tickets.write','tickets.escalate',
  'logs.read',
  'deployments.read','deployments.trigger',
  'projects.read','projects.create','projects.delete',
  'dashboard.read','dashboard.write','dashboard.customize',
  'projects.update','projects.publish','projects.archive',
  'projects.analytics','projects.featured',
  'revenue.read',
  'sessions.read','sessions.kill',
  'audit.read',
  'monitoring.read',
  'security.read',
  'moderation.read','moderation.write',
  'mentors.read','mentors.verify',
  'analytics.read',
  'widgets.customize',
  'feature_flags.read','feature_flags.write'
);

CREATE TYPE admin.audit_action AS ENUM (
  'login','logout',
  'config.read','config.write','config.delete',
  'table.read','table.write','table.delete',
  'user.create','user.update','user.suspend','user.delete',
  'permission.grant','permission.revoke',
  'ticket.create','ticket.update','ticket.escalate','ticket.close',
  'deployment.trigger',
  'dashboard.create','dashboard.update','dashboard.delete','dashboard.reset',
  'widget.add','widget.remove','widget.resize','widget.move',
  'dashboard.favorite'
);


-- ------------------------------------------------------------
-- STEP 3: Move tables to admin schema
-- ------------------------------------------------------------

ALTER TABLE public.admin_users               SET SCHEMA admin;
ALTER TABLE public.admin_invites             SET SCHEMA admin;
ALTER TABLE public.admin_totp                SET SCHEMA admin;
ALTER TABLE public.admin_sessions            SET SCHEMA admin;
ALTER TABLE public.admin_permissions         SET SCHEMA admin;
ALTER TABLE public.role_permissions          SET SCHEMA admin;
ALTER TABLE public.admin_dashboards          SET SCHEMA admin;
ALTER TABLE public.admin_dashboard_layouts   SET SCHEMA admin;
ALTER TABLE public.admin_dashboard_favorites SET SCHEMA admin;
ALTER TABLE public.admin_widget_preferences  SET SCHEMA admin;
ALTER TABLE public.admin_notifications       SET SCHEMA admin;
ALTER TABLE public.admin_schema_permissions  SET SCHEMA admin;
ALTER TABLE public.admin_table_permissions   SET SCHEMA admin;
ALTER TABLE public.app_config                SET SCHEMA admin;
ALTER TABLE public.app_config_history        SET SCHEMA admin;
ALTER TABLE public.audit_logs                SET SCHEMA admin;
ALTER TABLE public.notion_workspaces            SET SCHEMA admin;
ALTER TABLE public.notion_database_connections  SET SCHEMA admin;
ALTER TABLE public.notion_ticket_sync           SET SCHEMA admin;
ALTER TABLE public.notion_sync_queue            SET SCHEMA admin;
ALTER TABLE public.notion_sync_events           SET SCHEMA admin;
ALTER TABLE public.notion_dead_letter_queue     SET SCHEMA admin;
ALTER TABLE public.notion_rate_limit_state      SET SCHEMA admin;
ALTER TABLE public.notion_schema_evolution      SET SCHEMA admin;
ALTER TABLE public.notion_webhooks              SET SCHEMA admin;
ALTER TABLE public.ticket_activity_logs      SET SCHEMA admin;
ALTER TABLE public.ticket_notifications      SET SCHEMA admin;


-- ------------------------------------------------------------
-- STEP 4: Cast columns to new admin.* enum types
-- Pattern: drop default → cast → restore default
-- ------------------------------------------------------------

-- ── admin_users.role ─────────────────────────────────────────
ALTER TABLE admin.admin_users
  ALTER COLUMN role DROP DEFAULT;
ALTER TABLE admin.admin_users
  ALTER COLUMN role TYPE admin.admin_role
    USING role::text::admin.admin_role;
ALTER TABLE admin.admin_users
  ALTER COLUMN role SET DEFAULT 'support'::admin.admin_role;

-- ── admin_invites.role ───────────────────────────────────────
ALTER TABLE admin.admin_invites
  ALTER COLUMN role DROP DEFAULT;
ALTER TABLE admin.admin_invites
  ALTER COLUMN role TYPE admin.admin_role
    USING role::text::admin.admin_role;

-- ── admin_dashboard_layouts.role ─────────────────────────────
ALTER TABLE admin.admin_dashboard_layouts
  ALTER COLUMN role DROP DEFAULT;
ALTER TABLE admin.admin_dashboard_layouts
  ALTER COLUMN role TYPE admin.admin_role
    USING role::text::admin.admin_role;

-- ── admin_permissions.permission ─────────────────────────────
ALTER TABLE admin.admin_permissions
  ALTER COLUMN permission DROP DEFAULT;
ALTER TABLE admin.admin_permissions
  ALTER COLUMN permission TYPE admin.admin_permission
    USING permission::text::admin.admin_permission;

-- ── role_permissions.role ────────────────────────────────────
ALTER TABLE admin.role_permissions
  ALTER COLUMN role DROP DEFAULT;
ALTER TABLE admin.role_permissions
  ALTER COLUMN role TYPE admin.admin_role
    USING role::text::admin.admin_role;

-- ── role_permissions.permission ──────────────────────────────
ALTER TABLE admin.role_permissions
  ALTER COLUMN permission DROP DEFAULT;
ALTER TABLE admin.role_permissions
  ALTER COLUMN permission TYPE admin.admin_permission
    USING permission::text::admin.admin_permission;

-- ── audit_logs.user_role ─────────────────────────────────────
ALTER TABLE admin.audit_logs
  ALTER COLUMN user_role DROP DEFAULT;
ALTER TABLE admin.audit_logs
  ALTER COLUMN user_role TYPE admin.admin_role
    USING user_role::text::admin.admin_role;

-- ── audit_logs.action ────────────────────────────────────────
ALTER TABLE admin.audit_logs
  ALTER COLUMN action DROP DEFAULT;
ALTER TABLE admin.audit_logs
  ALTER COLUMN action TYPE admin.audit_action
    USING action::text::admin.audit_action;


-- ------------------------------------------------------------
-- STEP 5: Drop old public enums
-- ------------------------------------------------------------

DROP TYPE IF EXISTS public.admin_role CASCADE;
DROP TYPE IF EXISTS public.admin_permission CASCADE;


-- ------------------------------------------------------------
-- STEP 6: Create helper functions in admin schema
-- ------------------------------------------------------------

-- Main permission check function
CREATE OR REPLACE FUNCTION admin.current_user_has(
  required_permission admin.admin_permission
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = admin, public, auth
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM admin.admin_permissions ap
    WHERE ap.user_id = auth.uid()
      AND ap.permission = required_permission
      AND ap.granted = true
  )
  OR EXISTS (
    SELECT 1
    FROM admin.role_permissions rp
    JOIN admin.admin_users au ON au.role = rp.role
    WHERE au.id = auth.uid()
      AND rp.permission = required_permission
  );
$$;

-- Public alias so any existing code still works during transition
CREATE OR REPLACE FUNCTION public.current_user_has(
  required_permission admin.admin_permission
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = admin, public, auth
AS $$
  SELECT admin.current_user_has(required_permission);
$$;

-- Update is_admin() to point at admin schema
CREATE OR REPLACE FUNCTION public.is_admin()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = admin, public, auth
AS $$
  SELECT EXISTS (
    SELECT 1 FROM admin.admin_users
    WHERE id = auth.uid()
      AND is_active = true
      AND role IN ('super_admin', 'admin')
  );
$$;


-- ------------------------------------------------------------
-- STEP 7: Grant permissions on admin schema
-- ------------------------------------------------------------

GRANT USAGE ON SCHEMA admin TO authenticated;
GRANT USAGE ON SCHEMA admin TO service_role;
GRANT USAGE ON SCHEMA admin TO anon;

GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA admin TO authenticated;
GRANT ALL ON ALL TABLES IN SCHEMA admin TO service_role;
GRANT SELECT ON ALL TABLES IN SCHEMA admin TO anon;

GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA admin TO authenticated;
GRANT ALL ON ALL SEQUENCES IN SCHEMA admin TO service_role;

ALTER DEFAULT PRIVILEGES IN SCHEMA admin
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO authenticated;
ALTER DEFAULT PRIVILEGES IN SCHEMA admin
  GRANT ALL ON TABLES TO service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA admin
  GRANT USAGE, SELECT ON SEQUENCES TO authenticated;


-- ------------------------------------------------------------
-- STEP 8: Enable RLS on all admin tables
-- ------------------------------------------------------------

ALTER TABLE admin.admin_users               ENABLE ROW LEVEL SECURITY;
ALTER TABLE admin.admin_invites             ENABLE ROW LEVEL SECURITY;
ALTER TABLE admin.admin_totp                ENABLE ROW LEVEL SECURITY;
ALTER TABLE admin.admin_sessions            ENABLE ROW LEVEL SECURITY;
ALTER TABLE admin.admin_permissions         ENABLE ROW LEVEL SECURITY;
ALTER TABLE admin.role_permissions          ENABLE ROW LEVEL SECURITY;
ALTER TABLE admin.admin_dashboards          ENABLE ROW LEVEL SECURITY;
ALTER TABLE admin.admin_dashboard_layouts   ENABLE ROW LEVEL SECURITY;
ALTER TABLE admin.admin_dashboard_favorites ENABLE ROW LEVEL SECURITY;
ALTER TABLE admin.admin_widget_preferences  ENABLE ROW LEVEL SECURITY;
ALTER TABLE admin.admin_notifications       ENABLE ROW LEVEL SECURITY;
ALTER TABLE admin.admin_schema_permissions  ENABLE ROW LEVEL SECURITY;
ALTER TABLE admin.admin_table_permissions   ENABLE ROW LEVEL SECURITY;
ALTER TABLE admin.app_config                ENABLE ROW LEVEL SECURITY;
ALTER TABLE admin.app_config_history        ENABLE ROW LEVEL SECURITY;
ALTER TABLE admin.audit_logs                ENABLE ROW LEVEL SECURITY;
ALTER TABLE admin.notion_workspaces            ENABLE ROW LEVEL SECURITY;
ALTER TABLE admin.notion_database_connections  ENABLE ROW LEVEL SECURITY;
ALTER TABLE admin.notion_ticket_sync           ENABLE ROW LEVEL SECURITY;
ALTER TABLE admin.notion_sync_queue            ENABLE ROW LEVEL SECURITY;
ALTER TABLE admin.notion_sync_events           ENABLE ROW LEVEL SECURITY;
ALTER TABLE admin.notion_dead_letter_queue     ENABLE ROW LEVEL SECURITY;
ALTER TABLE admin.notion_rate_limit_state      ENABLE ROW LEVEL SECURITY;
ALTER TABLE admin.notion_schema_evolution      ENABLE ROW LEVEL SECURITY;
ALTER TABLE admin.notion_webhooks              ENABLE ROW LEVEL SECURITY;
ALTER TABLE admin.ticket_activity_logs      ENABLE ROW LEVEL SECURITY;
ALTER TABLE admin.ticket_notifications      ENABLE ROW LEVEL SECURITY;


-- ------------------------------------------------------------
-- STEP 9: Drop all old RLS policies then recreate
-- ------------------------------------------------------------

-- ── admin_users ──────────────────────────────────────────────
DROP POLICY IF EXISTS "self read"           ON admin.admin_users;
DROP POLICY IF EXISTS "users read"          ON admin.admin_users;
DROP POLICY IF EXISTS "users write insert"  ON admin.admin_users;
DROP POLICY IF EXISTS "users write update"  ON admin.admin_users;

CREATE POLICY "self read" ON admin.admin_users
  FOR SELECT USING (id = auth.uid());

CREATE POLICY "users read" ON admin.admin_users
  FOR SELECT USING (
    admin.current_user_has('users.read'::admin.admin_permission)
  );

CREATE POLICY "users write insert" ON admin.admin_users
  FOR INSERT WITH CHECK (
    admin.current_user_has('users.write'::admin.admin_permission)
  );

CREATE POLICY "users write update" ON admin.admin_users
  FOR UPDATE USING (
    admin.current_user_has('users.write'::admin.admin_permission)
  );


-- ── admin_invites ─────────────────────────────────────────────
DROP POLICY IF EXISTS "invites manage" ON admin.admin_invites;

CREATE POLICY "invites manage" ON admin.admin_invites
  FOR ALL USING (
    admin.current_user_has('users.write'::admin.admin_permission)
  );


-- ── admin_totp ────────────────────────────────────────────────
DROP POLICY IF EXISTS "service_role only" ON admin.admin_totp;

CREATE POLICY "service_role only" ON admin.admin_totp
  FOR ALL TO service_role
  USING (true)
  WITH CHECK (true);


-- ── admin_sessions ────────────────────────────────────────────
DROP POLICY IF EXISTS "self sessions" ON admin.admin_sessions;

CREATE POLICY "self sessions" ON admin.admin_sessions
  FOR SELECT USING (user_id = auth.uid());


-- ── admin_permissions ─────────────────────────────────────────
DROP POLICY IF EXISTS "permissions manage" ON admin.admin_permissions;

CREATE POLICY "permissions manage" ON admin.admin_permissions
  FOR ALL USING (
    admin.current_user_has('users.write'::admin.admin_permission)
  );


-- ── role_permissions ──────────────────────────────────────────
DROP POLICY IF EXISTS "role permissions read" ON admin.role_permissions;

CREATE POLICY "role permissions read" ON admin.role_permissions
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM admin.admin_users
      WHERE admin_users.id = auth.uid()
        AND admin_users.is_active = true
    )
  );


-- ── admin_dashboards ──────────────────────────────────────────
DROP POLICY IF EXISTS "dashboards read"  ON admin.admin_dashboards;
DROP POLICY IF EXISTS "dashboards write" ON admin.admin_dashboards;

CREATE POLICY "dashboards read" ON admin.admin_dashboards
  FOR SELECT USING (
    admin.current_user_has('dashboard.read'::admin.admin_permission)
  );

CREATE POLICY "dashboards write" ON admin.admin_dashboards
  FOR ALL USING (
    admin.current_user_has('dashboard.write'::admin.admin_permission)
  );


-- ── admin_dashboard_layouts ───────────────────────────────────
DROP POLICY IF EXISTS "layouts manage own" ON admin.admin_dashboard_layouts;

CREATE POLICY "layouts manage own" ON admin.admin_dashboard_layouts
  FOR ALL USING (user_id = auth.uid());


-- ── admin_dashboard_favorites ─────────────────────────────────
DROP POLICY IF EXISTS "favorites manage own" ON admin.admin_dashboard_favorites;

CREATE POLICY "favorites manage own" ON admin.admin_dashboard_favorites
  FOR ALL USING (user_id = auth.uid());


-- ── admin_widget_preferences ──────────────────────────────────
DROP POLICY IF EXISTS "widget prefs own" ON admin.admin_widget_preferences;

CREATE POLICY "widget prefs own" ON admin.admin_widget_preferences
  FOR ALL USING (user_id = auth.uid());


-- ── admin_notifications ───────────────────────────────────────
DROP POLICY IF EXISTS "notifications own" ON admin.admin_notifications;

CREATE POLICY "notifications own" ON admin.admin_notifications
  FOR ALL USING (user_id = auth.uid());


-- ── admin_schema_permissions ──────────────────────────────────
DROP POLICY IF EXISTS "service_role only" ON admin.admin_schema_permissions;

CREATE POLICY "service_role only" ON admin.admin_schema_permissions
  FOR ALL TO service_role
  USING (true)
  WITH CHECK (true);


-- ── admin_table_permissions ───────────────────────────────────
DROP POLICY IF EXISTS "table perms read" ON admin.admin_table_permissions;

CREATE POLICY "table perms read" ON admin.admin_table_permissions
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM admin.admin_users
      WHERE admin_users.id = auth.uid()
        AND admin_users.is_active = true
    )
  );


-- ── app_config ────────────────────────────────────────────────
DROP POLICY IF EXISTS "config read"         ON admin.app_config;
DROP POLICY IF EXISTS "config write insert" ON admin.app_config;
DROP POLICY IF EXISTS "config write update" ON admin.app_config;
DROP POLICY IF EXISTS "config delete"       ON admin.app_config;

CREATE POLICY "config read" ON admin.app_config
  FOR SELECT USING (
    admin.current_user_has('config.read'::admin.admin_permission)
  );

CREATE POLICY "config write insert" ON admin.app_config
  FOR INSERT WITH CHECK (
    admin.current_user_has('config.write'::admin.admin_permission)
  );

CREATE POLICY "config write update" ON admin.app_config
  FOR UPDATE USING (
    admin.current_user_has('config.write'::admin.admin_permission)
  );

CREATE POLICY "config delete" ON admin.app_config
  FOR DELETE USING (
    admin.current_user_has('config.write'::admin.admin_permission)
  );


-- ── app_config_history ────────────────────────────────────────
DROP POLICY IF EXISTS "config history read" ON admin.app_config_history;

CREATE POLICY "config history read" ON admin.app_config_history
  FOR SELECT USING (
    admin.current_user_has('config.read'::admin.admin_permission)
  );


-- ── audit_logs ────────────────────────────────────────────────
DROP POLICY IF EXISTS "logs read all"      ON admin.audit_logs;
DROP POLICY IF EXISTS "no direct insert"   ON admin.audit_logs;
DROP POLICY IF EXISTS "self read own logs" ON admin.audit_logs;

CREATE POLICY "logs read all" ON admin.audit_logs
  FOR SELECT USING (
    admin.current_user_has('logs.read'::admin.admin_permission)
  );

CREATE POLICY "no direct insert" ON admin.audit_logs
  FOR INSERT WITH CHECK (false);

CREATE POLICY "self read own logs" ON admin.audit_logs
  FOR SELECT USING (user_id = auth.uid());


-- ── notion_workspaces ─────────────────────────────────────────
DROP POLICY IF EXISTS "notion workspaces manage" ON admin.notion_workspaces;

CREATE POLICY "notion workspaces manage" ON admin.notion_workspaces
  FOR ALL USING (
    EXISTS (
      SELECT 1 FROM admin.admin_users
      WHERE admin_users.id = auth.uid()
        AND admin_users.is_active = true
    )
  );


-- ── notion_database_connections ───────────────────────────────
DROP POLICY IF EXISTS "notion db connections manage" ON admin.notion_database_connections;

CREATE POLICY "notion db connections manage" ON admin.notion_database_connections
  FOR ALL USING (
    EXISTS (
      SELECT 1 FROM admin.admin_users
      WHERE admin_users.id = auth.uid()
        AND admin_users.is_active = true
    )
  );


-- ── notion_ticket_sync ────────────────────────────────────────
DROP POLICY IF EXISTS "ticket sync manage" ON admin.notion_ticket_sync;

CREATE POLICY "ticket sync manage" ON admin.notion_ticket_sync
  FOR ALL USING (
    EXISTS (
      SELECT 1 FROM admin.admin_users
      WHERE admin_users.id = auth.uid()
        AND admin_users.is_active = true
    )
  );


-- ── notion_sync_queue ─────────────────────────────────────────
DROP POLICY IF EXISTS "sync queue service role" ON admin.notion_sync_queue;

CREATE POLICY "sync queue service role" ON admin.notion_sync_queue
  FOR ALL TO service_role
  USING (true)
  WITH CHECK (true);


-- ── notion_sync_events ────────────────────────────────────────
DROP POLICY IF EXISTS "sync events manage" ON admin.notion_sync_events;

CREATE POLICY "sync events manage" ON admin.notion_sync_events
  FOR ALL USING (
    EXISTS (
      SELECT 1 FROM admin.admin_users
      WHERE admin_users.id = auth.uid()
        AND admin_users.is_active = true
    )
  );


-- ── notion_dead_letter_queue ──────────────────────────────────
DROP POLICY IF EXISTS "dlq service role" ON admin.notion_dead_letter_queue;

CREATE POLICY "dlq service role" ON admin.notion_dead_letter_queue
  FOR ALL TO service_role
  USING (true)
  WITH CHECK (true);


-- ── notion_rate_limit_state ───────────────────────────────────
DROP POLICY IF EXISTS "rate limit service role" ON admin.notion_rate_limit_state;

CREATE POLICY "rate limit service role" ON admin.notion_rate_limit_state
  FOR ALL TO service_role
  USING (true)
  WITH CHECK (true);


-- ── notion_schema_evolution ───────────────────────────────────
DROP POLICY IF EXISTS "schema evolution manage" ON admin.notion_schema_evolution;

CREATE POLICY "schema evolution manage" ON admin.notion_schema_evolution
  FOR ALL USING (
    EXISTS (
      SELECT 1 FROM admin.admin_users
      WHERE admin_users.id = auth.uid()
        AND admin_users.is_active = true
    )
  );


-- ── notion_webhooks ───────────────────────────────────────────
DROP POLICY IF EXISTS "webhooks manage" ON admin.notion_webhooks;

CREATE POLICY "webhooks manage" ON admin.notion_webhooks
  FOR ALL USING (
    EXISTS (
      SELECT 1 FROM admin.admin_users
      WHERE admin_users.id = auth.uid()
        AND admin_users.is_active = true
    )
  );


-- ── ticket_activity_logs ──────────────────────────────────────
DROP POLICY IF EXISTS "ticket logs manage" ON admin.ticket_activity_logs;

CREATE POLICY "ticket logs manage" ON admin.ticket_activity_logs
  FOR ALL USING (
    EXISTS (
      SELECT 1 FROM admin.admin_users
      WHERE admin_users.id = auth.uid()
        AND admin_users.is_active = true
    )
  );


-- ── ticket_notifications ──────────────────────────────────────
DROP POLICY IF EXISTS "ticket notifs manage" ON admin.ticket_notifications;

CREATE POLICY "ticket notifs manage" ON admin.ticket_notifications
  FOR ALL USING (
    EXISTS (
      SELECT 1 FROM admin.admin_users
      WHERE admin_users.id = auth.uid()
        AND admin_users.is_active = true
    )
  );


-- ------------------------------------------------------------
-- STEP 10: Verify everything moved correctly
-- Run these SELECT statements to confirm
-- ------------------------------------------------------------

-- Should list all 27 tables in admin schema
SELECT tablename
FROM pg_tables
WHERE schemaname = 'admin'
ORDER BY tablename;

-- Should show rls = true for all tables
SELECT tablename, rowsecurity
FROM pg_tables
WHERE schemaname = 'admin'
ORDER BY tablename;

-- Should show 3 types in admin schema
SELECT typname
FROM pg_type
WHERE typnamespace = 'admin'::regnamespace
  AND typtype = 'e'
ORDER BY typname;






-- Allows service_role to execute arbitrary DDL (CREATE TABLE, ALTER TABLE ADD COLUMN).
-- SECURITY DEFINER so it runs as the function owner (superuser), not the caller.
-- Only service_role is granted EXECUTE — never anon or authenticated.
CREATE SCHEMA IF NOT EXISTS admin;

DROP FUNCTION IF EXISTS admin.exec_ddl(text);

CREATE OR REPLACE FUNCTION admin.exec_ddl(sql text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  EXECUTE sql;
END;
$$;

REVOKE ALL ON FUNCTION admin.exec_ddl(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION admin.exec_ddl(text) TO service_role;


