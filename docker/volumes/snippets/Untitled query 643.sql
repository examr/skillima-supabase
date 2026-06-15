-- =============================================================================
-- NOTION TICKET SYNC SYSTEM — Database Schema
-- Run against your Supabase project SQL editor
-- =============================================================================

-- 1. Notion Workspace Connections
CREATE TABLE IF NOT EXISTS notion_workspaces (
  id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  connected_by          UUID NOT NULL REFERENCES admin_users(id),
  workspace_id          TEXT NOT NULL UNIQUE,
  workspace_name        TEXT NOT NULL,
  workspace_icon        TEXT,
  bot_id                TEXT NOT NULL,
  access_token_enc      TEXT NOT NULL,           -- AES-256-CBC encrypted, never expose
  token_type            TEXT NOT NULL DEFAULT 'bearer',
  owner_type            TEXT NOT NULL,           -- 'workspace' | 'user'
  owner_notion_user_id  TEXT,
  is_active             BOOLEAN NOT NULL DEFAULT true,
  connected_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  last_verified_at      TIMESTAMPTZ,
  revoked_at            TIMESTAMPTZ,
  created_at            TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at            TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_notion_workspaces_connected_by ON notion_workspaces(connected_by);
CREATE INDEX IF NOT EXISTS idx_notion_workspaces_active ON notion_workspaces(is_active) WHERE is_active = true;

-- 2. Database Connections (one active per board type)
CREATE TABLE IF NOT EXISTS notion_database_connections (
  id                      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  workspace_id            UUID NOT NULL REFERENCES notion_workspaces(id) ON DELETE CASCADE,
  notion_database_id      TEXT NOT NULL,
  database_name           TEXT NOT NULL,
  database_icon           TEXT,
  board_type              TEXT NOT NULL,
  -- 'support' | 'bugs' | 'mentor' | 'billing' | 'infra' | 'ops'
  property_mappings       JSONB NOT NULL DEFAULT '{}',
  -- { "title": "Name", "status": "Status", "priority": "Priority", "assignee": "Assignee" }
  status_mappings         JSONB NOT NULL DEFAULT '{}',
  -- { "todo": "To Do", "in_progress": "In Progress", "review": "In Review", "done": "Done", "closed": "Closed" }
  schema_snapshot         JSONB,
  is_active               BOOLEAN NOT NULL DEFAULT true,
  last_schema_sync_at     TIMESTAMPTZ,
  created_by              UUID NOT NULL REFERENCES admin_users(id),
  created_at              TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at              TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE(workspace_id, notion_database_id)
);

CREATE INDEX IF NOT EXISTS idx_notion_db_conns_workspace ON notion_database_connections(workspace_id);
CREATE INDEX IF NOT EXISTS idx_notion_db_conns_board_type ON notion_database_connections(board_type) WHERE is_active = true;

-- 3. Ticket Sync Cache (local mirror of Notion pages)
CREATE TABLE IF NOT EXISTS notion_ticket_sync (
  id                      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  database_connection_id  UUID NOT NULL REFERENCES notion_database_connections(id),
  notion_page_id          TEXT NOT NULL UNIQUE,
  notion_page_url         TEXT,
  cached_title            TEXT NOT NULL,
  cached_status           TEXT,            -- internal: todo | in_progress | review | done | closed
  cached_notion_status    TEXT,            -- raw Notion option name
  cached_priority         TEXT,            -- urgent | high | medium | low
  cached_assignee_name    TEXT,
  cached_assignee_notion_id TEXT,
  cached_labels           TEXT[],
  created_by_admin_id     UUID REFERENCES admin_users(id),
  created_by_platform_uid UUID,            -- profiles.id
  category                TEXT,
  -- 'student_support' | 'mentor_support' | 'platform_ops' | 'internal'
  local_meta              JSONB DEFAULT '{}',
  sync_status             TEXT NOT NULL DEFAULT 'synced',
  -- 'synced' | 'pending_create' | 'pending_update' | 'failed' | 'conflict' | 'archived'
  last_synced_at          TIMESTAMPTZ,
  notion_last_edited_time TEXT,
  sync_error              TEXT,
  sync_retry_count        INTEGER NOT NULL DEFAULT 0,
  last_notified_status    TEXT,
  last_notified_at        TIMESTAMPTZ,
  created_at              TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at              TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_ticket_sync_db_conn   ON notion_ticket_sync(database_connection_id);
CREATE INDEX IF NOT EXISTS idx_ticket_sync_admin     ON notion_ticket_sync(created_by_admin_id);
CREATE INDEX IF NOT EXISTS idx_ticket_sync_uid       ON notion_ticket_sync(created_by_platform_uid);
CREATE INDEX IF NOT EXISTS idx_ticket_sync_status    ON notion_ticket_sync(cached_status);
CREATE INDEX IF NOT EXISTS idx_ticket_sync_fail      ON notion_ticket_sync(sync_status) WHERE sync_status != 'synced';
CREATE INDEX IF NOT EXISTS idx_ticket_sync_updated   ON notion_ticket_sync(updated_at DESC);

-- 4. Sync Events (immutable audit trail)
CREATE TABLE IF NOT EXISTS notion_sync_events (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  ticket_sync_id  UUID REFERENCES notion_ticket_sync(id) ON DELETE SET NULL,
  notion_page_id  TEXT,
  event_type      TEXT NOT NULL,
  direction       TEXT NOT NULL,           -- 'skillima→notion' | 'notion→skillima'
  old_status      TEXT,
  new_status      TEXT,
  payload         JSONB,
  proc_status     TEXT NOT NULL DEFAULT 'processed',
  -- 'processed' | 'failed' | 'skipped' | 'duplicate'
  error_message   TEXT,
  notion_event_id TEXT,
  processed_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_sync_events_ticket      ON notion_sync_events(ticket_sync_id);
CREATE INDEX IF NOT EXISTS idx_sync_events_page        ON notion_sync_events(notion_page_id);
CREATE INDEX IF NOT EXISTS idx_sync_events_dedup       ON notion_sync_events(notion_event_id) WHERE notion_event_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_sync_events_created     ON notion_sync_events(created_at DESC);

-- 5. Webhook Registration & Health
CREATE TABLE IF NOT EXISTS notion_webhooks (
  id                      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  workspace_id            UUID NOT NULL REFERENCES notion_workspaces(id) ON DELETE CASCADE,
  database_connection_id  UUID REFERENCES notion_database_connections(id) ON DELETE SET NULL,
  notion_webhook_id       TEXT,
  endpoint_url            TEXT NOT NULL,
  webhook_secret          TEXT NOT NULL,
  status                  TEXT NOT NULL DEFAULT 'active',
  -- 'active' | 'inactive' | 'failed' | 'unverified'
  last_received_at        TIMESTAMPTZ,
  event_count             BIGINT NOT NULL DEFAULT 0,
  failure_count           INTEGER NOT NULL DEFAULT 0,
  last_failure_at         TIMESTAMPTZ,
  last_failure_reason     TEXT,
  created_at              TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at              TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_notion_webhooks_workspace ON notion_webhooks(workspace_id);

-- 6. Ticket Notifications
CREATE TABLE IF NOT EXISTS ticket_notifications (
  id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  ticket_sync_id      UUID NOT NULL REFERENCES notion_ticket_sync(id) ON DELETE CASCADE,
  recipient_admin_id  UUID REFERENCES admin_users(id),
  recipient_uid       UUID,
  notif_type          TEXT NOT NULL,       -- 'push' | 'email' | 'in_app'
  title               TEXT NOT NULL,
  body                TEXT NOT NULL,
  data                JSONB DEFAULT '{}',
  status              TEXT NOT NULL DEFAULT 'pending',
  -- 'pending' | 'sent' | 'failed' | 'read'
  sent_at             TIMESTAMPTZ,
  read_at             TIMESTAMPTZ,
  error_message       TEXT,
  retry_count         INTEGER NOT NULL DEFAULT 0,
  created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_ticket_notifs_ticket  ON ticket_notifications(ticket_sync_id);
CREATE INDEX IF NOT EXISTS idx_ticket_notifs_admin   ON ticket_notifications(recipient_admin_id);
CREATE INDEX IF NOT EXISTS idx_ticket_notifs_pending ON ticket_notifications(status) WHERE status = 'pending';
CREATE INDEX IF NOT EXISTS idx_ticket_notifs_created ON ticket_notifications(created_at DESC);

-- 7. Ticket Activity Log (timeline per ticket)
CREATE TABLE IF NOT EXISTS ticket_activity_logs (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  ticket_sync_id  UUID NOT NULL REFERENCES notion_ticket_sync(id) ON DELETE CASCADE,
  event_type      TEXT NOT NULL,
  -- 'created' | 'status_changed' | 'comment_added' | 'assigned'
  -- 'priority_changed' | 'archived' | 'synced' | 'notification_sent'
  actor_type      TEXT NOT NULL,           -- 'admin' | 'platform_user' | 'notion_user' | 'system'
  actor_id        TEXT,
  actor_name      TEXT,
  actor_email     TEXT,
  old_value       TEXT,
  new_value       TEXT,
  metadata        JSONB DEFAULT '{}',
  notion_event_id TEXT,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_ticket_activity_ticket  ON ticket_activity_logs(ticket_sync_id);
CREATE INDEX IF NOT EXISTS idx_ticket_activity_created ON ticket_activity_logs(ticket_sync_id, created_at ASC);
CREATE INDEX IF NOT EXISTS idx_ticket_activity_dedup   ON ticket_activity_logs(notion_event_id)
  WHERE notion_event_id IS NOT NULL;

-- 8. Sync Queue (database-backed reliable async jobs)
CREATE TABLE IF NOT EXISTS notion_sync_queue (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  job_type         TEXT NOT NULL,
  -- 'create_notion_page' | 'process_webhook_event'
  -- 'sync_ticket' | 'send_ticket_notification' | 'refresh_schema'
  payload          JSONB NOT NULL,
  status           TEXT NOT NULL DEFAULT 'pending',
  -- 'pending' | 'processing' | 'completed' | 'failed' | 'dead_letter'
  priority         SMALLINT NOT NULL DEFAULT 5,
  max_retries      SMALLINT NOT NULL DEFAULT 3,
  retry_count      SMALLINT NOT NULL DEFAULT 0,
  next_run_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  locked_at        TIMESTAMPTZ,
  locked_by        TEXT,
  completed_at     TIMESTAMPTZ,
  error_message    TEXT,
  idempotency_key  TEXT UNIQUE,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_sync_queue_pending ON notion_sync_queue(priority ASC, next_run_at ASC)
  WHERE status = 'pending';
CREATE INDEX IF NOT EXISTS idx_sync_queue_locked ON notion_sync_queue(locked_at)
  WHERE status = 'processing';

-- 9. Rate Limit State
CREATE TABLE IF NOT EXISTS notion_rate_limit_state (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  workspace_id    UUID NOT NULL REFERENCES notion_workspaces(id) ON DELETE CASCADE,
  window_start    TIMESTAMPTZ NOT NULL,
  request_count   INTEGER NOT NULL DEFAULT 0,
  window_end      TIMESTAMPTZ NOT NULL,
  UNIQUE(workspace_id, window_start)
);

-- =============================================================================
-- Triggers — keep updated_at fresh
-- =============================================================================

CREATE OR REPLACE FUNCTION touch_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN NEW.updated_at = NOW(); RETURN NEW; END;
$$;

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_notion_workspaces_ua') THEN
    CREATE TRIGGER trg_notion_workspaces_ua
      BEFORE UPDATE ON notion_workspaces FOR EACH ROW EXECUTE FUNCTION touch_updated_at();
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_notion_db_conns_ua') THEN
    CREATE TRIGGER trg_notion_db_conns_ua
      BEFORE UPDATE ON notion_database_connections FOR EACH ROW EXECUTE FUNCTION touch_updated_at();
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_ticket_sync_ua') THEN
    CREATE TRIGGER trg_ticket_sync_ua
      BEFORE UPDATE ON notion_ticket_sync FOR EACH ROW EXECUTE FUNCTION touch_updated_at();
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_sync_queue_ua') THEN
    CREATE TRIGGER trg_sync_queue_ua
      BEFORE UPDATE ON notion_sync_queue FOR EACH ROW EXECUTE FUNCTION touch_updated_at();
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_notion_webhooks_ua') THEN
    CREATE TRIGGER trg_notion_webhooks_ua
      BEFORE UPDATE ON notion_webhooks FOR EACH ROW EXECUTE FUNCTION touch_updated_at();
  END IF;
END $$;

-- =============================================================================
-- Supabase Realtime — enable for live UI updates
-- Run in: Supabase Dashboard → Database → Replication → supabase_realtime
-- =============================================================================

-- ALTER PUBLICATION supabase_realtime ADD TABLE notion_ticket_sync;
-- ALTER PUBLICATION supabase_realtime ADD TABLE ticket_notifications;
-- ALTER PUBLICATION supabase_realtime ADD TABLE ticket_activity_logs;
