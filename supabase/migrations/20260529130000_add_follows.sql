-- Adds the "follow creators" feature. Surfaces:
--   * /creators/<auth_user_id> — cp-follow-btn + #cp-followers count
--   * /insyters              — follow-filter-btn + per-card insyter-follow-btn
--   * /insyts                — per-card insyts-follow-btn
--
-- Source of truth is public.follows (this migration). Denormalised counters
-- live on public.users.follower_count / following_count (columns already
-- exist; nothing maintained them before). The /insyters feed (creator_search
-- view) gets follower_count appended. The /insyts feed (public.insyts)
-- gets a denormalised creator_auth_user_id column so the per-card follow
-- button has the creator uid without a join in the hot path — mirrors the
-- existing creator_display_name denormalisation
-- (see 20260520120000_add_insyts_feed_search.sql).

-- ============================================================================
-- 1. The follow graph. Both ids are auth uuids — every public-facing creator
--    key in the system is auth_user_id (URL slug, creator_search view,
--    GETINSYT.session.user.id), so storing the auth uid avoids a join on
--    every read. users.auth_user_id is already FK-unique to auth.users.id.
-- ============================================================================
CREATE TABLE public.follows (
  follower_id  uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  creator_id   uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  created_at   timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (follower_id, creator_id),
  CHECK (follower_id <> creator_id)
);

-- follower_id has the PK prefix, so "who do I follow" lookups are already
-- indexed. Add the reverse for "who follows this creator" and follower-count
-- recomputes.
CREATE INDEX follows_creator_id_idx ON public.follows (creator_id);

-- ============================================================================
-- 2. RLS. Reads are public — counts and the listing-page "show creators I
--    follow" filter both need anon-readable rows. Writes are restricted to
--    the owning follower; updates are forbidden (follow rows are immutable).
-- ============================================================================
ALTER TABLE public.follows ENABLE ROW LEVEL SECURITY;

CREATE POLICY follows_select_all ON public.follows
  FOR SELECT TO anon, authenticated USING (true);

CREATE POLICY follows_insert_own ON public.follows
  FOR INSERT TO authenticated WITH CHECK (follower_id = auth.uid());

CREATE POLICY follows_delete_own ON public.follows
  FOR DELETE TO authenticated USING (follower_id = auth.uid());

-- ============================================================================
-- 3. Keep public.users.follower_count + following_count in sync via trigger.
--    Recompute (vs +/- 1 deltas) can't drift; lookups are indexed (PK + the
--    creator_id index above), so the cost is negligible. SECURITY DEFINER so
--    the trigger can write users regardless of the writer's RLS — matches
--    sync_insyts_creator_display_name (20260520120000) and
--    refresh_creator_report_count (20260527120000).
-- ============================================================================
CREATE OR REPLACE FUNCTION public.refresh_follow_counts(p_auth_user_id uuid)
  RETURNS void
  LANGUAGE sql
  SECURITY DEFINER
  SET search_path = public
AS $$
  UPDATE public.users u
     SET follower_count  = (SELECT count(*)::int FROM public.follows WHERE creator_id  = p_auth_user_id),
         following_count = (SELECT count(*)::int FROM public.follows WHERE follower_id = p_auth_user_id)
   WHERE u.auth_user_id = p_auth_user_id;
$$;

CREATE OR REPLACE FUNCTION public.follows_count_sync()
  RETURNS trigger
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path = public
AS $$
BEGIN
  -- Each row touches exactly two users — refresh both.
  IF TG_OP = 'INSERT' THEN
    PERFORM public.refresh_follow_counts(NEW.follower_id);
    PERFORM public.refresh_follow_counts(NEW.creator_id);
    RETURN NEW;
  ELSE -- DELETE (UPDATE is rejected by absence of UPDATE policy)
    PERFORM public.refresh_follow_counts(OLD.follower_id);
    PERFORM public.refresh_follow_counts(OLD.creator_id);
    RETURN OLD;
  END IF;
END;
$$;

DROP TRIGGER IF EXISTS follows_count_sync ON public.follows;
CREATE TRIGGER follows_count_sync
  AFTER INSERT OR DELETE ON public.follows
  FOR EACH ROW
  EXECUTE FUNCTION public.follows_count_sync();

-- ============================================================================
-- 4. Backfill counts from current data. The follows table is empty on first
--    deploy so this resets every user to 0/0 — idempotent and re-runnable.
-- ============================================================================
UPDATE public.users u
   SET follower_count  = (SELECT count(*)::int FROM public.follows WHERE creator_id  = u.auth_user_id),
       following_count = (SELECT count(*)::int FROM public.follows WHERE follower_id = u.auth_user_id);

-- ============================================================================
-- 5. Expose follower_count on creator_search. CREATE OR REPLACE preserves the
--    existing security_invoker = off and grants. Re-asserted as belt-and-braces
--    — the public /insyters page reads this view as anon.
-- ============================================================================
CREATE OR REPLACE VIEW public.creator_search AS
  SELECT
    u.auth_user_id,
    u.display_name,
    u.headline,
    u.bio,
    u.profile_image_url,
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
    u.report_count,
    u.follower_count
  FROM public.users u
  WHERE u.is_creator = true;

ALTER VIEW public.creator_search SET (security_invoker = off);

GRANT SELECT ON public.creator_search TO anon, authenticated;

-- ============================================================================
-- 6. Denormalise creator_auth_user_id onto public.insyts. The per-card follow
--    button on /insyts needs the creator's auth uid; today the table only
--    stores creator_email. Mirrors the creator_display_name denormalisation
--    in 20260520120000_add_insyts_feed_search.sql — same join key
--    (users.email = insyts.creator_email), same trigger shape.
-- ============================================================================
ALTER TABLE public.insyts
  ADD COLUMN creator_auth_user_id uuid;

COMMENT ON COLUMN public.insyts.creator_auth_user_id IS
  'Denormalised copy of users.auth_user_id (matched by creator_email). '
  'Kept in sync by triggers sync_insyts_creator_auth_user_id (on users) '
  'and set_insyt_creator_auth_user_id (BEFORE INSERT on insyts).';

CREATE INDEX insyts_creator_auth_user_id_idx
  ON public.insyts (creator_auth_user_id);

-- Backfill from current users data.
UPDATE public.insyts i
   SET creator_auth_user_id = u.auth_user_id
  FROM public.users u
 WHERE u.email = i.creator_email;

-- Re-sync if a user's email or auth_user_id ever changes (rare but possible).
CREATE OR REPLACE FUNCTION public.sync_insyts_creator_auth_user_id()
  RETURNS trigger
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path = public
AS $$
BEGIN
  UPDATE public.insyts
     SET creator_auth_user_id = NEW.auth_user_id
   WHERE creator_email = NEW.email;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS sync_insyts_creator_auth_user_id ON public.users;
CREATE TRIGGER sync_insyts_creator_auth_user_id
  AFTER UPDATE OF auth_user_id, email ON public.users
  FOR EACH ROW
  WHEN (
    OLD.auth_user_id IS DISTINCT FROM NEW.auth_user_id
    OR OLD.email IS DISTINCT FROM NEW.email
  )
  EXECUTE FUNCTION public.sync_insyts_creator_auth_user_id();

-- Populate on new insyts, regardless of which insert path created the row
-- (edge function, n8n native pipeline, manual SQL, future admin tools).
CREATE OR REPLACE FUNCTION public.set_insyt_creator_auth_user_id()
  RETURNS trigger
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path = public
AS $$
BEGIN
  IF NEW.creator_auth_user_id IS NULL AND NEW.creator_email IS NOT NULL THEN
    SELECT auth_user_id INTO NEW.creator_auth_user_id
      FROM public.users
     WHERE email = NEW.creator_email;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS set_insyt_creator_auth_user_id ON public.insyts;
CREATE TRIGGER set_insyt_creator_auth_user_id
  BEFORE INSERT ON public.insyts
  FOR EACH ROW
  EXECUTE FUNCTION public.set_insyt_creator_auth_user_id();
