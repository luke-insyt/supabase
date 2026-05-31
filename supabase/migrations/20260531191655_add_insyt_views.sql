-- Adds the "insyt views" feature: count the distinct people who have read an
-- insyt's full content, surfaced as an eye+count chip across the app and used
-- to rank a "Trending Insyts" panel. See features/insyt-views-features.md.
--
-- Source of truth is public.insyt_views (one row per (insyt, viewer); a re-open
-- bumps last_viewed_at without adding a row). The distinct-viewer count is
-- denormalised onto public.insyts.view_count via refresh_insyt_view_count,
-- mirroring insyt_ratings (20260529173913), follower_count and report_count.
--
-- A view is recorded ONLY by the get-insyt-content edge function, on the
-- access-granted path and only when the viewer is NOT the creator. That
-- function already owns "who may read this content", so eligibility isn't
-- duplicated here. Hence the table has NO write RLS policies (service_role
-- only) and NO read policy either: individual "user X viewed insyt Y" rows
-- stay private; only the aggregate public.insyts.view_count is public.

-- ============================================================================
-- 1. The views table. PK (insyt_id, user_id) = one row per viewer per insyt;
--    re-opens upsert (bump last_viewed_at) without adding rows. insyt_id
--    references the uuid PK on public.insyts (always populated, unlike the
--    varchar insyts.insyt_id which is null for drafts). user_id references
--    auth.users.id, matching GETINSYT.session.user.id and follows.follower_id.
-- ============================================================================
CREATE TABLE public.insyt_views (
  insyt_id        uuid NOT NULL REFERENCES public.insyts(id) ON DELETE CASCADE,
  user_id         uuid NOT NULL REFERENCES auth.users(id)    ON DELETE CASCADE,
  first_viewed_at timestamptz NOT NULL DEFAULT now(),
  last_viewed_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (insyt_id, user_id)
);

-- Reverse lookup ("all insyts this user viewed") + the 7-day trending-window
-- scan filters on last_viewed_at.
CREATE INDEX insyt_views_user_id_idx     ON public.insyt_views (user_id);
CREATE INDEX insyt_views_last_viewed_idx ON public.insyt_views (last_viewed_at);

-- ============================================================================
-- 2. RLS. Enabled with NO policies → only service_role (the get-insyt-content
--    edge function) can read or write. The public number lives on
--    insyts.view_count, not in row reads.
-- ============================================================================
ALTER TABLE public.insyt_views ENABLE ROW LEVEL SECURITY;

-- ============================================================================
-- 3. Denormalised distinct-viewer count on public.insyts. Inherits the
--    existing public SELECT on insyts, so every read surface already sees it.
-- ============================================================================
ALTER TABLE public.insyts ADD COLUMN IF NOT EXISTS view_count integer NOT NULL DEFAULT 0;

-- ============================================================================
-- 4. Full recompute (not delta) so the counter cannot drift — same shape as
--    refresh_insyt_rating. Fires on INSERT (a new unique viewer) and DELETE;
--    the re-open UPDATE path leaves the distinct count unchanged.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.refresh_insyt_view_count()
  RETURNS trigger
  LANGUAGE plpgsql
AS $$
DECLARE
  target uuid := COALESCE(NEW.insyt_id, OLD.insyt_id);
BEGIN
  UPDATE public.insyts
     SET view_count = (SELECT count(*) FROM public.insyt_views WHERE insyt_id = target)
   WHERE id = target;
  RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS refresh_insyt_view_count ON public.insyt_views;
CREATE TRIGGER refresh_insyt_view_count
  AFTER INSERT OR DELETE ON public.insyt_views
  FOR EACH ROW
  EXECUTE FUNCTION public.refresh_insyt_view_count();
