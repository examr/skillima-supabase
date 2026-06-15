-- ================================================================
--  SKILLIMA — GitHub Integration: Complete DB Layer
--
--  This file contains ALL database functions and triggers that
--  drive the GitHub integration via Supabase Edge Functions.
--
--  ARCHITECTURE:
--    DB status change → pg_net HTTP POST → Edge Function → GitHub API
--
--  REPO OWNERSHIP MODEL:
--    All repos live under the Skillima org (Skillima-Projects).
--    Students and mentors are added as collaborators.
--    Skillima controls the repo lifecycle end-to-end.
--
--  TRIGGER → EDGE FUNCTION MAP:
--    enrollment  → active             → github-repo-create
--    enrollment  → active (mentor)    → github-mentor-added
--    enrollment  → completed          → github-repo-complete
--    stage_progress → submitted       → github-stage-submit
--    stage_progress → approved        → github-stage-approve
--    stage_progress → changes_req     → github-stage-changes
--    student_profiles.github_username → github-username-validate
--
--  REQUIRED COLUMNS (ensure these exist before running):
--    project_enrollments.github_repo_name   TEXT
--    project_enrollments.github_status      TEXT
--    stage_progress.github_pr_number        INTEGER
--    stage_progress.submitted_at            TIMESTAMPTZ
--    student_profiles.github_username       TEXT
--    student_profiles.github_username_valid BOOLEAN
--    student_profiles.github_username_error TEXT
--    mentor_profiles.github_username        TEXT
--
--  REQUIRED ENV VARS (set via docker .env):
--    GITHUB_APP_ID
--    GITHUB_APP_SLUG
--    GITHUB_APP_INSTALLATION_ID
--    GITHUB_APP_PRIVATE_KEY
--    GITHUB_ORG                 (= Skillima-Projects)
--    GITHUB_WEBHOOK_SECRET
-- ================================================================

BEGIN;

-- ================================================================
-- STEP 0 — REQUIRED COLUMNS
-- Add any missing columns needed by the GitHub integration.
-- All idempotent (IF NOT EXISTS / DROP NOT NULL).
-- ================================================================

ALTER TABLE public.project_enrollments
  ADD COLUMN IF NOT EXISTS github_repo_name TEXT DEFAULT NULL,
  ADD COLUMN IF NOT EXISTS github_status    TEXT DEFAULT 'pending'
    CHECK (github_status IN ('pending','creating','ready','transfer_pending','public','error'));

ALTER TABLE public.stage_progress
  ADD COLUMN IF NOT EXISTS github_pr_number INTEGER DEFAULT NULL,
  ADD COLUMN IF NOT EXISTS submitted_at     TIMESTAMPTZ DEFAULT NULL;

ALTER TABLE public.student_profiles
  ADD COLUMN IF NOT EXISTS github_username       TEXT    DEFAULT NULL,
  ADD COLUMN IF NOT EXISTS github_username_valid BOOLEAN DEFAULT NULL,
  ADD COLUMN IF NOT EXISTS github_username_error TEXT    DEFAULT NULL;

ALTER TABLE public.mentor_profiles
  ADD COLUMN IF NOT EXISTS github_username TEXT DEFAULT NULL;

COMMENT ON COLUMN public.project_enrollments.github_repo_name IS
  'Repo name under Skillima-Projects org. e.g. "todo-app-johndoe". '
  'Set by github-repo-create edge function after repo is created.';

COMMENT ON COLUMN public.project_enrollments.github_status IS
  'pending    = repo not created yet
   creating   = edge function in flight
   ready      = repo exists, collaborators added, branches set up
   transfer_pending = project completed, repo going public
   public     = repo is public (portfolio artifact)
   error      = edge function failed, needs manual retry';

COMMENT ON COLUMN public.stage_progress.github_pr_number IS
  'GitHub PR number for this stage. Set by github-stage-submit.
   NULL = PR not yet opened (stage not submitted or fn pending).';

COMMENT ON COLUMN public.student_profiles.github_username_valid IS
  'NULL = not checked yet (username just set, validation in flight).
   TRUE = GitHub confirmed this username exists.
   FALSE = GitHub returned 404 for this username.';

-- ================================================================
-- STEP 1 — SHARED HELPER: edge function base URL
-- ================================================================

CREATE OR REPLACE FUNCTION public.get_edge_function_url(fn_name TEXT)
  RETURNS TEXT
  LANGUAGE sql
  SECURITY DEFINER
  STABLE
  SET search_path = ''
AS $$
  SELECT current_setting('app.supabase_url') || '/functions/v1/' || fn_name;
$$;

REVOKE EXECUTE ON FUNCTION public.get_edge_function_url(TEXT)
  FROM authenticated, anon;

-- ================================================================
-- STEP 2 — TRIGGER FUNCTION: github-repo-create
--
-- Fires: project_enrollments AFTER UPDATE → status = 'active'
-- Calls: github-repo-create edge function
-- Does:  creates private repo, protects main, pushes README,
--        adds collaborators, creates stage/1 branch
-- ================================================================

CREATE OR REPLACE FUNCTION public.notify_github_repo_create()
  RETURNS trigger
  LANGUAGE plpgsql
  SECURITY DEFINER
  VOLATILE
  SET search_path = ''
AS $$
DECLARE
  _url TEXT := public.get_edge_function_url('github-repo-create');
  _key TEXT := current_setting('app.service_role_key');
BEGIN
  -- Only fire when transitioning TO 'active'
  IF NEW.status <> 'active'::public.enrollment_status THEN RETURN NEW; END IF;
  IF OLD.status  = 'active'::public.enrollment_status THEN RETURN NEW; END IF;

  -- Only fire if repo doesn't already exist (idempotency guard)
  IF NEW.github_repo_name IS NOT NULL THEN RETURN NEW; END IF;

  -- Mark as creating so the UI can show a spinner
  UPDATE public.project_enrollments
     SET github_status = 'creating',
         updated_at    = now()
   WHERE id = NEW.id;

  PERFORM extensions.net.http_post(
    url     := _url,
    headers := jsonb_build_object(
      'Content-Type',  'application/json',
      'Authorization', 'Bearer ' || _key
    ),
    body    := jsonb_build_object('enrollmentId', NEW.id)
  );

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_github_repo_create ON public.project_enrollments;

CREATE TRIGGER trg_github_repo_create
  AFTER UPDATE ON public.project_enrollments
  FOR EACH ROW
  EXECUTE FUNCTION public.notify_github_repo_create();

REVOKE EXECUTE ON FUNCTION public.notify_github_repo_create()
  FROM authenticated, anon;

-- ================================================================
-- STEP 3 — TRIGGER FUNCTION: github-mentor-added
--
-- Fires: project_enrollments AFTER UPDATE → status = 'active'
-- Calls: github-mentor-added edge function
-- Does:  adds the newly assigned mentor as 'maintain' collaborator
--        on the repo. Handles:
--        a) Admin-created projects where mentor is assigned after
--           repo already exists
--        b) Mentor replacement mid-project
-- ================================================================

CREATE OR REPLACE FUNCTION public.notify_github_mentor_added()
  RETURNS trigger
  LANGUAGE plpgsql
  SECURITY DEFINER
  VOLATILE
  SET search_path = ''
AS $$
DECLARE
  _url TEXT := public.get_edge_function_url('github-mentor-added');
  _key TEXT := current_setting('app.service_role_key');
BEGIN
  -- Only fire when transitioning TO 'active'
  IF NEW.status <> 'active'::public.enrollment_status THEN RETURN NEW; END IF;
  IF OLD.status  = 'active'::public.enrollment_status THEN RETURN NEW; END IF;

  -- Mentor must exist
  IF NEW.mentor_id IS NULL THEN RETURN NEW; END IF;

  -- Repo must already exist (repo-create fires separately and handles
  -- the initial mentor add — this covers late-assignment cases)
  IF NEW.github_repo_name IS NULL THEN RETURN NEW; END IF;

  PERFORM extensions.net.http_post(
    url     := _url,
    headers := jsonb_build_object(
      'Content-Type',  'application/json',
      'Authorization', 'Bearer ' || _key
    ),
    body    := jsonb_build_object('enrollmentId', NEW.id)
  );

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_github_mentor_added ON public.project_enrollments;

CREATE TRIGGER trg_github_mentor_added
  AFTER UPDATE ON public.project_enrollments
  FOR EACH ROW
  EXECUTE FUNCTION public.notify_github_mentor_added();

REVOKE EXECUTE ON FUNCTION public.notify_github_mentor_added()
  FROM authenticated, anon;

-- ================================================================
-- STEP 4 — TRIGGER FUNCTION: github-repo-complete
--
-- Fires: project_enrollments AFTER UPDATE → status = 'completed'
-- Calls: github-repo-complete edge function
-- Does:  makes repo public, rewrites README as portfolio artifact,
--        sets skillima-verified topics, creates certificate Release,
--        revokes mentor collaborator access
-- ================================================================

CREATE OR REPLACE FUNCTION public.notify_github_repo_complete()
  RETURNS trigger
  LANGUAGE plpgsql
  SECURITY DEFINER
  VOLATILE
  SET search_path = ''
AS $$
DECLARE
  _url TEXT := public.get_edge_function_url('github-repo-complete');
  _key TEXT := current_setting('app.service_role_key');
BEGIN
  -- Only fire when transitioning TO 'completed'
  IF NEW.status <> 'completed'::public.enrollment_status    THEN RETURN NEW; END IF;
  IF OLD.status  = 'completed'::public.enrollment_status    THEN RETURN NEW; END IF;

  -- Must have a repo to complete
  IF NEW.github_repo_name IS NULL THEN RETURN NEW; END IF;

  -- Mark as transfer pending so UI shows "publishing portfolio..."
  UPDATE public.project_enrollments
     SET github_status = 'transfer_pending',
         updated_at    = now()
   WHERE id = NEW.id;

  PERFORM extensions.net.http_post(
    url     := _url,
    headers := jsonb_build_object(
      'Content-Type',  'application/json',
      'Authorization', 'Bearer ' || _key
    ),
    body    := jsonb_build_object('enrollmentId', NEW.id)
  );

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_github_repo_complete ON public.project_enrollments;

CREATE TRIGGER trg_github_repo_complete
  AFTER UPDATE ON public.project_enrollments
  FOR EACH ROW
  EXECUTE FUNCTION public.notify_github_repo_complete();

REVOKE EXECUTE ON FUNCTION public.notify_github_repo_complete()
  FROM authenticated, anon;

-- ================================================================
-- STEP 5 — TRIGGER FUNCTION: github-stage-submit
--
-- Fires: stage_progress AFTER UPDATE → status = 'submitted'
-- Calls: github-stage-submit edge function
-- Does:  opens PR from stage/N → main with deliverables checklist
--
-- Guard: github_pr_number IS NULL prevents duplicate PRs
--        (student could somehow double-submit)
-- ================================================================

CREATE OR REPLACE FUNCTION public.notify_github_stage_submit()
  RETURNS trigger
  LANGUAGE plpgsql
  SECURITY DEFINER
  VOLATILE
  SET search_path = ''
AS $$
DECLARE
  _url TEXT := public.get_edge_function_url('github-stage-submit');
  _key TEXT := current_setting('app.service_role_key');
BEGIN
  -- Only fire when transitioning TO 'submitted'
  IF NEW.status <> 'submitted'::public.stage_status THEN RETURN NEW; END IF;
  IF OLD.status  = 'submitted'::public.stage_status THEN RETURN NEW; END IF;

  -- Don't open a second PR if one already exists
  IF NEW.github_pr_number IS NOT NULL THEN RETURN NEW; END IF;

  PERFORM extensions.net.http_post(
    url     := _url,
    headers := jsonb_build_object(
      'Content-Type',  'application/json',
      'Authorization', 'Bearer ' || _key
    ),
    body    := jsonb_build_object('stageProgressId', NEW.id)
  );

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_github_stage_submit ON public.stage_progress;

CREATE TRIGGER trg_github_stage_submit
  AFTER UPDATE ON public.stage_progress
  FOR EACH ROW
  EXECUTE FUNCTION public.notify_github_stage_submit();

REVOKE EXECUTE ON FUNCTION public.notify_github_stage_submit()
  FROM authenticated, anon;

-- ================================================================
-- STEP 6 — TRIGGER FUNCTION: github-stage-approve
--
-- Fires: stage_progress AFTER UPDATE → status = 'approved'
-- Calls: github-stage-approve edge function
-- Does:  posts APPROVE review, squash merges PR, deletes stage/N
--        branch, creates stage/N+1 branch if next stage exists
--
-- Guard: github_pr_number IS NULL → skip (no PR to merge)
-- ================================================================

CREATE OR REPLACE FUNCTION public.notify_github_stage_approve()
  RETURNS trigger
  LANGUAGE plpgsql
  SECURITY DEFINER
  VOLATILE
  SET search_path = ''
AS $$
DECLARE
  _url TEXT := public.get_edge_function_url('github-stage-approve');
  _key TEXT := current_setting('app.service_role_key');
BEGIN
  -- Only fire when transitioning TO 'approved'
  IF NEW.status <> 'approved'::public.stage_status THEN RETURN NEW; END IF;
  IF OLD.status  = 'approved'::public.stage_status THEN RETURN NEW; END IF;

  -- Must have a PR to approve and merge
  IF NEW.github_pr_number IS NULL THEN RETURN NEW; END IF;

  PERFORM extensions.net.http_post(
    url     := _url,
    headers := jsonb_build_object(
      'Content-Type',  'application/json',
      'Authorization', 'Bearer ' || _key
    ),
    body    := jsonb_build_object(
      'stageProgressId', NEW.id,
      'feedback',        NEW.mentor_feedback
    )
  );

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_github_stage_approve ON public.stage_progress;

CREATE TRIGGER trg_github_stage_approve
  AFTER UPDATE ON public.stage_progress
  FOR EACH ROW
  EXECUTE FUNCTION public.notify_github_stage_approve();

REVOKE EXECUTE ON FUNCTION public.notify_github_stage_approve()
  FROM authenticated, anon;

-- ================================================================
-- STEP 7 — TRIGGER FUNCTION: github-stage-changes
--
-- Fires: stage_progress AFTER UPDATE → status = 'changes_requested'
-- Calls: github-stage-changes edge function
-- Does:  posts REQUEST_CHANGES review to the open PR with feedback
--        The PR stays open — student pushes more commits
--
-- Guard: github_pr_number IS NULL → skip (no PR exists yet)
-- ================================================================

CREATE OR REPLACE FUNCTION public.notify_github_stage_changes()
  RETURNS trigger
  LANGUAGE plpgsql
  SECURITY DEFINER
  VOLATILE
  SET search_path = ''
AS $$
DECLARE
  _url TEXT := public.get_edge_function_url('github-stage-changes');
  _key TEXT := current_setting('app.service_role_key');
BEGIN
  -- Only fire when transitioning TO 'changes_requested'
  IF NEW.status <> 'changes_requested'::public.stage_status THEN RETURN NEW; END IF;
  IF OLD.status  = 'changes_requested'::public.stage_status THEN RETURN NEW; END IF;

  -- Must have a PR open to request changes on
  IF NEW.github_pr_number IS NULL THEN RETURN NEW; END IF;

  PERFORM extensions.net.http_post(
    url     := _url,
    headers := jsonb_build_object(
      'Content-Type',  'application/json',
      'Authorization', 'Bearer ' || _key
    ),
    body    := jsonb_build_object(
      'stageProgressId', NEW.id,
      'feedback',        NEW.mentor_feedback
    )
  );

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_github_stage_changes ON public.stage_progress;

CREATE TRIGGER trg_github_stage_changes
  AFTER UPDATE ON public.stage_progress
  FOR EACH ROW
  EXECUTE FUNCTION public.notify_github_stage_changes();

REVOKE EXECUTE ON FUNCTION public.notify_github_stage_changes()
  FROM authenticated, anon;

-- ================================================================
-- STEP 8 — TRIGGER FUNCTION: github-username-validate
--
-- Fires: student_profiles BEFORE UPDATE when github_username changes
-- Calls: github-username-validate edge function
-- Does:  calls GET /users/{username} on GitHub API
--        writes back github_username_valid + github_username_error
--
-- Uses BEFORE UPDATE so we can reset validation state in the same
-- row update (no extra round trip needed).
-- ================================================================

CREATE OR REPLACE FUNCTION public.notify_github_username_set()
  RETURNS trigger
  LANGUAGE plpgsql
  SECURITY DEFINER
  VOLATILE
  SET search_path = ''
AS $$
DECLARE
  _url TEXT := public.get_edge_function_url('github-username-validate');
  _key TEXT := current_setting('app.service_role_key');
BEGIN
  -- Only fire when github_username actually changes
  IF NEW.github_username IS NOT DISTINCT FROM OLD.github_username THEN
    RETURN NEW;
  END IF;

  -- Reset validation state immediately so UI can show "checking..."
  NEW.github_username_valid := NULL;
  NEW.github_username_error := NULL;

  -- Only call the API if a username was actually set (not cleared)
  IF NEW.github_username IS NOT NULL AND trim(NEW.github_username) <> '' THEN
    PERFORM extensions.net.http_post(
      url     := _url,
      headers := jsonb_build_object(
        'Content-Type',  'application/json',
        'Authorization', 'Bearer ' || _key
      ),
      body    := jsonb_build_object(
        'userId',   NEW.user_id,
        'username', NEW.github_username
      )
    );
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_github_username_set ON public.student_profiles;

-- BEFORE UPDATE so we can modify NEW (reset validation state)
CREATE TRIGGER trg_github_username_set
  BEFORE UPDATE ON public.student_profiles
  FOR EACH ROW
  EXECUTE FUNCTION public.notify_github_username_set();

REVOKE EXECUTE ON FUNCTION public.notify_github_username_set()
  FROM authenticated, anon;

-- ================================================================
-- STEP 9 — ADMIN RETRY FUNCTION
--
-- If an edge function fails (network error, GitHub API down, etc.)
-- pg_net does not retry automatically. This function lets admins
-- manually re-trigger any of the GitHub edge functions from the
-- admin dashboard or Supabase SQL editor.
--
-- Usage examples:
--   SELECT public.retry_github_repo_create('enrollment-uuid');
--   SELECT public.retry_github_stage_submit('stage-progress-uuid');
--   SELECT public.retry_github_repo_complete('enrollment-uuid');
-- ================================================================

CREATE OR REPLACE FUNCTION public.retry_github_repo_create(_enrollment_id UUID)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  VOLATILE
  SET search_path = ''
AS $$
DECLARE
  _url TEXT := public.get_edge_function_url('github-repo-create');
  _key TEXT := current_setting('app.service_role_key');
BEGIN
  -- Reset github_status so the function can run fresh
  UPDATE public.project_enrollments
     SET github_status  = 'creating',
         github_repo_name = NULL,   -- clear stale repo name if partial creation
         updated_at     = now()
   WHERE id = _enrollment_id;

  PERFORM extensions.net.http_post(
    url     := _url,
    headers := jsonb_build_object(
      'Content-Type',  'application/json',
      'Authorization', 'Bearer ' || _key
    ),
    body    := jsonb_build_object('enrollmentId', _enrollment_id)
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.retry_github_stage_submit(_stage_progress_id UUID)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  VOLATILE
  SET search_path = ''
AS $$
DECLARE
  _url TEXT := public.get_edge_function_url('github-stage-submit');
  _key TEXT := current_setting('app.service_role_key');
BEGIN
  -- Clear PR number so the function opens a fresh PR
  UPDATE public.stage_progress
     SET github_pr_number = NULL,
         updated_at       = now()
   WHERE id = _stage_progress_id;

  PERFORM extensions.net.http_post(
    url     := _url,
    headers := jsonb_build_object(
      'Content-Type',  'application/json',
      'Authorization', 'Bearer ' || _key
    ),
    body    := jsonb_build_object('stageProgressId', _stage_progress_id)
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.retry_github_repo_complete(_enrollment_id UUID)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  VOLATILE
  SET search_path = ''
AS $$
DECLARE
  _url TEXT := public.get_edge_function_url('github-repo-complete');
  _key TEXT := current_setting('app.service_role_key');
BEGIN
  PERFORM extensions.net.http_post(
    url     := _url,
    headers := jsonb_build_object(
      'Content-Type',  'application/json',
      'Authorization', 'Bearer ' || _key
    ),
    body    := jsonb_build_object('enrollmentId', _enrollment_id)
  );
END;
$$;

-- Retry functions are admin-only — not exposed to regular users
REVOKE EXECUTE ON FUNCTION public.retry_github_repo_create(UUID)    FROM authenticated, anon;
REVOKE EXECUTE ON FUNCTION public.retry_github_stage_submit(UUID)   FROM authenticated, anon;
REVOKE EXECUTE ON FUNCTION public.retry_github_repo_complete(UUID)  FROM authenticated, anon;

-- ================================================================
-- STEP 10 — MONITORING VIEW
--
-- Quick overview of GitHub integration health.
-- Useful for the admin dashboard and manual debugging.
-- Shows all enrollments with their GitHub status and any
-- stage_progress rows with missing PR numbers.
-- ================================================================

CREATE OR REPLACE VIEW public.github_integration_status AS
SELECT
  pe.id                   AS enrollment_id,
  pe.github_repo_name,
  pe.github_status,
  pe.status               AS enrollment_status,
  pe.created_at,
  pe.updated_at,

  -- Count stages with no PR number that are in submitted/approved status
  (
    SELECT COUNT(*)
      FROM public.stage_progress sp
     WHERE sp.enrollment_id      = pe.id
       AND sp.github_pr_number  IS NULL
       AND sp.status            IN ('submitted', 'approved')
  ) AS stages_missing_pr,

  -- Student GitHub username (to catch missing username issues)
  stp.github_username            AS student_github_username,
  stp.github_username_valid      AS student_username_valid,

  -- Mentor GitHub username
  mp.github_username             AS mentor_github_username

FROM public.project_enrollments pe
LEFT JOIN public.student_profiles stp ON stp.user_id = pe.student_id
LEFT JOIN public.mentor_profiles  mp  ON mp.user_id  = pe.mentor_id
WHERE pe.status IN ('active', 'completed')
ORDER BY pe.updated_at DESC;

COMMENT ON VIEW public.github_integration_status IS
  'Admin monitoring view. Shows GitHub integration state for all active and '
  'completed enrollments. Look for: github_status = error, stages_missing_pr > 0, '
  'student_username_valid = false.';

-- ================================================================
-- STEP 11 — VERIFY TRIGGERS EXIST
--
-- Run this SELECT after applying the migration to confirm all
-- 7 triggers are registered correctly.
-- ================================================================

-- SELECT trigger_name, event_object_table, action_timing, event_manipulation
--   FROM information_schema.triggers
--  WHERE trigger_schema = 'public'
--    AND trigger_name LIKE 'trg_github%'
--  ORDER BY trigger_name;
--
-- Expected output (7 rows):
--   trg_github_mentor_added    | project_enrollments | AFTER  | UPDATE
--   trg_github_repo_complete   | project_enrollments | AFTER  | UPDATE
--   trg_github_repo_create     | project_enrollments | AFTER  | UPDATE
--   trg_github_stage_approve   | stage_progress      | AFTER  | UPDATE
--   trg_github_stage_changes   | stage_progress      | AFTER  | UPDATE
--   trg_github_stage_submit    | stage_progress      | AFTER  | UPDATE
--   trg_github_username_set    | student_profiles    | BEFORE | UPDATE

-- ================================================================
-- DONE
-- ================================================================

COMMIT;