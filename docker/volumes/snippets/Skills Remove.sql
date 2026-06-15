-- ================================================================
--  SKILLIMA — RPC: remove_user_skills
--
--  Removes a list of skills for a given user from user_skills.
--
--  Parameters:
--    _user_id     uuid    — the user to remove skills for
--    _skill_ids   uuid[]  — array of skill UUIDs to remove
--
--  Returns: jsonb
--    {
--      "removed": 2,  -- rows actually deleted
--      "skipped": 1   -- skill IDs that weren't in user's skills
--    }
--
--  Security:
--    Caller must be the user themselves OR an admin
-- ================================================================

CREATE OR REPLACE FUNCTION public.remove_user_skills(
  _user_id   uuid,
  _skill_ids uuid[]
)
  RETURNS jsonb
  LANGUAGE plpgsql
  SECURITY DEFINER
  VOLATILE
  SET search_path = ''
AS $$
DECLARE
  _removed_count int := 0;
  _skipped_count int := 0;
BEGIN

  -- ── 1. Auth guard ──────────────────────────────────────────────
  IF (SELECT auth.uid()) <> _user_id AND NOT public.is_admin() THEN
    RAISE EXCEPTION 'Permission denied: cannot modify skills for another user'
      USING ERRCODE = '42501';
  END IF;

  -- ── 2. Validate user exists ────────────────────────────────────
  IF NOT EXISTS (
    SELECT 1 FROM public.profiles WHERE id = _user_id
  ) THEN
    RAISE EXCEPTION 'User % not found', _user_id
      USING ERRCODE = 'P0002';
  END IF;

  -- ── 3. Validate input array is not empty ───────────────────────
  IF _skill_ids IS NULL OR array_length(_skill_ids, 1) IS NULL THEN
    RAISE EXCEPTION 'skill_ids array cannot be empty'
      USING ERRCODE = '22023';
  END IF;

  -- ── 4. Delete matched rows, capture count ──────────────────────
  WITH deleted AS (
    DELETE FROM public.user_skills
    WHERE user_id  = _user_id
      AND skill_id = ANY(_skill_ids)
    RETURNING skill_id
  )
  SELECT COUNT(*)::int INTO _removed_count FROM deleted;

  -- Skills requested but not found in user's list
  _skipped_count := array_length(_skill_ids, 1) - _removed_count;

  -- ── 5. Return summary ──────────────────────────────────────────
  RETURN jsonb_build_object(
    'removed', _removed_count,
    'skipped', _skipped_count
  );

END;
$$;

-- ── Grants ────────────────────────────────────────────────────────
GRANT EXECUTE ON FUNCTION public.remove_user_skills(uuid, uuid[]) TO authenticated;
REVOKE EXECUTE ON FUNCTION public.remove_user_skills(uuid, uuid[]) FROM anon;