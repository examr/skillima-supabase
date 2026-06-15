-- ════════════════════════════════════════
-- ENUMS
-- ════════════════════════════════════════

create type admin_role as enum ('super_admin', 'admin', 'developer', 'support');

create type admin_permission as enum (
  'config.read',
  'config.write',
  'tables.read',
  'tables.write',
  'users.read',
  'users.write',
  'tickets.read',
  'tickets.write',
  'tickets.escalate',
  'logs.read',
  'deployments.read',
  'deployments.trigger'
);

create type audit_action as enum (
  'login',
  'logout',
  'config.read',
  'config.write',
  'config.delete',
  'table.read',
  'table.write',
  'table.delete',
  'user.create',
  'user.update',
  'user.suspend',
  'user.delete',
  'permission.grant',
  'permission.revoke',
  'ticket.create',
  'ticket.update',
  'ticket.escalate',
  'ticket.close',
  'deployment.trigger'
);

-- ════════════════════════════════════════
-- CORE TABLES
-- ════════════════════════════════════════

create table admin_users (
  id            uuid primary key references auth.users(id) on delete cascade,
  email         text not null,
  full_name     text,
  role          admin_role not null default 'support',
  is_active     boolean default true,
  invited_by    uuid references admin_users(id),
  created_at    timestamptz default now(),
  last_login_at timestamptz
);

create table admin_permissions (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references admin_users(id) on delete cascade,
  permission admin_permission not null,
  granted    boolean not null default true,
  granted_by uuid references admin_users(id),
  created_at timestamptz default now(),
  unique(user_id, permission)
);

create table role_permissions (
  role       admin_role not null,
  permission admin_permission not null,
  primary key (role, permission)
);

create table admin_totp (
  user_id    uuid primary key references admin_users(id) on delete cascade,
  secret     text not null,
  verified   boolean default false,
  created_at timestamptz default now()
);

create table admin_invites (
  id         uuid primary key default gen_random_uuid(),
  email      text not null,
  role       admin_role not null,
  token      text unique not null,
  invited_by uuid references admin_users(id),
  expires_at timestamptz not null default now() + interval '24 hours',
  used_at    timestamptz,
  created_at timestamptz default now()
);

create table admin_sessions (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid references admin_users(id) on delete cascade,
  session_token text unique not null,
  ip_address    inet,
  user_agent    text,
  expires_at    timestamptz not null default now() + interval '4 hours',
  created_at    timestamptz default now(),
  last_seen_at  timestamptz default now()
);

create table app_config (
  id          uuid primary key default gen_random_uuid(),
  key         text unique not null,
  value       text not null,
  is_secret   boolean default false,
  description text,
  updated_by  uuid references admin_users(id),
  updated_at  timestamptz default now()
);

create table app_config_history (
  id         uuid primary key default gen_random_uuid(),
  config_id  uuid references app_config(id),
  key        text not null,
  old_value  text,
  new_value  text,
  changed_by uuid references admin_users(id),
  changed_at timestamptz default now()
);

create table audit_logs (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid references admin_users(id) on delete set null,
  user_email  text,
  user_role   admin_role,
  action      audit_action not null,
  resource    text,
  resource_id text,
  old_data    jsonb,
  new_data    jsonb,
  ip_address  inet,
  user_agent  text,
  status      text default 'success',
  meta        jsonb,
  created_at  timestamptz default now()
);

-- ════════════════════════════════════════
-- INDEXES
-- ════════════════════════════════════════

create index audit_logs_user_id_idx    on audit_logs(user_id);
create index audit_logs_action_idx     on audit_logs(action);
create index audit_logs_created_at_idx on audit_logs(created_at desc);
create index audit_logs_resource_idx   on audit_logs(resource);
create index admin_sessions_user_id_idx on admin_sessions(user_id);
create index admin_sessions_expires_at_idx on admin_sessions(expires_at);
create index admin_invites_token_idx   on admin_invites(token);

-- ════════════════════════════════════════
-- ROLE DEFAULT PERMISSIONS
-- ════════════════════════════════════════

insert into role_permissions (role, permission) values
  ('super_admin', 'config.read'),
  ('super_admin', 'config.write'),
  ('super_admin', 'tables.read'),
  ('super_admin', 'tables.write'),
  ('super_admin', 'users.read'),
  ('super_admin', 'users.write'),
  ('super_admin', 'tickets.read'),
  ('super_admin', 'tickets.write'),
  ('super_admin', 'tickets.escalate'),
  ('super_admin', 'logs.read'),
  ('super_admin', 'deployments.read'),
  ('super_admin', 'deployments.trigger'),
  ('admin', 'config.read'),
  ('admin', 'tables.read'),
  ('admin', 'users.read'),
  ('admin', 'tickets.read'),
  ('admin', 'tickets.write'),
  ('admin', 'tickets.escalate'),
  ('admin', 'logs.read'),
  ('admin', 'deployments.read'),
  ('developer', 'config.read'),
  ('developer', 'config.write'),
  ('developer', 'tables.read'),
  ('developer', 'tables.write'),
  ('developer', 'logs.read'),
  ('developer', 'deployments.read'),
  ('developer', 'deployments.trigger'),
  ('support', 'tickets.read'),
  ('support', 'tickets.write');

-- ════════════════════════════════════════
-- HELPER FUNCTIONS
-- ════════════════════════════════════════

-- Check if a specific user has a permission
create or replace function has_permission(
  p_user_id  uuid,
  perm       admin_permission
) returns boolean
language sql security definer stable as $$
  select coalesce(
    (
      select granted
      from admin_permissions
      where user_id = p_user_id
        and permission = perm
    ),
    exists (
      select 1
      from admin_users au
      join role_permissions rp on rp.role = au.role
      where au.id = p_user_id
        and rp.permission = perm
        and au.is_active = true
    )
  );
$$;

-- Shorthand for the currently logged in user
create or replace function current_user_has(perm admin_permission)
returns boolean language sql security definer stable as $$
  select has_permission(auth.uid(), perm);
$$;

-- Get current user's admin profile (used in middleware)
create or replace function get_my_admin_profile()
returns table (id uuid, email text, role admin_role, is_active boolean)
language sql security definer stable as $$
  select id, email, role, is_active
  from admin_users
  where id = auth.uid()
    and is_active = true;
$$;

-- Kill all sessions for a user (called on suspend/revoke)
create or replace function kill_user_sessions(p_user_id uuid)
returns void language sql security definer as $$
  delete from admin_sessions where user_id = p_user_id;
$$;

-- Secure audit log insert (called from Next.js server side)
create or replace function log_audit(
  p_action      audit_action,
  p_resource    text    default null,
  p_resource_id text    default null,
  p_old_data    jsonb   default null,
  p_new_data    jsonb   default null,
  p_ip_address  text    default null,
  p_user_agent  text    default null,
  p_status      text    default 'success',
  p_meta        jsonb   default null
) returns uuid
language plpgsql security definer as $$
declare
  v_user   admin_users%rowtype;
  v_log_id uuid;
begin
  select * into v_user
  from admin_users
  where id = auth.uid();

  insert into audit_logs (
    user_id, user_email, user_role,
    action, resource, resource_id,
    old_data, new_data,
    ip_address, user_agent,
    status, meta
  ) values (
    auth.uid(), v_user.email, v_user.role,
    p_action, p_resource, p_resource_id,
    p_old_data, p_new_data,
    p_ip_address::inet, p_user_agent,
    p_status, p_meta
  )
  returning id into v_log_id;

  if p_action = 'login' then
    update admin_users set last_login_at = now() where id = auth.uid();
  end if;

  return v_log_id;
end;
$$;

-- ════════════════════════════════════════
-- TRIGGERS
-- ════════════════════════════════════════

-- Auto-log config changes
create or replace function audit_config_change()
returns trigger language plpgsql security definer as $$
declare v_user admin_users%rowtype;
begin
  select * into v_user from admin_users where id = auth.uid();
  insert into audit_logs (
    user_id, user_email, user_role,
    action, resource, resource_id,
    old_data, new_data, status
  ) values (
    auth.uid(), v_user.email, v_user.role,
    case TG_OP
      when 'INSERT' then 'config.write'::audit_action
      when 'UPDATE' then 'config.write'::audit_action
      when 'DELETE' then 'config.delete'::audit_action
    end,
    'app_config',
    coalesce(new.id::text, old.id::text),
    case when TG_OP != 'INSERT'
      then jsonb_build_object('key', old.key, 'value', old.value)
    end,
    case when TG_OP != 'DELETE'
      then jsonb_build_object('key', new.key, 'value', new.value)
    end,
    'success'
  );
  return coalesce(new, old);
end;
$$;

create trigger audit_config
after insert or update or delete on app_config
for each row execute function audit_config_change();

-- Auto-log user changes
create or replace function audit_user_change()
returns trigger language plpgsql security definer as $$
declare v_user admin_users%rowtype;
begin
  select * into v_user from admin_users where id = auth.uid();
  insert into audit_logs (
    user_id, user_email, user_role,
    action, resource, resource_id,
    old_data, new_data, status
  ) values (
    auth.uid(), v_user.email, v_user.role,
    case TG_OP
      when 'INSERT' then 'user.create'::audit_action
      when 'UPDATE' then
        case
          when old.is_active = true and new.is_active = false
            then 'user.suspend'::audit_action
          else 'user.update'::audit_action
        end
      when 'DELETE' then 'user.delete'::audit_action
    end,
    'admin_users',
    coalesce(new.id::text, old.id::text),
    case when TG_OP != 'INSERT' then
      jsonb_build_object('email', old.email, 'role', old.role, 'is_active', old.is_active)
    end,
    case when TG_OP != 'DELETE' then
      jsonb_build_object('email', new.email, 'role', new.role, 'is_active', new.is_active)
    end,
    'success'
  );
  return coalesce(new, old);
end;
$$;

create trigger audit_users
after insert or update or delete on admin_users
for each row execute function audit_user_change();

-- Auto-log permission changes
create or replace function audit_permission_change()
returns trigger language plpgsql security definer as $$
declare v_user admin_users%rowtype;
begin
  select * into v_user from admin_users where id = auth.uid();
  insert into audit_logs (
    user_id, user_email, user_role,
    action, resource, resource_id,
    old_data, new_data, status
  ) values (
    auth.uid(), v_user.email, v_user.role,
    case when coalesce(new.granted, false)
      then 'permission.grant'::audit_action
      else 'permission.revoke'::audit_action
    end,
    'admin_permissions',
    coalesce(new.user_id::text, old.user_id::text),
    case when TG_OP = 'UPDATE' then
      jsonb_build_object('permission', old.permission, 'granted', old.granted)
    end,
    jsonb_build_object('permission', new.permission, 'granted', new.granted),
    'success'
  );
  return coalesce(new, old);
end;
$$;

create trigger audit_permissions
after insert or update on admin_permissions
for each row execute function audit_permission_change();

-- Auto kill sessions when user is suspended
create or replace function auto_kill_sessions_on_suspend()
returns trigger language plpgsql security definer as $$
begin
  if old.is_active = true and new.is_active = false then
    delete from admin_sessions where user_id = new.id;
  end if;
  return new;
end;
$$;

create trigger kill_sessions_on_suspend
after update on admin_users
for each row execute function auto_kill_sessions_on_suspend();

-- ════════════════════════════════════════
-- RLS POLICIES
-- ════════════════════════════════════════

-- admin_users
alter table admin_users enable row level security;

create policy "self read" on admin_users
  for select using (id = auth.uid());

create policy "users read" on admin_users
  for select using (current_user_has('users.read'));

create policy "users write insert" on admin_users
  for insert with check (current_user_has('users.write'));

create policy "users write update" on admin_users
  for update using (current_user_has('users.write'));

-- admin_permissions
alter table admin_permissions enable row level security;

create policy "permissions manage" on admin_permissions
  using (current_user_has('users.write'));

-- role_permissions (read only for all admins)
alter table role_permissions enable row level security;

create policy "role permissions read" on role_permissions
  for select using (
    exists (select 1 from admin_users where id = auth.uid() and is_active = true)
  );

-- admin_totp (no RLS — service role only from Next.js)
alter table admin_totp enable row level security;

-- admin_invites
alter table admin_invites enable row level security;

create policy "invites manage" on admin_invites
  using (current_user_has('users.write'));

-- admin_sessions (users see only their own)
alter table admin_sessions enable row level security;

create policy "self sessions" on admin_sessions
  for select using (user_id = auth.uid());

-- app_config
alter table app_config enable row level security;

create policy "config read" on app_config
  for select using (current_user_has('config.read'));

create policy "config write insert" on app_config
  for insert with check (current_user_has('config.write'));

create policy "config write update" on app_config
  for update using (current_user_has('config.write'));

create policy "config delete" on app_config
  for delete using (current_user_has('config.write'));

-- app_config_history
alter table app_config_history enable row level security;

create policy "config history read" on app_config_history
  for select using (current_user_has('config.read'));

-- audit_logs
alter table audit_logs enable row level security;

create policy "logs read all" on audit_logs
  for select using (current_user_has('logs.read'));

create policy "self read own logs" on audit_logs
  for select using (user_id = auth.uid());

create policy "no direct insert" on audit_logs
  for insert with check (false);