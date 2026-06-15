-- =============================================================================
-- NOTION DYNAMIC PROPERTY SYSTEM — Migration
-- Run AFTER notion-sync-schema.sql (the initial schema)
-- Safe to re-run — all statements are idempotent
-- =============================================================================

-- ── 1. Raw + normalized property storage on notion_ticket_sync ────────────────

ALTER TABLE notion_ticket_sync
  ADD COLUMN IF NOT EXISTS raw_properties        JSONB NOT NULL DEFAULT '{}',
  ADD COLUMN IF NOT EXISTS normalized_properties  JSONB NOT NULL DEFAULT '{}',
  ADD COLUMN IF NOT EXISTS property_version       INTEGER NOT NULL DEFAULT 1;

COMMENT ON COLUMN notion_ticket_sync.raw_properties IS
  'Verbatim Notion API page.properties object — never transformed, preserved for debugging and re-parse.';
COMMENT ON COLUMN notion_ticket_sync.normalized_properties IS
  'Normalized envelope keyed by property name: { [name]: { type, label, value, raw, meta } }. Frontend renders this directly without knowing the schema.';
COMMENT ON COLUMN notion_ticket_sync.property_version IS
  'Incremented each time normalized_properties is recomputed — allows cache invalidation.';

-- ── 2. Schema versioning on notion_database_connections ───────────────────────

ALTER TABLE notion_database_connections
  ADD COLUMN IF NOT EXISTS schema_version      INTEGER NOT NULL DEFAULT 1,
  ADD COLUMN IF NOT EXISTS known_property_ids  TEXT[]  NOT NULL DEFAULT '{}';

COMMENT ON COLUMN notion_database_connections.schema_version IS
  'Bumped whenever schema_snapshot changes — used to invalidate cached introspections.';
COMMENT ON COLUMN notion_database_connections.known_property_ids IS
  'Array of Notion property IDs seen at last schema sync — used to detect newly added properties.';

-- ── 3. Schema Evolution Log ───────────────────────────────────────────────────
-- Tracks when new or renamed properties appear in Notion databases.
-- Populated automatically by the sync engine; no manual inserts needed.

CREATE TABLE IF NOT EXISTS notion_schema_evolution (
  id                      UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  database_connection_id  UUID        NOT NULL REFERENCES notion_database_connections(id) ON DELETE CASCADE,
  property_id             TEXT        NOT NULL,   -- Notion's internal property ID (stable across renames)
  property_name           TEXT        NOT NULL,   -- current display name (may change)
  property_type           TEXT        NOT NULL,   -- Notion property type string
  first_seen_at           TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  last_seen_at            TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  sample_value            JSONB,                  -- last normalized value snapshot
  UNIQUE(database_connection_id, property_id)
);

COMMENT ON TABLE notion_schema_evolution IS
  'Immutable record of every Notion property ever seen per database connection. Enables zero-downtime schema changes — new properties are auto-discovered and tracked without redeploys.';

CREATE INDEX IF NOT EXISTS idx_schema_evo_conn    ON notion_schema_evolution(database_connection_id);
CREATE INDEX IF NOT EXISTS idx_schema_evo_type    ON notion_schema_evolution(property_type);
CREATE INDEX IF NOT EXISTS idx_schema_evo_seen_at ON notion_schema_evolution(last_seen_at DESC);

-- ── 4. Dead-Letter Queue (separate table for observability) ───────────────────
-- Jobs that have exhausted max_retries are moved here instead of staying in
-- notion_sync_queue with status='dead_letter', giving cleaner queue health views.

CREATE TABLE IF NOT EXISTS notion_dead_letter_queue (
  id               UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  original_job_id  UUID,                          -- references notion_sync_queue.id (no FK — row may be cleaned up)
  job_type         TEXT        NOT NULL,
  payload          JSONB       NOT NULL,
  reason           TEXT        NOT NULL,          -- last error message
  retry_count      SMALLINT    NOT NULL DEFAULT 0,
  workspace_id     UUID        REFERENCES notion_workspaces(id) ON DELETE SET NULL,
  failed_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  replayed_at      TIMESTAMPTZ,                   -- set when ops replays the job
  created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE notion_dead_letter_queue IS
  'Exhausted queue jobs. Ops can replay via the Sync Health panel (replayDeadLetterJobs action). Separate table keeps queue health metrics clean.';

CREATE INDEX IF NOT EXISTS idx_dlq_workspace ON notion_dead_letter_queue(workspace_id);
CREATE INDEX IF NOT EXISTS idx_dlq_job_type  ON notion_dead_letter_queue(job_type);
CREATE INDEX IF NOT EXISTS idx_dlq_failed_at ON notion_dead_letter_queue(failed_at DESC);
CREATE INDEX IF NOT EXISTS idx_dlq_replayed  ON notion_dead_letter_queue(replayed_at) WHERE replayed_at IS NULL;

-- ── 5. Webhook multi-workspace routing ───────────────────────────────────────
-- Adds the raw Notion workspace_id string to notion_webhooks so the webhook
-- handler can match the incoming X-Notion-Workspace-Id header without a join.

ALTER TABLE notion_webhooks
  ADD COLUMN IF NOT EXISTS notion_workspace_id TEXT;

-- Backfill from joined workspace table
UPDATE notion_webhooks nwh
SET    notion_workspace_id = nws.workspace_id
FROM   notion_workspaces nws
WHERE  nwh.workspace_id       = nws.id
  AND  nwh.notion_workspace_id IS NULL;

CREATE INDEX IF NOT EXISTS idx_webhooks_notion_ws_id
  ON notion_webhooks(notion_workspace_id)
  WHERE notion_workspace_id IS NOT NULL;

-- ── 6. GIN indexes for JSONB query performance ────────────────────────────────

CREATE INDEX IF NOT EXISTS idx_ticket_sync_raw_props
  ON notion_ticket_sync USING gin(raw_properties jsonb_path_ops);

CREATE INDEX IF NOT EXISTS idx_ticket_sync_norm_props
  ON notion_ticket_sync USING gin(normalized_properties jsonb_path_ops);

-- Partial index — only index tickets that have been fully synced (have real data)
CREATE INDEX IF NOT EXISTS idx_ticket_sync_norm_status
  ON notion_ticket_sync((normalized_properties->>'cached_status'))
  WHERE sync_status = 'synced';

-- ── 7. Sync queue — add workspace_id for observability ───────────────────────

ALTER TABLE notion_sync_queue
  ADD COLUMN IF NOT EXISTS workspace_id UUID REFERENCES notion_workspaces(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_sync_queue_workspace
  ON notion_sync_queue(workspace_id)
  WHERE workspace_id IS NOT NULL;

-- ── 8. Supabase Realtime — enable new tables ──────────────────────────────────
-- Run manually in: Supabase Dashboard → Database → Replication

-- ALTER PUBLICATION supabase_realtime ADD TABLE notion_schema_evolution;
-- ALTER PUBLICATION supabase_realtime ADD TABLE notion_dead_letter_queue;

-- ── 9. Trigger — keep updated_at fresh on new tables ─────────────────────────

DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_trigger WHERE tgname = 'trg_schema_evo_ua'
  ) THEN
    CREATE TRIGGER trg_schema_evo_ua
      BEFORE UPDATE ON notion_schema_evolution
      FOR EACH ROW EXECUTE FUNCTION touch_updated_at();
  END IF;
END $$;

-- ── 10. Recommended RLS policies (adapt to your security model) ───────────────
-- These are additive — adjust based on your existing RLS setup.

-- notion_schema_evolution: readable by authenticated service role only (no anon access)
-- ALTER TABLE notion_schema_evolution ENABLE ROW LEVEL SECURITY;
-- CREATE POLICY "service_role_all" ON notion_schema_evolution
--   USING (true) WITH CHECK (true);  -- service_role bypasses RLS anyway

-- notion_dead_letter_queue: ops team only via service role
-- ALTER TABLE notion_dead_letter_queue ENABLE ROW LEVEL SECURITY;
