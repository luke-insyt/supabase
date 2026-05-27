-- Populate the per-Insyter "N reports" metric on the public /insyters directory.
--
-- public.users already has a report_count column, but nothing kept it in sync, so
-- it was always 0 and creator_search never exposed it. We define "reports" as the
-- creator's PUBLICLY VISIBLE insyts — status in ('live','published') and not hidden
-- — the same set the /insyts feed shows (see js/feed.js). insyts link to a creator
-- by creator_email = users.email (same join the display_name sync trigger uses, see
-- 20260520120000_add_insyts_feed_search.sql).
--
-- Approach: keep users.report_count maintained by a trigger on insyts, then expose
-- it through creator_search. The frontend reads the column rather than counting.

-- ============================================================================
-- 1. Index the visible set so the recompute (run on every insyt write) is a
--    cheap indexed count instead of a table scan.
-- ============================================================================
CREATE INDEX IF NOT EXISTS insyts_visible_creator_email_idx
  ON public.insyts (creator_email)
  WHERE status IN ('live', 'published') AND is_hidden = false;

-- ============================================================================
-- 2. Recompute one creator's report_count from scratch. Recomputing (vs. +/- 1
--    deltas) can't drift, and the partial index above keeps it trivial. NULL or
--    unknown emails are a safe no-op. SECURITY DEFINER so the trigger can write
--    users regardless of the writer's RLS (matches sync_insyts_creator_display_name).
-- ============================================================================
CREATE OR REPLACE FUNCTION public.refresh_creator_report_count(p_email text)
  RETURNS void
  LANGUAGE sql
  SECURITY DEFINER
  SET search_path = public
AS $$
  UPDATE public.users u
     SET report_count = (
       SELECT count(*)::int
         FROM public.insyts i
        WHERE i.creator_email = p_email
          AND i.status IN ('live', 'published')
          AND i.is_hidden = false
     )
   WHERE u.email = p_email;
$$;

-- ============================================================================
-- 3. Trigger: refresh the affected creator(s) whenever an insyt's visibility or
--    ownership could change the count. Skips no-op updates (e.g. a title edit).
-- ============================================================================
CREATE OR REPLACE FUNCTION public.insyts_report_count_sync()
  RETURNS trigger
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path = public
AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    PERFORM public.refresh_creator_report_count(NEW.creator_email);
    RETURN NEW;
  ELSIF TG_OP = 'DELETE' THEN
    PERFORM public.refresh_creator_report_count(OLD.creator_email);
    RETURN OLD;
  ELSE -- UPDATE
    IF NEW.creator_email IS DISTINCT FROM OLD.creator_email
       OR NEW.status     IS DISTINCT FROM OLD.status
       OR NEW.is_hidden  IS DISTINCT FROM OLD.is_hidden THEN
      PERFORM public.refresh_creator_report_count(NEW.creator_email);
      -- An insyt reassigned to a different creator changes both counts.
      IF NEW.creator_email IS DISTINCT FROM OLD.creator_email THEN
        PERFORM public.refresh_creator_report_count(OLD.creator_email);
      END IF;
    END IF;
    RETURN NEW;
  END IF;
END;
$$;

DROP TRIGGER IF EXISTS insyts_report_count_sync ON public.insyts;
CREATE TRIGGER insyts_report_count_sync
  AFTER INSERT OR UPDATE OR DELETE ON public.insyts
  FOR EACH ROW
  EXECUTE FUNCTION public.insyts_report_count_sync();

-- ============================================================================
-- 4. Backfill every user from current data (idempotent).
-- ============================================================================
UPDATE public.users u
   SET report_count = (
     SELECT count(*)::int
       FROM public.insyts i
      WHERE i.creator_email = u.email
        AND i.status IN ('live', 'published')
        AND i.is_hidden = false
   );

-- ============================================================================
-- 5. Expose report_count on creator_search (appended; CREATE OR REPLACE keeps the
--    existing security_invoker = off setting and grants). security_invoker = off
--    re-asserted as belt-and-braces — the public page reads this view as anon.
-- ============================================================================
CREATE OR REPLACE VIEW public.creator_search AS
  SELECT
    u.auth_user_id,            -- slug for /creators/<auth_user_id>
    u.display_name,
    u.headline,
    u.bio,
    u.profile_image_url,       -- storage path; frontend resolves via creator-avatars bucket
    u.experience_years,
    u.search_vector,
    u.creator_activated_at,
    u.created_at,
    COALESCE(
      (SELECT array_agg(t.label ORDER BY t.label)
         FROM public.creator_expertise ce
         JOIN public.expertise_tags t ON t.id = ce.tag_id
        WHERE ce.user_id = u.auth_user_id),
      '{}'
    ) AS expertise,
    COALESCE(
      (SELECT array_agg(t.slug ORDER BY t.slug)
         FROM public.creator_expertise ce
         JOIN public.expertise_tags t ON t.id = ce.tag_id
        WHERE ce.user_id = u.auth_user_id),
      '{}'
    ) AS expertise_slugs,
    u.report_count             -- maintained by insyts_report_count_sync
  FROM public.users u
  WHERE u.is_creator = true;

ALTER VIEW public.creator_search SET (security_invoker = off);

GRANT SELECT ON public.creator_search TO anon, authenticated;
