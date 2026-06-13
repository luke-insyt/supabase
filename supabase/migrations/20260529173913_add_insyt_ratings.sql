-- Adds the "rate an insyt" feature. Surfaces:
--   * /insyts/<slug> — read-only star row at #insyt-rating-result (everyone)
--                    — input row at #insyt-rating-div (only purchasers; creators excluded)
--
-- Source of truth is public.insyt_ratings (one row per user, upserted on
-- re-rate). Aggregates are denormalised onto public.insyts.rating_avg and
-- public.insyts.rating_count via the trigger refresh_insyt_rating, mirroring
-- the pattern used for users.follower_count (20260529130000) and
-- users.report_count (20260527120000).
--
-- IMPORTANT: this table has NO INSERT/UPDATE/DELETE RLS policies. All
-- mutations must go through the submit-insyt-rating edge function, which
-- runs the purchase / creator-block eligibility check with service-role.
-- The check spans insyts.id (uuid) and insyts.insyt_id (varchar) — the
-- latter is the join key into public.purchases — and duplicating that
-- translation in an RLS WITH CHECK clause would diverge from the access
-- logic that already lives in the get-insyt-content edge function. One
-- place owns "who can touch insyt content".

-- ============================================================================
-- 1. The rating table. PK on (insyt_id, user_id) means one row per user per
--    insyt; re-rates are upserted on conflict. insyt_id references the uuid
--    PK on public.insyts (always populated, unlike insyts.insyt_id varchar
--    which is null for drafts). user_id references auth.users.id, matching
--    GETINSYT.session.user.id and public.follows.follower_id.
-- ============================================================================
CREATE TABLE public.insyt_ratings (
  insyt_id   uuid NOT NULL REFERENCES public.insyts(id) ON DELETE CASCADE,
  user_id    uuid NOT NULL REFERENCES auth.users(id)    ON DELETE CASCADE,
  rating     numeric(2,1) NOT NULL
             CHECK (rating IN (0.5, 1.0, 1.5, 2.0, 2.5, 3.0, 3.5, 4.0, 4.5, 5.0)),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (insyt_id, user_id)
);

-- insyt_id has the PK prefix so per-insyt scans are already indexed. Add the
-- reverse for "all ratings by this user" (account-page history, future work).
CREATE INDEX insyt_ratings_user_id_idx ON public.insyt_ratings (user_id);

-- ============================================================================
-- 2. RLS. Reads are public — aggregates are public, individual rows leak
--    only "user X rated insyt Y as 4.5" which matches the public review
--    nature. NO write policies: mutations are restricted to service_role
--    (the submit-insyt-rating edge function) so eligibility (purchase +
--    creator-block) can be enforced in one place.
-- ============================================================================
ALTER TABLE public.insyt_ratings ENABLE ROW LEVEL SECURITY;

CREATE POLICY insyt_ratings_select_all ON public.insyt_ratings
  FOR SELECT TO anon, authenticated USING (true);

-- No INSERT / UPDATE / DELETE policies → only service_role can mutate.

-- ============================================================================
-- 3. Bump updated_at on every rating change so the timestamp is authoritative
--    regardless of caller. The edge function will also set updated_at = now()
--    in its UPSERT, but the trigger backstops manual SQL fixes too.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.touch_insyt_ratings_updated_at()
  RETURNS trigger
  LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS touch_insyt_ratings_updated_at ON public.insyt_ratings;
CREATE TRIGGER touch_insyt_ratings_updated_at
  BEFORE UPDATE ON public.insyt_ratings
  FOR EACH ROW
  EXECUTE FUNCTION public.touch_insyt_ratings_updated_at();

-- ============================================================================
-- 4. Denormalised aggregates on public.insyts. rating_avg is nullable so the
--    UI can distinguish "no ratings yet" (null) from "average is exactly 0"
--    (which the CHECK constraint makes impossible anyway, but the contract
--    stays readable). numeric(3,2) holds up to 9.99 — plenty of headroom for
--    a 0-5 scale with two decimals.
-- ============================================================================
ALTER TABLE public.insyts
  ADD COLUMN rating_avg   numeric(3,2),
  ADD COLUMN rating_count int NOT NULL DEFAULT 0;

-- ============================================================================
-- 5. Recompute one insyt's aggregates from scratch. Recomputing (vs. +/- 1
--    deltas) can't drift. SECURITY DEFINER so the trigger can write insyts
--    regardless of the writer's RLS — matches refresh_follow_counts
--    (20260529130000) and refresh_creator_report_count (20260527120000).
-- ============================================================================
CREATE OR REPLACE FUNCTION public.refresh_insyt_rating(p_insyt_id uuid)
  RETURNS void
  LANGUAGE sql
  SECURITY DEFINER
  SET search_path = public
AS $$
  UPDATE public.insyts i SET
    rating_count = (SELECT count(*)::int            FROM public.insyt_ratings WHERE insyt_id = p_insyt_id),
    rating_avg   = (SELECT round(avg(rating)::numeric, 2)
                      FROM public.insyt_ratings WHERE insyt_id = p_insyt_id)
  WHERE i.id = p_insyt_id;
$$;

CREATE OR REPLACE FUNCTION public.insyt_ratings_count_sync()
  RETURNS trigger
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path = public
AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    PERFORM public.refresh_insyt_rating(NEW.insyt_id);
    RETURN NEW;
  ELSIF TG_OP = 'UPDATE' THEN
    -- The PK is (insyt_id, user_id), so an UPDATE never moves a row to a
    -- different insyt — but refresh on both sides if it ever did (paranoia).
    PERFORM public.refresh_insyt_rating(NEW.insyt_id);
    IF NEW.insyt_id IS DISTINCT FROM OLD.insyt_id THEN
      PERFORM public.refresh_insyt_rating(OLD.insyt_id);
    END IF;
    RETURN NEW;
  ELSE -- DELETE
    PERFORM public.refresh_insyt_rating(OLD.insyt_id);
    RETURN OLD;
  END IF;
END;
$$;

DROP TRIGGER IF EXISTS insyt_ratings_count_sync ON public.insyt_ratings;
CREATE TRIGGER insyt_ratings_count_sync
  AFTER INSERT OR UPDATE OR DELETE ON public.insyt_ratings
  FOR EACH ROW
  EXECUTE FUNCTION public.insyt_ratings_count_sync();

-- ============================================================================
-- 6. Backfill from current data. The table is empty on first deploy so this
--    resets every insyt to (null, 0) — idempotent and re-runnable.
-- ============================================================================
UPDATE public.insyts i
   SET rating_count = (SELECT count(*)::int            FROM public.insyt_ratings WHERE insyt_id = i.id),
       rating_avg   = (SELECT round(avg(rating)::numeric, 2)
                         FROM public.insyt_ratings WHERE insyt_id = i.id);

-- No view changes needed: js/feed.js and js/insyt-detail.js both query
-- public.insyts directly. Adding columns to the table makes them available
-- to any future SELECT that names them.
