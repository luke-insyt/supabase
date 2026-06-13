-- "Trending Insyts" rail: top live insyts ranked by unique viewers in the last
-- 7 days. The per-insyt chip everywhere shows all-time insyts.view_count; only
-- this ranking uses the recent window. See features/insyt-views-features.md.
--
-- SECURITY DEFINER so it can aggregate over public.insyt_views (which has RLS
-- enabled with no policies — rows are private). The function only ever returns
-- aggregates + public insyt fields, never the raw (user_id, insyt_id) rows.
-- All text columns are cast to text so the RETURNS TABLE signature is stable
-- regardless of the underlying varchar/text choices on public.insyts.
CREATE OR REPLACE FUNCTION public.get_trending_insyts(p_limit int DEFAULT 5)
  RETURNS TABLE (
    insyt_id              text,
    title                 text,
    creator_display_name  text,
    creator_auth_user_id  text,
    thumbnail_url         text,
    view_count            integer,
    recent_views          bigint
  )
  LANGUAGE sql
  STABLE
  SECURITY DEFINER
  SET search_path = public
AS $$
  SELECT i.insyt_id::text,
         i.title::text,
         i.creator_display_name::text,
         i.creator_auth_user_id::text,
         i.thumbnail_url::text,
         COALESCE(i.view_count, 0),
         count(v.user_id) AS recent_views
  FROM public.insyts i
  LEFT JOIN public.insyt_views v
    ON v.insyt_id = i.id
   AND v.last_viewed_at >= now() - interval '7 days'
  WHERE i.status IN ('live', 'published')
    AND i.is_hidden = false
  GROUP BY i.id
  ORDER BY count(v.user_id) DESC, COALESCE(i.view_count, 0) DESC, i.created_at DESC
  LIMIT GREATEST(COALESCE(p_limit, 5), 0);
$$;

GRANT EXECUTE ON FUNCTION public.get_trending_insyts(int) TO anon, authenticated;
