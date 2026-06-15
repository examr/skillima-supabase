-- ── FCM token column on admin_users ─────────────────────────────────────────
ALTER TABLE admin_users
  ADD COLUMN IF NOT EXISTS fcm_token text;

-- ── Admin notifications table ─────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS admin_notifications (
  id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     uuid        NOT NULL REFERENCES admin_users(id) ON DELETE CASCADE,
  title       text        NOT NULL,
  body        text        NOT NULL,
  link        text,                          -- optional deep link (e.g. /dashboard/logs)
  sent_by     uuid        REFERENCES admin_users(id) ON DELETE SET NULL,
  sent_by_name text,
  read_at     timestamptz,
  created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS admin_notifications_user_created
  ON admin_notifications (user_id, created_at DESC);

-- Only super_admin can insert/delete; all admin users can read their own rows
-- (Row-level security not enforced here — app logic gates access via service_role)
