-- ================================================================
--  SKILLIMA — RPC: add_user_skills
--
--  Adds or updates a list of skills for a given user.
--  Uses UPSERT — if (user_id, skill_id) already exists,
--  it updates the proficiency_level. If not, inserts fresh.
--
--  Parameters:
--    _user_id          uuid     — the user to add skills for
--    _skill_ids        uuid[]   — array of skill UUIDs to add
--    _proficiency      text     — single level applied to all skills
--                                 ('beginner' | 'intermediate' |
--                                  'advanced' | 'expert')
--                                 DEFAULT: 'beginner'
--
--  Returns: jsonb
--    {
--      "added":   3,   -- newly inserted rows
--      "updated": 1,   -- rows that already existed (proficiency changed)
--      "skipped": 1    -- invalid skill IDs that don't exist in skills table
--    }
--
--  Security:
--    SECURITY DEFINER — runs as postgres
--    Caller validated: auth.uid() must match _user_id
--    OR caller must be admin
--    Skill IDs validated against skills table before insert
-- ================================================================

CREATE OR REPLACE FUNCTION public.add_user_skills(
  _user_id     uuid,
  _skill_ids   uuid[],
  _proficiency text DEFAULT 'beginner'
)
  RETURNS jsonb
  LANGUAGE plpgsql
  SECURITY DEFINER
  VOLATILE
  SET search_path = ''
AS $$
DECLARE
  _valid_proficiency  public.proficiency_level;
  _valid_skill_ids    uuid[];
  _existing_skill_ids uuid[];
  _new_skill_ids      uuid[];
  _added_count        int := 0;
  _updated_count      int := 0;
  _skipped_count      int := 0;
BEGIN

  -- ── 1. Auth guard ──────────────────────────────────────────────
  -- Caller must be the user themselves OR an admin
  IF (SELECT auth.uid()) <> _user_id AND NOT public.is_admin() THEN
    RAISE EXCEPTION 'Permission denied: cannot modify skills for another user'
      USING ERRCODE = '42501';
  END IF;

  -- ── 2. Validate user exists in profiles ────────────────────────
  IF NOT EXISTS (
    SELECT 1 FROM public.profiles WHERE id = _user_id
  ) THEN
    RAISE EXCEPTION 'User % not found', _user_id
      USING ERRCODE = 'P0002';
  END IF;

  -- ── 3. Validate proficiency level ──────────────────────────────
  -- Safe cast — raise clear error instead of cryptic postgres cast error
  BEGIN
    _valid_proficiency := _proficiency::public.proficiency_level;
  EXCEPTION WHEN invalid_text_representation THEN
    RAISE EXCEPTION 'Invalid proficiency level: %. Must be one of: beginner, intermediate, advanced, expert', _proficiency
      USING ERRCODE = '22P02';
  END;

  -- ── 4. Validate skill IDs ──────────────────────────────────────
  -- Filter out any UUIDs that don't exist in the skills table
  -- This prevents silent failures from bad client data
  SELECT ARRAY(
    SELECT s.id
    FROM public.skills s
    WHERE s.id = ANY(_skill_ids)
  ) INTO _valid_skill_ids;

  -- Track how many were invalid / not found
  _skipped_count := array_length(_skill_ids, 1) - COALESCE(array_length(_valid_skill_ids, 1), 0);

  -- Nothing valid to insert — return early
  IF COALESCE(array_length(_valid_skill_ids, 1), 0) = 0 THEN
    RETURN jsonb_build_object(
      'added',   0,
      'updated', 0,
      'skipped', _skipped_count
    );
  END IF;

  -- ── 5. Find which skills already exist for this user ───────────
  SELECT ARRAY(
    SELECT skill_id
    FROM public.user_skills
    WHERE user_id  = _user_id
      AND skill_id = ANY(_valid_skill_ids)
  ) INTO _existing_skill_ids;

  -- New = valid - already existing
  SELECT ARRAY(
    SELECT unnest(_valid_skill_ids)
    EXCEPT
    SELECT unnest(_existing_skill_ids)
  ) INTO _new_skill_ids;

  _added_count   := COALESCE(array_length(_new_skill_ids, 1), 0);
  _updated_count := COALESCE(array_length(_existing_skill_ids, 1), 0);

  -- ── 6. Upsert all valid skills in one statement ─────────────────
  INSERT INTO public.user_skills (user_id, skill_id, proficiency_level)
  SELECT
    _user_id,
    unnest(_valid_skill_ids),
    _valid_proficiency
  ON CONFLICT (user_id, skill_id)
  DO UPDATE SET
    proficiency_level = EXCLUDED.proficiency_level;

  -- ── 7. Return result summary ────────────────────────────────────
  RETURN jsonb_build_object(
    'added',   _added_count,
    'updated', _updated_count,
    'skipped', _skipped_count
  );

END;
$$;

-- ── Grants ────────────────────────────────────────────────────────
-- Authenticated users can call this for themselves
-- Auth guard inside the function blocks cross-user calls
GRANT EXECUTE ON FUNCTION public.add_user_skills(uuid, uuid[], text) TO authenticated;
REVOKE EXECUTE ON FUNCTION public.add_user_skills(uuid, uuid[], text) FROM anon;
