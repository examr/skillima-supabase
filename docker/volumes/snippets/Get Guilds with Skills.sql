-- ================================================================
--  SKILLIMA — RPC: get_guilds_with_skills (paginated)
--
--  Parameters:
--    _limit  int  — guilds per page (default 10, max 50)
--    _offset int  — skip N guilds (default 0)
--
--  Response shape:
--  {
--    "total_count": 10,
--    "guilds": [
--      {
--        "id": "uuid",
--        "name": "React Artisans",
--        "slug": "react-artisans",
--        "description": "...",
--        "icon_url": null,
--        "banner_url": null,
--        "member_count": 0,
--        "project_count": 0,
--        "skills": [
--          {
--            "id": "uuid",
--            "name": "React.js",
--            "slug": "react-js",
--            "icon_url": "https://cdn.jsdelivr.net/...",
--            "user_count": 42
--          }
--        ]
--      }
--    ]
--  }
-- ================================================================

CREATE OR REPLACE FUNCTION public.get_guilds_with_skills(
  _limit  int DEFAULT 10,
  _offset int DEFAULT 0
)
  RETURNS jsonb
  LANGUAGE sql
  SECURITY DEFINER
  STABLE
  SET search_path = ''
AS $$
  WITH active_guilds AS (
    -- Resolve total count + apply pagination in one CTE
    -- so we don't scan the guilds table twice
    SELECT
      id,
      name,
      slug,
      description,
      icon_url,
      banner_url,
      member_count,
      project_count,
      COUNT(*) OVER () AS total_count   -- window fn: total active guilds
    FROM public.guilds
    WHERE is_active = true
    ORDER BY name
    LIMIT  GREATEST(1, LEAST(_limit, 50))   -- hard cap at 50 per page
    OFFSET GREATEST(0, _offset)
  )
  SELECT jsonb_build_object(
    'total_count', COALESCE(MAX(ag.total_count), 0),
    'guilds',      COALESCE(
      jsonb_agg(
        jsonb_build_object(
          'id',            ag.id,
          'name',          ag.name,
          'slug',          ag.slug,
          'description',   ag.description,
          'icon_url',      ag.icon_url,
          'banner_url',    ag.banner_url,
          'member_count',  ag.member_count,
          'project_count', ag.project_count,
          'skills',        COALESCE(skill_data.skills, '[]'::jsonb)
        )
        ORDER BY ag.name
      ),
      '[]'::jsonb
    )
  )
  FROM active_guilds ag
  LEFT JOIN LATERAL (
    SELECT jsonb_agg(
      jsonb_build_object(
        'id',         s.id,
        'name',       s.name,
        'slug',       s.slug,
        'icon_url',   s.icon_url,
        'user_count', COALESCE(uc.user_count, 0)
      )
      ORDER BY s.name
    ) AS skills
    FROM public.guild_skills gs
    JOIN public.skills s ON s.id = gs.skill_id
    LEFT JOIN LATERAL (
      SELECT COUNT(*)::int AS user_count
      FROM public.user_skills us
      WHERE us.skill_id = s.id
    ) uc ON true
    WHERE gs.guild_id = ag.id
  ) skill_data ON true;
$$;

-- Grants unchanged
GRANT EXECUTE ON FUNCTION public.get_guilds_with_skills(int, int) TO authenticated;
REVOKE EXECUTE ON FUNCTION public.get_guilds_with_skills(int, int) FROM anon;
