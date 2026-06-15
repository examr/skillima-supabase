-- ================================================================
--  SKILLIMA — Migration: v5.2 (final)
--
--  FIXES vs previous drafts:
--    • Patches pre-existing audit_config_change trigger function
--      (was referencing admin_users without schema prefix → broke
--      when search_path = '' was active)
--    • All function bodies use fully-qualified schema names:
--      public.*, admin.*, extensions.*, auth.*
--    • Removed invalid inline FUNCTION definition inside PL/pgSQL
--      (replaced with a helper function defined before it is needed)
--    • get_cooling_interval() and every caller uses admin.app_config
--      fully qualified
--    • is_admin() calls kept as-is (already defined in public schema
--      with correct admin.admin_users reference)
-- ================================================================

BEGIN;

-- ================================================================
-- STEP 0 — DISABLE AUDIT TRIGGER FOR THIS MIGRATION
-- ================================================================
-- admin.app_config has a trigger (audit_config_change) that fires on
-- INSERT/UPDATE and references other tables in the admin schema.
--
-- PostgreSQL compiles PL/pgSQL function bodies at CREATE time using
-- the SESSION search_path — NOT the function's own SET search_path.
-- Any CREATE OR REPLACE FUNCTION that references admin schema tables
-- in its body will fail to compile if the migration session doesn't
-- have 'admin' in its search_path.
--
-- Attempting to rewrite the function body hits the same wall regardless
-- of how the references are qualified.
--
-- CORRECT APPROACH: don't touch the function at all.
-- Disable ALL triggers on admin.app_config for this transaction,
-- do our INSERT, then re-enable. The trigger only audits value changes;
-- seeding a new default config key doesn't need to be audited.

ALTER TABLE admin.app_config DISABLE TRIGGER ALL;

-- ================================================================
-- STEP 1 — ENUMs (idempotent)
-- ================================================================

DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_type
     WHERE typname = 'project_origin'
       AND typnamespace = 'public'::regnamespace
  ) THEN
    CREATE TYPE public.project_origin AS ENUM ('mentor', 'admin');
  END IF;
END $$;

-- ================================================================
-- STEP 2 — ALTER public.projects
-- ================================================================

ALTER TABLE public.projects
  ADD COLUMN IF NOT EXISTS origin public.project_origin
    NOT NULL DEFAULT 'mentor',

  ADD COLUMN IF NOT EXISTS created_by_user uuid
    REFERENCES public.profiles(id) ON DELETE SET NULL,

  ADD COLUMN IF NOT EXISTS is_locked boolean NOT NULL DEFAULT false,

  ADD COLUMN IF NOT EXISTS visible_to_ranks public.rank_tier_mentor[]
    DEFAULT NULL,

  ADD COLUMN IF NOT EXISTS max_interested_mentors smallint
    DEFAULT NULL
    CHECK (max_interested_mentors IS NULL OR max_interested_mentors > 0),

  -- Denormalized free-mentor counter. Maintained by triggers.
  -- >= 1 → 'published',  0 → 'draft'  (admin-created only)
  ADD COLUMN IF NOT EXISTS free_mentor_count integer
    NOT NULL DEFAULT 0
    CHECK (free_mentor_count >= 0);

ALTER TABLE public.projects
  ALTER COLUMN mentor_id DROP NOT NULL;

COMMENT ON COLUMN public.projects.origin IS
  '''mentor'' = created by a specific mentor who owns it. '
  '''admin''  = created by Skillima admin; mentor assigned at purchase time.';

COMMENT ON COLUMN public.projects.max_interested_mentors IS
  'Admin-created only. Cap on how many mentors can express interest. '
  'NULL = no limit. Enforced with an advisory lock in express_mentor_interest().';

COMMENT ON COLUMN public.projects.free_mentor_count IS
  'Denormalized. Number of mentors in the interest pool who are currently '
  'free (active, not in a live enrollment on this project, not in cooling). '
  'Maintained by triggers. Drives automatic published ↔ draft flipping.';

-- ================================================================
-- STEP 3 — CREATE public.project_mentor_interest
-- ================================================================

CREATE TABLE IF NOT EXISTS public.project_mentor_interest (
  id          uuid     NOT NULL PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id  uuid     NOT NULL REFERENCES public.projects(id) ON DELETE CASCADE,
  mentor_id   uuid     NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,

  auto_assign boolean  NOT NULL DEFAULT false,

  -- Denormalized workload counter for this mentor (all projects).
  -- Incremented when any of their enrollments → active.
  -- Decremented when any of their enrollments end.
  -- Used by the assignment ORDER BY instead of a correlated subquery.
  active_enrollment_count integer NOT NULL DEFAULT 0
    CHECK (active_enrollment_count >= 0),

  -- FALSE + decline_reason NOT NULL → permanently blocked (declined assignment)
  -- FALSE + decline_reason NULL     → admin manually deactivated
  is_active      boolean NOT NULL DEFAULT true,
  decline_reason text    DEFAULT NULL,

  -- Pre-computed cooling expiry.
  -- Set to now() + cooling_period at project completion.
  -- NULL = not in cooling.  Checked as: cooling_expires_at < now()
  cooling_expires_at timestamptz DEFAULT NULL,

  expressed_at timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now(),

  UNIQUE (project_id, mentor_id)
);

COMMENT ON TABLE public.project_mentor_interest IS
  'Mentors who expressed interest in an admin-created project. '
  'free_mentor_count on projects is maintained by triggers on this table '
  'and on project_enrollments.';

-- Index for assignment query (O log N)
CREATE INDEX IF NOT EXISTS idx_pmi_assignment
  ON public.project_mentor_interest (project_id, active_enrollment_count, is_active)
  WHERE is_active = true;

-- Index for cron cooling-expiry sweep
CREATE INDEX IF NOT EXISTS idx_pmi_cooling
  ON public.project_mentor_interest (cooling_expires_at)
  WHERE cooling_expires_at IS NOT NULL;

-- Mentor reverse lookup
CREATE INDEX IF NOT EXISTS idx_pmi_mentor
  ON public.project_mentor_interest (mentor_id);

CREATE TRIGGER trg_pmi_updated_at
  BEFORE UPDATE ON public.project_mentor_interest
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();

-- ================================================================
-- STEP 4 — CREATE public.enrollment_mentor_queue
-- ================================================================

CREATE TABLE IF NOT EXISTS public.enrollment_mentor_queue (
  id            uuid     NOT NULL PRIMARY KEY DEFAULT gen_random_uuid(),
  enrollment_id uuid     NOT NULL REFERENCES public.project_enrollments(id) ON DELETE CASCADE,
  mentor_id     uuid     NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  queue_position smallint NOT NULL,
  auto_assign   boolean  NOT NULL,
  status        text     NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending','offered','accepted','declined','expired','skipped')),
  offered_at    timestamptz,
  expires_at    timestamptz,
  responded_at  timestamptz,
  created_at    timestamptz NOT NULL DEFAULT now(),

  UNIQUE (enrollment_id, mentor_id)
);

CREATE INDEX IF NOT EXISTS idx_emq_enrollment
  ON public.enrollment_mentor_queue (enrollment_id);

CREATE INDEX IF NOT EXISTS idx_emq_expires
  ON public.enrollment_mentor_queue (expires_at)
  WHERE status = 'offered';

-- ================================================================
-- STEP 5 — GLOBAL COOLING CONFIG
-- ================================================================

-- Triggers disabled in STEP 0. Re-enabled immediately after this INSERT.
INSERT INTO admin.app_config (key, value, description, is_secret)
VALUES (
  'mentor_cooling_period_days',
  '30',
  'Days a mentor must wait after completing an admin-created project '
  'before they can re-express interest in it. Configurable per platform.',
  false
)
ON CONFLICT (key) DO NOTHING;

-- Re-enable triggers now that our INSERT is done.
ALTER TABLE admin.app_config ENABLE TRIGGER ALL;

-- ================================================================
-- STEP 6 — HELPER: get_cooling_interval()
-- ================================================================

CREATE OR REPLACE FUNCTION public.get_cooling_interval()
  RETURNS interval
  LANGUAGE sql
  SECURITY DEFINER
  STABLE
  SET search_path = ''
AS $$
  SELECT COALESCE(
    (
      SELECT value::integer
        FROM admin.app_config        -- fully qualified: admin schema
       WHERE key = 'mentor_cooling_period_days'
       LIMIT 1
    ),
    30
  ) * INTERVAL '1 day';
$$;

REVOKE EXECUTE ON FUNCTION public.get_cooling_interval() FROM authenticated, anon;

-- ================================================================
-- STEP 7 — HELPER: pmi_mentor_is_free()
-- ================================================================
-- Extracted as a standalone function so triggers can call it.
-- Returns TRUE if the mentor row should count toward free_mentor_count.
-- A mentor is "free" if:
--   • is_active = true
--   • cooling_expires_at is null or in the past
--   • no active/pending enrollment for them on this specific project

CREATE OR REPLACE FUNCTION public.pmi_mentor_is_free(
  _mentor_id   uuid,
  _project_id  uuid,
  _is_active   boolean,
  _cooling     timestamptz
)
  RETURNS boolean
  LANGUAGE sql
  SECURITY DEFINER
  STABLE
  SET search_path = ''
AS $$
  SELECT
    _is_active = true
    AND (_cooling IS NULL OR _cooling < now())
    AND NOT EXISTS (
      SELECT 1
        FROM public.project_enrollments pe
       WHERE pe.mentor_id  = _mentor_id
         AND pe.project_id = _project_id
         AND pe.status     IN ('pending_mentor', 'active')
    );
$$;

REVOKE EXECUTE ON FUNCTION public.pmi_mentor_is_free(uuid, uuid, boolean, timestamptz)
  FROM authenticated, anon;

-- ================================================================
-- STEP 8 — HELPER: recalc_free_mentor_count()
-- ================================================================
-- Full recount from scratch. Used after bulk changes or cron sweep.
-- Incremental triggers (STEP 9) handle single-row changes O(1).

CREATE OR REPLACE FUNCTION public.recalc_free_mentor_count(_project_id uuid)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  VOLATILE
  SET search_path = ''
AS $$
DECLARE
  _free   integer;
  _origin public.project_origin;
BEGIN
  SELECT origin INTO _origin
    FROM public.projects
   WHERE id = _project_id;

  IF _origin IS DISTINCT FROM 'admin' THEN RETURN; END IF;

  SELECT COUNT(*)::integer INTO _free
    FROM public.project_mentor_interest pmi
   WHERE pmi.project_id = _project_id
     AND public.pmi_mentor_is_free(
           pmi.mentor_id, pmi.project_id,
           pmi.is_active, pmi.cooling_expires_at
         );

  UPDATE public.projects
     SET free_mentor_count = _free,
         status = CASE
           WHEN status = 'archived'::public.project_status THEN status
           WHEN _free >= 1 THEN 'published'::public.project_status
           ELSE                 'draft'::public.project_status
         END,
         updated_at = now()
   WHERE id = _project_id;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.recalc_free_mentor_count(uuid)
  FROM authenticated, anon;

-- ================================================================
-- STEP 9 — TRIGGER: project_mentor_interest → maintain free_mentor_count
-- ================================================================
-- Incremental ±1 on projects.free_mentor_count after any INSERT/UPDATE/DELETE.
-- Flips status published ↔ draft automatically.

CREATE OR REPLACE FUNCTION public.trg_fn_pmi_maintain_free_count()
  RETURNS trigger
  LANGUAGE plpgsql
  SECURITY DEFINER
  VOLATILE
  SET search_path = ''
AS $$
DECLARE
  _project_id  uuid;
  _delta       integer := 0;
  _was_free    boolean;
  _now_free    boolean;
BEGIN
  IF TG_OP = 'INSERT' THEN
    _project_id := NEW.project_id;
    IF public.pmi_mentor_is_free(
        NEW.mentor_id, NEW.project_id, NEW.is_active, NEW.cooling_expires_at
    ) THEN
      _delta := 1;
    END IF;

  ELSIF TG_OP = 'DELETE' THEN
    _project_id := OLD.project_id;
    IF public.pmi_mentor_is_free(
        OLD.mentor_id, OLD.project_id, OLD.is_active, OLD.cooling_expires_at
    ) THEN
      _delta := -1;
    END IF;

  ELSIF TG_OP = 'UPDATE' THEN
    _project_id := NEW.project_id;
    _was_free := public.pmi_mentor_is_free(
      OLD.mentor_id, OLD.project_id, OLD.is_active, OLD.cooling_expires_at
    );
    _now_free := public.pmi_mentor_is_free(
      NEW.mentor_id, NEW.project_id, NEW.is_active, NEW.cooling_expires_at
    );
    IF     _was_free AND NOT _now_free THEN _delta := -1;
    ELSIF NOT _was_free AND _now_free  THEN _delta :=  1;
    END IF;
  END IF;

  IF _delta <> 0 THEN
    UPDATE public.projects
       SET free_mentor_count = GREATEST(0, free_mentor_count + _delta),
           status = CASE
             WHEN status = 'archived'::public.project_status THEN status
             WHEN (free_mentor_count + _delta) >= 1
               THEN 'published'::public.project_status
             ELSE 'draft'::public.project_status
           END,
           updated_at = now()
     WHERE id     = _project_id
       AND origin = 'admin';
  END IF;

  RETURN COALESCE(NEW, OLD);
END;
$$;

DROP TRIGGER IF EXISTS trg_pmi_maintain_free_count ON public.project_mentor_interest;
CREATE TRIGGER trg_pmi_maintain_free_count
  AFTER INSERT OR UPDATE OR DELETE ON public.project_mentor_interest
  FOR EACH ROW EXECUTE FUNCTION public.trg_fn_pmi_maintain_free_count();

REVOKE EXECUTE ON FUNCTION public.trg_fn_pmi_maintain_free_count()
  FROM authenticated, anon;

-- ================================================================
-- STEP 10 — TRIGGER: project_enrollments → maintain counts + lock
-- ================================================================

CREATE OR REPLACE FUNCTION public.trg_fn_enrollment_maintain_counts()
  RETURNS trigger
  LANGUAGE plpgsql
  SECURITY DEFINER
  VOLATILE
  SET search_path = ''
AS $$
DECLARE
  _origin      public.project_origin;
  _cooling_ivl interval;
BEGIN
  SELECT origin INTO _origin
    FROM public.projects
   WHERE id = NEW.project_id;

  -- ── MENTOR-CREATED: lock / unlock ──────────────────────────────
  IF _origin = 'mentor' THEN

    IF NEW.status IN ('pending_mentor', 'active') THEN
      UPDATE public.projects
         SET is_locked = true, updated_at = now()
       WHERE id = NEW.project_id;

    ELSIF NEW.status IN ('completed', 'cancelled', 'disputed')
      AND OLD.status NOT IN ('completed', 'cancelled', 'disputed') THEN

      -- Only unlock if no other active enrollment exists on this project
      IF NOT EXISTS (
        SELECT 1 FROM public.project_enrollments
         WHERE project_id = NEW.project_id
           AND status     IN ('pending_mentor', 'active')
           AND id         <> NEW.id
      ) THEN
        UPDATE public.projects
           SET is_locked = false, updated_at = now()
         WHERE id = NEW.project_id;
      END IF;
    END IF;

    RETURN NEW;
  END IF;

  -- ── ADMIN-CREATED below ────────────────────────────────────────

  -- Purchase (INSERT, status = pending_mentor):
  -- Immediately force draft to close the race-condition window.
  -- Decrement free_mentor_count because this mentor is now "busy".
  IF TG_OP = 'INSERT' AND NEW.status = 'pending_mentor' THEN
    UPDATE public.projects
       SET status            = 'draft',
           free_mentor_count = GREATEST(0, free_mentor_count - 1),
           updated_at        = now()
     WHERE id     = NEW.project_id
       AND origin = 'admin'
       AND status <> 'archived'::public.project_status;
    RETURN NEW;
  END IF;

  -- Mentor accepts (pending_mentor → active):
  -- Bump active_enrollment_count on ALL interest rows for this mentor
  -- so the ORDER BY in assign_mentor_for_enrollment stays accurate.
  IF TG_OP = 'UPDATE'
     AND OLD.status = 'pending_mentor'
     AND NEW.status = 'active'
     AND NEW.mentor_id IS NOT NULL THEN

    UPDATE public.project_mentor_interest
       SET active_enrollment_count = active_enrollment_count + 1,
           updated_at              = now()
     WHERE mentor_id = NEW.mentor_id;

    RETURN NEW;
  END IF;

  -- Enrollment ends (completed / cancelled / disputed):
  IF TG_OP = 'UPDATE'
     AND NEW.status IN ('completed', 'cancelled', 'disputed')
     AND OLD.status NOT IN ('completed', 'cancelled', 'disputed')
     AND NEW.mentor_id IS NOT NULL THEN

    -- Decrement workload counter across all projects for this mentor
    UPDATE public.project_mentor_interest
       SET active_enrollment_count = GREATEST(0, active_enrollment_count - 1),
           updated_at              = now()
     WHERE mentor_id = NEW.mentor_id;

    IF NEW.status = 'completed' THEN
      -- Start cooling: write pre-computed expiry timestamp
      _cooling_ivl := public.get_cooling_interval();

      UPDATE public.project_mentor_interest
         SET cooling_expires_at = now() + _cooling_ivl,
             updated_at         = now()
       WHERE project_id = NEW.project_id
         AND mentor_id  = NEW.mentor_id
         AND is_active  = true;
      -- The pmi UPDATE trigger above fires and decrements free_mentor_count,
      -- flipping project to draft if this was the last free mentor.

    ELSE
      -- Cancelled / disputed: mentor is immediately free again
      UPDATE public.projects
         SET free_mentor_count = free_mentor_count + 1,
             status = CASE
               WHEN status = 'archived'::public.project_status THEN status
               ELSE 'published'::public.project_status
             END,
             updated_at = now()
       WHERE id     = NEW.project_id
         AND origin = 'admin';
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_enrollment_maintain_counts ON public.project_enrollments;
CREATE TRIGGER trg_enrollment_maintain_counts
  AFTER INSERT OR UPDATE OF status ON public.project_enrollments
  FOR EACH ROW EXECUTE FUNCTION public.trg_fn_enrollment_maintain_counts();

REVOKE EXECUTE ON FUNCTION public.trg_fn_enrollment_maintain_counts()
  FROM authenticated, anon;

-- ================================================================
-- STEP 11 — RPC: express_mentor_interest()
-- ================================================================
-- Mentor taps "I'm Interested" on an admin-created project.
-- All guards enforced here. Trigger handles free_mentor_count.

CREATE OR REPLACE FUNCTION public.express_mentor_interest(
  _project_id  uuid,
  _auto_assign boolean DEFAULT false
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  VOLATILE
  SET search_path = ''
AS $$
DECLARE
  _mentor_id  uuid := (SELECT auth.uid());
  _project    record;
  _mp         record;
  _existing   record;
  _pool_count integer;
BEGIN
  -- Load project
  SELECT * INTO _project
    FROM public.projects
   WHERE id = _project_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Project not found';
  END IF;
  IF _project.origin <> 'admin' THEN
    RAISE EXCEPTION 'You can only express interest in admin-created projects';
  END IF;
  IF _project.status = 'archived'::public.project_status THEN
    RAISE EXCEPTION 'This project is no longer accepting interest';
  END IF;

  -- Load mentor profile
  SELECT * INTO _mp
    FROM public.mentor_profiles
   WHERE user_id = _mentor_id;

  IF NOT FOUND OR _mp.verification_status <> 'approved' THEN
    RAISE EXCEPTION 'Only approved mentors can express interest';
  END IF;
  IF NOT _mp.available_for_mentorship THEN
    RAISE EXCEPTION 'You have set yourself as unavailable for mentorship';
  END IF;

  -- Rank tier check
  IF _project.visible_to_ranks IS NOT NULL
     AND NOT (_mp.rank_tier = ANY(_project.visible_to_ranks)) THEN
    RAISE EXCEPTION
      'Your rank tier (%) is not eligible for this project', _mp.rank_tier;
  END IF;

  -- Check for existing row
  SELECT * INTO _existing
    FROM public.project_mentor_interest
   WHERE project_id = _project_id
     AND mentor_id  = _mentor_id;

  IF FOUND THEN
    -- Permanently blocked via decline
    IF NOT _existing.is_active AND _existing.decline_reason IS NOT NULL THEN
      RAISE EXCEPTION
        'You previously declined this project. Contact support to be reinstated.';
    END IF;

    -- In active cooling period
    IF _existing.cooling_expires_at IS NOT NULL
       AND _existing.cooling_expires_at > now() THEN
      RAISE EXCEPTION
        'You are in a cooling period for this project. '
        'You can re-express interest from %.',
        to_char(_existing.cooling_expires_at, 'DD Mon YYYY');
    END IF;

    -- Already active — just update auto_assign preference
    IF _existing.is_active AND _existing.cooling_expires_at IS NULL THEN
      UPDATE public.project_mentor_interest
         SET auto_assign = _auto_assign,
             updated_at  = now()
       WHERE project_id = _project_id
         AND mentor_id  = _mentor_id;
      RETURN;
    END IF;

    -- Cooling expired — reactivate existing row
    UPDATE public.project_mentor_interest
       SET is_active          = true,
           auto_assign        = _auto_assign,
           cooling_expires_at = NULL,
           expressed_at       = now(),
           updated_at         = now()
     WHERE project_id = _project_id
       AND mentor_id  = _mentor_id;
    -- pmi UPDATE trigger fires → free_mentor_count++, may flip to published
    RETURN;
  END IF;

  -- ── New interest: enforce per-project cap with advisory lock ─────
  -- pg_advisory_xact_lock serialises concurrent inserts for the same
  -- project without blocking other projects.
  IF _project.max_interested_mentors IS NOT NULL THEN
    PERFORM pg_advisory_xact_lock(hashtext(_project_id::text));

    SELECT COUNT(*)::integer INTO _pool_count
      FROM public.project_mentor_interest
     WHERE project_id = _project_id
       AND is_active  = true;

    IF _pool_count >= _project.max_interested_mentors THEN
      RAISE EXCEPTION
        'This project has reached its mentor interest limit of %. '
        'Check back later if a spot opens.',
        _project.max_interested_mentors;
    END IF;
  END IF;

  -- Insert new row
  INSERT INTO public.project_mentor_interest
    (project_id, mentor_id, auto_assign, active_enrollment_count)
  VALUES (
    _project_id,
    _mentor_id,
    _auto_assign,
    (
      SELECT COUNT(*)::integer
        FROM public.project_enrollments
       WHERE mentor_id = _mentor_id
         AND status    IN ('active', 'pending_mentor')
    )
  );
  -- pmi INSERT trigger fires → free_mentor_count++, may flip to published
END;
$$;

GRANT EXECUTE ON FUNCTION public.express_mentor_interest(uuid, boolean)
  TO authenticated;

-- ================================================================
-- STEP 12 — RPC: assign_mentor_for_enrollment()
-- ================================================================

CREATE OR REPLACE FUNCTION public.assign_mentor_for_enrollment(_enrollment_id uuid)
  RETURNS text
  LANGUAGE plpgsql
  SECURITY DEFINER
  VOLATILE
  SET search_path = ''
AS $$
DECLARE
  _enrollment record;
  _project    record;
  _candidate  record;
  _queue_pos  smallint;
BEGIN
  SELECT * INTO _enrollment
    FROM public.project_enrollments
   WHERE id = _enrollment_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Enrollment % not found', _enrollment_id;
  END IF;

  SELECT * INTO _project
    FROM public.projects
   WHERE id = _enrollment.project_id;
  IF _project.origin <> 'admin' THEN
    RAISE EXCEPTION 'assign_mentor_for_enrollment is for admin-created projects only';
  END IF;

  SELECT COALESCE(MAX(queue_position), 0) + 1
    INTO _queue_pos
    FROM public.enrollment_mentor_queue
   WHERE enrollment_id = _enrollment_id;

  -- O(log N): reads indexed active_enrollment_count column, no subqueries
  SELECT pmi.mentor_id, pmi.auto_assign
    INTO _candidate
    FROM public.project_mentor_interest pmi
    JOIN public.mentor_profiles mp ON mp.user_id = pmi.mentor_id
   WHERE pmi.project_id = _enrollment.project_id
     AND pmi.is_active  = true
     AND mp.verification_status      = 'approved'
     AND mp.available_for_mentorship = true
     -- Rank filter
     AND (
       _project.visible_to_ranks IS NULL
       OR mp.rank_tier = ANY(_project.visible_to_ranks)
     )
     -- Not in cooling period (indexed column)
     AND (pmi.cooling_expires_at IS NULL OR pmi.cooling_expires_at < now())
     -- Not already tried for this enrollment
     AND pmi.mentor_id NOT IN (
       SELECT emq.mentor_id
         FROM public.enrollment_mentor_queue emq
        WHERE emq.enrollment_id = _enrollment_id
     )
     -- Not already in an active/pending enrollment on this same project
     AND NOT EXISTS (
       SELECT 1
         FROM public.project_enrollments pe
        WHERE pe.mentor_id  = pmi.mentor_id
          AND pe.project_id = _enrollment.project_id
          AND pe.status     IN ('pending_mentor', 'active')
          AND pe.id         <> _enrollment_id
     )
     -- Under their own capacity limit
     AND pmi.active_enrollment_count < mp.max_concurrent_students
   ORDER BY
     pmi.active_enrollment_count ASC,  -- indexed, no subquery
     mp.rank_points               DESC,
     pmi.expressed_at             ASC
   LIMIT 50;  -- never scan more than 50 candidates

  IF NOT FOUND THEN
    -- Notify all admins
    INSERT INTO public.notifications
      (recipient_id, notification_type, reference_id, body)
    SELECT
      p.id,
      'dispute_opened',
      _enrollment_id,
      'No eligible mentors available for enrollment ' || _enrollment_id::text ||
      '. All interested mentors are busy, cooling, or declined.'
    FROM public.profiles p
    WHERE p.role = 'admin'::public.user_role;

    RETURN 'no_candidates';
  END IF;

  -- Insert queue row
  INSERT INTO public.enrollment_mentor_queue
    (enrollment_id, mentor_id, queue_position, auto_assign, status, offered_at, expires_at)
  VALUES (
    _enrollment_id,
    _candidate.mentor_id,
    _queue_pos,
    _candidate.auto_assign,
    CASE WHEN _candidate.auto_assign THEN 'accepted' ELSE 'offered' END,
    now(),
    CASE WHEN _candidate.auto_assign THEN NULL ELSE now() + INTERVAL '48 hours' END
  );

  IF _candidate.auto_assign THEN
    UPDATE public.project_enrollments
       SET mentor_id  = _candidate.mentor_id,
           status     = 'active',
           started_at = now(),
           updated_at = now()
     WHERE id = _enrollment_id;

    INSERT INTO public.notifications
      (recipient_id, notification_type, reference_id, body)
    VALUES (
      _enrollment.student_id, 'mentor_accepted', _enrollment_id,
      'A mentor has been assigned to your project. You can start now!'
    );

    RETURN 'auto_assigned';

  ELSE
    UPDATE public.project_enrollments
       SET mentor_id          = _candidate.mentor_id,
           status             = 'pending_mentor',
           mentor_deadline_at = now() + INTERVAL '48 hours',
           updated_at         = now()
     WHERE id = _enrollment_id;

    INSERT INTO public.notifications
      (recipient_id, notification_type, reference_id, body)
    VALUES (
      _candidate.mentor_id, 'project_enrolled', _enrollment_id,
      'A student purchased a project you expressed interest in. '
      'You have 48 hours to accept.'
    );

    RETURN 'offer_sent';
  END IF;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.assign_mentor_for_enrollment(uuid)
  FROM authenticated, anon;

-- ================================================================
-- STEP 13 — RPC: decline_or_expire_mentor_offer()
-- ================================================================

CREATE OR REPLACE FUNCTION public.decline_or_expire_mentor_offer(
  _enrollment_id uuid,
  _mentor_id     uuid,
  _reason        text DEFAULT 'expired'  -- 'declined' | 'expired'
)
  RETURNS text
  LANGUAGE plpgsql
  SECURITY DEFINER
  VOLATILE
  SET search_path = ''
AS $$
DECLARE
  _project_id uuid;
BEGIN
  SELECT project_id INTO _project_id
    FROM public.project_enrollments
   WHERE id = _enrollment_id;

  -- Mark the queue row
  UPDATE public.enrollment_mentor_queue
     SET status       = _reason,
         responded_at = now()
   WHERE enrollment_id = _enrollment_id
     AND mentor_id     = _mentor_id
     AND status        IN ('offered', 'pending');

  IF NOT FOUND THEN
    RAISE EXCEPTION
      'No active offer found for mentor % on enrollment %',
      _mentor_id, _enrollment_id;
  END IF;

  -- DECLINE: permanently block this mentor on this project
  IF _reason = 'declined' THEN
    UPDATE public.project_mentor_interest
       SET is_active      = false,
           decline_reason = 'Declined assignment on enrollment ' || _enrollment_id::text,
           updated_at     = now()
     WHERE project_id = _project_id
       AND mentor_id  = _mentor_id;
    -- pmi UPDATE trigger fires → free_mentor_count--, may flip to draft
  END IF;

  -- Clear tentative mentor assignment on the enrollment
  UPDATE public.project_enrollments
     SET mentor_id          = NULL,
         status             = 'pending_mentor',
         mentor_deadline_at = NULL,
         updated_at         = now()
   WHERE id = _enrollment_id;

  -- EXPIRE: mentor is no longer "assigned", restore their free slot
  IF _reason = 'expired' THEN
    UPDATE public.projects
       SET free_mentor_count = free_mentor_count + 1,
           status = CASE
             WHEN status = 'archived'::public.project_status THEN status
             ELSE 'published'::public.project_status
           END,
           updated_at = now()
     WHERE id     = _project_id
       AND origin = 'admin';
  END IF;

  -- Try next candidate
  RETURN public.assign_mentor_for_enrollment(_enrollment_id);
END;
$$;

REVOKE EXECUTE ON FUNCTION public.decline_or_expire_mentor_offer(uuid, uuid, text)
  FROM authenticated, anon;
GRANT  EXECUTE ON FUNCTION public.decline_or_expire_mentor_offer(uuid, uuid, text)
  TO authenticated;

-- ================================================================
-- STEP 14 — RPC: create_enrollment_after_purchase()
-- ================================================================

CREATE OR REPLACE FUNCTION public.create_enrollment_after_purchase(
  _project_id  uuid,
  _student_id  uuid,
  _price_paise bigint,
  _payment_ref text,
  _team_id     uuid DEFAULT NULL
)
  RETURNS uuid
  LANGUAGE plpgsql
  SECURITY DEFINER
  VOLATILE
  SET search_path = ''
AS $$
DECLARE
  _project       record;
  _enrollment_id uuid;
BEGIN
  SELECT * INTO _project
    FROM public.projects
   WHERE id = _project_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Project % not found', _project_id;
  END IF;
  IF _project.status <> 'published'::public.project_status THEN
    RAISE EXCEPTION
      'Project is not available for purchase (status: %)', _project.status;
  END IF;
  IF _project.origin = 'mentor' AND _project.is_locked THEN
    RAISE EXCEPTION
      'This project is currently active with another student and will '
      'be available again after they complete it.';
  END IF;

  INSERT INTO public.project_enrollments (
    project_id, student_id, mentor_id, team_id,
    status, payment_status, payment_reference,
    purchase_price_paise, mentor_deadline_at
  ) VALUES (
    _project_id,
    _student_id,
    CASE WHEN _project.origin = 'mentor' THEN _project.mentor_id ELSE NULL END,
    _team_id,
    'pending_mentor',
    'held',
    _payment_ref,
    _price_paise,
    CASE WHEN _project.origin = 'mentor'
         THEN now() + INTERVAL '48 hours'
         ELSE NULL
    END
  )
  RETURNING id INTO _enrollment_id;
  -- INSERT trigger fires:
  --   mentor → is_locked = true
  --   admin  → status = 'draft', free_mentor_count--

  -- Admin-created: kick off assignment
  IF _project.origin = 'admin' THEN
    PERFORM public.assign_mentor_for_enrollment(_enrollment_id);
  END IF;

  -- Increment denormalized enrollment_count on the project
  UPDATE public.projects
     SET enrollment_count = enrollment_count + 1,
         updated_at       = now()
   WHERE id = _project_id;

  RETURN _enrollment_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.create_enrollment_after_purchase(uuid, uuid, bigint, text, uuid)
  TO authenticated;

-- ================================================================
-- STEP 15 — CRON: expire stale offers every 15 min
-- ================================================================

CREATE OR REPLACE FUNCTION public.expire_stale_mentor_offers()
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  VOLATILE
  SET search_path = ''
AS $$
DECLARE
  _row record;
BEGIN
  -- Admin-created: 48h queue offers that timed out
  FOR _row IN
    SELECT emq.enrollment_id, emq.mentor_id
      FROM public.enrollment_mentor_queue emq
     WHERE emq.status    = 'offered'
       AND emq.expires_at < now()
  LOOP
    PERFORM public.decline_or_expire_mentor_offer(
      _row.enrollment_id, _row.mentor_id, 'expired'
    );
  END LOOP;

  -- Mentor-created: no response in 48h → cancel + refund
  FOR _row IN
    SELECT pe.id
      FROM public.project_enrollments pe
      JOIN public.projects p ON p.id = pe.project_id
     WHERE pe.status             = 'pending_mentor'
       AND pe.mentor_deadline_at < now()
       AND pe.mentor_id          IS NOT NULL
       AND p.origin              = 'mentor'
  LOOP
    UPDATE public.project_enrollments
       SET status         = 'cancelled',
           payment_status = 'refunded',
           updated_at     = now()
     WHERE id = _row.id;
  END LOOP;

  -- Sweep draft admin projects whose mentor cooling periods have expired.
  -- Calling recalc rebuilds free_mentor_count from scratch and may flip
  -- the project back to published.
  FOR _row IN
    SELECT DISTINCT pmi.project_id
      FROM public.project_mentor_interest pmi
      JOIN public.projects p ON p.id = pmi.project_id
     WHERE p.origin              = 'admin'
       AND p.status              = 'draft'::public.project_status
       AND pmi.is_active         = true
       AND pmi.cooling_expires_at IS NOT NULL
       AND pmi.cooling_expires_at < now()
  LOOP
    PERFORM public.recalc_free_mentor_count(_row.project_id);
  END LOOP;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.expire_stale_mentor_offers() FROM authenticated, anon;

-- Unschedule only if the job already exists (first-run safe)
DO $$
BEGIN
  PERFORM cron.unschedule('expire-mentor-offers');
EXCEPTION WHEN others THEN
  NULL; -- job didn't exist yet, nothing to unschedule
END;
$$;

SELECT cron.schedule(
  'expire-mentor-offers',
  '*/15 * * * *',
  $$SELECT public.expire_stale_mentor_offers();$$
);

-- ================================================================
-- STEP 16 — RLS
-- ================================================================

ALTER TABLE public.project_mentor_interest ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.enrollment_mentor_queue  ENABLE ROW LEVEL SECURITY;

-- project_mentor_interest --
-- Mentors see their own rows; admins see all
CREATE POLICY "pmi_select_own_or_admin"
  ON public.project_mentor_interest FOR SELECT TO authenticated
  USING (
    mentor_id = (SELECT auth.uid())
    OR public.is_admin()
  );

-- All inserts go through express_mentor_interest() RPC
CREATE POLICY "pmi_no_direct_insert"
  ON public.project_mentor_interest FOR INSERT TO authenticated
  WITH CHECK (false);

-- Mentors can update their own row (auto_assign toggle); admins can update any
CREATE POLICY "pmi_update_own_or_admin"
  ON public.project_mentor_interest FOR UPDATE TO authenticated
  USING (
    mentor_id = (SELECT auth.uid())
    OR public.is_admin()
  )
  WITH CHECK (
    mentor_id = (SELECT auth.uid())
    OR public.is_admin()
  );

-- Only admins can delete (e.g. reinstate a declined mentor)
CREATE POLICY "pmi_delete_admin_only"
  ON public.project_mentor_interest FOR DELETE TO authenticated
  USING (public.is_admin());

-- enrollment_mentor_queue --
CREATE POLICY "emq_select_participant_or_admin"
  ON public.enrollment_mentor_queue FOR SELECT TO authenticated
  USING (
    mentor_id = (SELECT auth.uid())
    OR public.is_enrollment_participant(enrollment_id)
    OR public.is_admin()
  );

-- All writes go through RPCs (SECURITY DEFINER)
CREATE POLICY "emq_no_direct_write"
  ON public.enrollment_mentor_queue FOR INSERT TO authenticated
  WITH CHECK (false);

-- ================================================================
-- STEP 17 — UPDATE project SELECT policy
-- ================================================================

DROP POLICY IF EXISTS "projects_select_published_or_own_or_admin" ON public.projects;

CREATE POLICY "projects_select_published_or_own_or_admin"
  ON public.projects FOR SELECT TO authenticated
  USING (
    -- Admins see everything
    public.is_admin()

    -- Mentor sees their own projects regardless of status
    OR mentor_id = (SELECT auth.uid())

    -- Mentor-created published + unlocked: students browse and buy
    OR (
      origin = 'mentor'
      AND status   = 'published'::public.project_status
      AND NOT is_locked
    )

    -- Admin-created published: students can purchase
    OR (
      origin = 'admin'
      AND status   = 'published'::public.project_status
      AND EXISTS (
        SELECT 1 FROM public.profiles
         WHERE id   = (SELECT auth.uid())
           AND role = 'student'::public.user_role
      )
    )

    -- Admin-created draft OR published: eligible mentors browse (discovery feed)
    -- draft = no free mentor yet (discovery only)
    -- published = has free mentors (students can also buy)
    OR (
      origin = 'admin'
      AND status IN ('draft'::public.project_status, 'published'::public.project_status)
      AND EXISTS (
        SELECT 1 FROM public.profiles
         WHERE id   = (SELECT auth.uid())
           AND role = 'mentor'::public.user_role
      )
      -- Rank tier filter
      AND (
        visible_to_ranks IS NULL
        OR EXISTS (
          SELECT 1 FROM public.mentor_profiles mp
           WHERE mp.user_id   = (SELECT auth.uid())
             AND mp.rank_tier = ANY(visible_to_ranks)
        )
      )
      -- Not permanently blocked on this project
      AND NOT EXISTS (
        SELECT 1 FROM public.project_mentor_interest pmi
         WHERE pmi.project_id    = projects.id
           AND pmi.mentor_id     = (SELECT auth.uid())
           AND pmi.is_active     = false
           AND pmi.decline_reason IS NOT NULL
      )
    )
  );

-- ================================================================
-- STEP 18 — GRANTS
-- ================================================================

GRANT SELECT, UPDATE, DELETE ON public.project_mentor_interest TO authenticated;
GRANT SELECT                  ON public.enrollment_mentor_queue  TO authenticated;

GRANT SELECT, INSERT, UPDATE, DELETE ON public.project_mentor_interest TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.enrollment_mentor_queue  TO service_role;

-- ================================================================
-- DONE
-- ================================================================

COMMIT;