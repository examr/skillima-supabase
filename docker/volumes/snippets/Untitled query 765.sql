CREATE OR REPLACE FUNCTION public.search_guilds(
  _search text    DEFAULT '',
  _offset integer DEFAULT 0,
  _limit  integer DEFAULT 20
)
  RETURNS jsonb
  LANGUAGE plpgsql
  SECURITY DEFINER
  STABLE
  SET search_path = ''
AS $$
DECLARE
  _results jsonb;
  _total   bigint;
BEGIN
  SELECT COUNT(DISTINCT g.id)
    INTO _total
    FROM public.guilds g
   WHERE g.is_active = true
     AND (
       _search = ''
       OR g.name        ILIKE '%' || _search || '%'
       OR g.slug        ILIKE '%' || _search || '%'
       OR g.description ILIKE '%' || _search || '%'
     );

  SELECT jsonb_agg(row ORDER BY row->>'name')
    INTO _results
    FROM (
      SELECT jsonb_build_object(
        'id',            g.id,
        'name',          g.name,
        'slug',          g.slug,
        'description',   g.description,
        'icon_url',      g.icon_url,
        'banner_url',    g.banner_url,
        'member_count',  g.member_count,
        'project_count', g.project_count,
        'skills', COALESCE(
          (
            SELECT jsonb_agg(jsonb_build_object(
              'id',         s.id,
              'name',       s.name,
              'slug',       s.slug,
              'icon_url',   s.icon_url,       -- ← was missing
              'user_count', COALESCE(uc.user_count, 0)
            ) ORDER BY s.name)
            FROM public.guild_skills gs
            JOIN public.skills s ON s.id = gs.skill_id
            LEFT JOIN LATERAL (
              SELECT COUNT(*)::int AS user_count
              FROM public.user_skills us
              WHERE us.skill_id = s.id
            ) uc ON true
            WHERE gs.guild_id = g.id
          ),
          '[]'::jsonb
        ),
        'total_count', 0
      ) AS row
      FROM public.guilds g
      WHERE g.is_active = true
        AND (
          _search = ''
          OR g.name        ILIKE '%' || _search || '%'
          OR g.slug        ILIKE '%' || _search || '%'
          OR g.description ILIKE '%' || _search || '%'
        )
      ORDER BY g.name ASC
      LIMIT  _limit
      OFFSET _offset
    ) sub;

  RETURN jsonb_build_object(
    'guilds',      COALESCE(_results, '[]'::jsonb),
    'total_count', _total
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.search_guilds(text, integer, integer) TO authenticated, anon;