-- Per-role table access control.
-- Rows here gate what the table browser shows and what data actions can execute.
-- super_admin and admin bypass this table entirely (see lib/tables/access.ts).
-- developer and support only see rows whose role matches theirs and can_read = true.

create table if not exists admin_table_permissions (
  id          uuid        primary key default gen_random_uuid(),
  role        text        not null,
  table_name  text        not null,
  can_read    boolean     not null default true,
  can_write   boolean     not null default false,
  created_at  timestamptz not null default now(),
  unique (role, table_name)
);

-- ── Developer defaults ────────────────────────────────────────────────────────
-- Technical / non-PII tables only. No user profiles, no financials.
insert into admin_table_permissions (role, table_name, can_read, can_write) values
  ('developer', 'audit_logs',          true, false),
  ('developer', 'app_config',          true, true),
  ('developer', 'app_config_history',  true, false),
  ('developer', 'admin_sessions',      true, false),
  ('developer', 'admin_users',         true, false),
  ('developer', 'admin_invites',       true, false),
  ('developer', 'projects',            true, false),
  ('developer', 'guilds',              true, false)
on conflict (role, table_name) do nothing;

-- ── Support defaults ──────────────────────────────────────────────────────────
-- User-facing read-only tables for investigating issues.
insert into admin_table_permissions (role, table_name, can_read, can_write) values
  ('support', 'profiles',   true, false),
  ('support', 'audit_logs', true, false),
  ('support', 'projects',   true, false),
  ('support', 'guilds',     true, false)
on conflict (role, table_name) do nothing;