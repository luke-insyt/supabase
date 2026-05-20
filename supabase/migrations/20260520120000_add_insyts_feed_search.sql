-- Adds full-text search + a denormalised creator display name to
-- public.insyts so the /insyts feed can query Supabase directly instead
-- of relying on Webflow CMS's 100-item pagination cap and DOM-level
-- filtering. See webflow-app-documentation/features/feed-features.md →
-- "Planned rebuild" for the design decisions this migration enacts.

-- 1. Denormalise users.display_name onto insyts so search_vector can be
--    self-contained (no join in the hot path).
ALTER TABLE public.insyts
  ADD COLUMN creator_display_name text;

COMMENT ON COLUMN public.insyts.creator_display_name IS
  'Denormalised copy of users.display_name (matched by creator_email). '
  'Kept in sync by triggers sync_insyts_creator_display_name (on users) '
  'and set_insyt_creator_display_name (BEFORE INSERT on insyts).';

UPDATE public.insyts i
   SET creator_display_name = u.display_name
  FROM public.users u
 WHERE u.email = i.creator_email;

-- 2. Add the FTS column. Weighting:
--    A: title
--    B: creator display name, abstract
--    C: sport, content_type
-- 'simple' dictionary (no stemming, no stop-words) keeps multi-language
-- sport tokens intact ("Padel", "Futsal", "BJJ"). Language-aware
-- dictionaries are captured in feed-features.md → Later improvements.
ALTER TABLE public.insyts
  ADD COLUMN search_vector tsvector
    GENERATED ALWAYS AS (
      setweight(to_tsvector('simple', coalesce(title, '')), 'A') ||
      setweight(to_tsvector('simple', coalesce(creator_display_name, '')), 'B') ||
      setweight(to_tsvector('simple', coalesce(abstract, '')), 'B') ||
      setweight(to_tsvector('simple', coalesce(sport, '')), 'C') ||
      setweight(to_tsvector('simple', coalesce(content_type, '')), 'C')
    ) STORED;

COMMENT ON COLUMN public.insyts.search_vector IS
  'GIN-indexed tsvector for the /insyts feed search. Weights: '
  'A=title, B=creator_display_name+abstract, C=sport+content_type.';

CREATE INDEX insyts_search_vector_idx
  ON public.insyts USING GIN (search_vector);

-- 3. Partial index for the default "no-filter, newest first" feed query.
--    Most pageviews hit this path (anonymous browsers landing on /insyts
--    with no query string). Sport/content-type filter queries fall back
--    to a sequential scan, which is fine at our current row count and
--    can be revisited if it shows up in pg_stat_statements.
CREATE INDEX insyts_feed_created_at_idx
  ON public.insyts (created_at DESC)
  WHERE status = 'live' AND is_hidden = false;

-- 4. Keep creator_display_name in sync when a user renames themselves.
CREATE OR REPLACE FUNCTION public.sync_insyts_creator_display_name()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  UPDATE public.insyts
     SET creator_display_name = NEW.display_name
   WHERE creator_email = NEW.email;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS sync_insyts_creator_display_name ON public.users;
CREATE TRIGGER sync_insyts_creator_display_name
  AFTER UPDATE OF display_name ON public.users
  FOR EACH ROW
  WHEN (OLD.display_name IS DISTINCT FROM NEW.display_name)
  EXECUTE FUNCTION public.sync_insyts_creator_display_name();

-- 5. Populate creator_display_name on new insyts. Belt-and-braces so the
--    column is correct regardless of which path inserted the row
--    (create-insyt edge function, n8n create-insyt-native pipeline,
--    manual SQL, future admin tools).
CREATE OR REPLACE FUNCTION public.set_insyt_creator_display_name()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.creator_display_name IS NULL AND NEW.creator_email IS NOT NULL THEN
    SELECT display_name INTO NEW.creator_display_name
      FROM public.users
     WHERE email = NEW.creator_email;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS set_insyt_creator_display_name ON public.insyts;
CREATE TRIGGER set_insyt_creator_display_name
  BEFORE INSERT ON public.insyts
  FOR EACH ROW
  EXECUTE FUNCTION public.set_insyt_creator_display_name();
