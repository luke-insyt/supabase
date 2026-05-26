-- Adds creator expertise tags to public.users, a full-text search vector, and a
-- public RLS-bypassing creator_search view that powers the Insyter Search page.
-- See webflow-app-documentation/features/insyter-search-features.md.
--
-- Note: "years of experience" reuses the EXISTING public.users.experience_years
-- (integer) column — no new column is added for it.

-- 1. Expertise tags. Free-form text[] (the controlled vocabulary lives in JS for
--    v1, like FEED_SPORTS in js/feed.js). Default '{}' so existing rows and the
--    generated search_vector below are always well-defined.
ALTER TABLE public.users
  ADD COLUMN IF NOT EXISTS expertise text[] NOT NULL DEFAULT '{}';

-- 2. Creator full-text search vector. Weights mirror the /insyts feed:
--    A = display_name, B = headline + bio, C = expertise tags.
--    'simple' dictionary (no stemming / stop-words) matches the feed and keeps
--    multi-word / multi-language tokens intact.
ALTER TABLE public.users
  ADD COLUMN search_vector tsvector
    GENERATED ALWAYS AS (
      setweight(to_tsvector('simple', coalesce(display_name, '')), 'A') ||
      setweight(to_tsvector('simple', coalesce(headline, '')), 'B') ||
      setweight(to_tsvector('simple', coalesce(bio, '')), 'B') ||
      setweight(to_tsvector('simple', array_to_string(coalesce(expertise, '{}'), ' ')), 'C')
    ) STORED;

COMMENT ON COLUMN public.users.search_vector IS
  'GIN-indexed tsvector for the Insyter Search page. '
  'Weights: A=display_name, B=headline+bio, C=expertise.';

CREATE INDEX IF NOT EXISTS users_search_vector_idx ON public.users USING GIN (search_vector);
CREATE INDEX IF NOT EXISTS users_expertise_idx     ON public.users USING GIN (expertise);

-- 3. Public, RLS-bypassing view exposing ONLY safe public creator columns.
--    public.users RLS is read-own-only ("Users read own": auth.uid() =
--    auth_user_id), so the browser cannot list other creators directly.
--    security_invoker = off makes this view ignore that RLS and return all
--    creator rows (same trick as author_profiles, migration 20260511214223),
--    while exposing a hand-picked safe column set. WHERE is_creator keeps
--    non-creators out of search results.
CREATE OR REPLACE VIEW public.creator_search AS
  SELECT
    auth_user_id,          -- slug for /creators/<auth_user_id>
    display_name,
    headline,
    bio,
    profile_image_url,     -- storage path; frontend resolves via creator-avatars bucket
    expertise,
    experience_years,
    search_vector,
    creator_activated_at,
    created_at
  FROM public.users
  WHERE is_creator = true;

ALTER VIEW public.creator_search SET (security_invoker = off);

-- Public Insyter Search page → anon must read it; authenticated too.
GRANT SELECT ON public.creator_search TO anon, authenticated;
