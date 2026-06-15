-- ── Notion User ID column on admin_users ─────────────────────────────────────
ALTER TABLE public.admin_users ADD COLUMN IF NOT EXISTS notion_user_id TEXT;
