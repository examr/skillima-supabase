-- ── Mentor Verification Log (admin schema) ────────────────────────────────────
-- Lives in the `admin` schema so only the service_role key (used by the ops
-- dashboard) and Supabase superusers can access it. Public/anon/authenticated
-- roles have no access at all.

create table if not exists admin.mentor_verification_log (
  id               uuid primary key default gen_random_uuid(),
  mentor_user_id   uuid not null,          -- references public.profiles(id)
  mentor_name      text not null,
  mentor_email     text not null,
  decision         text not null check (decision in ('approved', 'rejected', 'pending')),
  note             text,
  reviewed_by_id   uuid,                   -- references admin.admin_users(id)
  reviewed_by_email text not null,
  reviewed_by_name  text not null,
  created_at       timestamptz not null default now()
);

comment on table admin.mentor_verification_log is
  'Audit trail of all mentor application review decisions. '
  'Stored in the admin schema — only accessible via service_role key.';

create index if not exists idx_mvlog_mentor   on admin.mentor_verification_log (mentor_user_id);
create index if not exists idx_mvlog_reviewer on admin.mentor_verification_log (reviewed_by_id);
create index if not exists idx_mvlog_created  on admin.mentor_verification_log (created_at desc);

-- Revoke all public access — only service_role (ops dashboard) can read/write
revoke all on admin.mentor_verification_log from anon, authenticated;