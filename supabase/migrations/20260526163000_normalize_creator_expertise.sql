-- Normalize creator expertise into a SHARED, STANDARDIZED, SEARCHABLE vocabulary.
--
-- Supersedes the per-creator public.users.expertise text[] added in
-- 20260526105653_add_users_expertise_and_creator_search.sql. A free-text array
-- per user can't be shared or standardized across creators ("Tactical Analysis",
-- "tactical analysis" and "Tactics" are three different strings). We move to:
--   public.expertise_tags     — one canonical row per tag (unique slug = dedup)
--   public.creator_expertise  — creator <-> tag links
-- Custom tags AUTO-ADD to the vocabulary, so a tag one creator invents becomes a
-- suggestion everyone else can pick and search by.
--
-- The earlier array migration is already applied on staging, so this is a forward
-- migration (not an in-place edit): it folds any existing arrays into the new
-- tables, then drops the array column + its generated search_vector / view.
-- See webflow-app-documentation/features/insyter-search-features.md.

-- ============================================================================
-- 0. Slug helper — the single source of truth for tag normalization.
--    lower + trim + collapse internal whitespace. IMMUTABLE so it can back a
--    unique index / be reused in the RPC and the data fold below.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.expertise_slugify(p text)
  RETURNS text
  LANGUAGE sql
  IMMUTABLE
  PARALLEL SAFE
AS $$ SELECT lower(regexp_replace(btrim(coalesce(p, '')), '\s+', ' ', 'g')) $$;

-- ============================================================================
-- 1. Canonical tag vocabulary.
-- ============================================================================
CREATE TABLE IF NOT EXISTS public.expertise_tags (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  label       text NOT NULL,                                   -- display form, e.g. "Tactical Analysis"
  slug        text NOT NULL,                                   -- normalized key (expertise_slugify)
  created_by  uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  created_at  timestamptz NOT NULL DEFAULT now()
);

-- One canonical row per normalized label → standardization / dedup.
CREATE UNIQUE INDEX IF NOT EXISTS expertise_tags_slug_key ON public.expertise_tags (slug);

-- ============================================================================
-- 2. Creator <-> tag links. user_id is the auth user id (= auth.uid()), matching
--    public.user_social_links.user_id.
-- ============================================================================
CREATE TABLE IF NOT EXISTS public.creator_expertise (
  user_id    uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  tag_id     uuid NOT NULL REFERENCES public.expertise_tags (id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, tag_id)
);
CREATE INDEX IF NOT EXISTS creator_expertise_tag_idx  ON public.creator_expertise (tag_id);
CREATE INDEX IF NOT EXISTS creator_expertise_user_idx ON public.creator_expertise (user_id);

-- ============================================================================
-- 3. RLS.
--    expertise_tags: the vocabulary is public (picker + Insyter Search are public);
--      any signed-in user may add a tag (auto-add). The unique slug keeps dupes out.
--    creator_expertise: a creator reads/writes ONLY their own links. The public
--      Insyter Search reads tags through creator_search (security_invoker = off),
--      so it doesn't need a public policy here.
-- ============================================================================
ALTER TABLE public.expertise_tags    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.creator_expertise ENABLE ROW LEVEL SECURITY;

CREATE POLICY "expertise_tags read"   ON public.expertise_tags
  FOR SELECT TO anon, authenticated USING (true);
CREATE POLICY "expertise_tags insert" ON public.expertise_tags
  FOR INSERT TO authenticated WITH CHECK (true);

CREATE POLICY "creator_expertise read own"   ON public.creator_expertise
  FOR SELECT TO authenticated USING (user_id = auth.uid());
CREATE POLICY "creator_expertise insert own" ON public.creator_expertise
  FOR INSERT TO authenticated WITH CHECK (user_id = auth.uid());
CREATE POLICY "creator_expertise delete own" ON public.creator_expertise
  FOR DELETE TO authenticated USING (user_id = auth.uid());

-- ============================================================================
-- 4. set_creator_expertise(labels) — atomic "replace my tags with this set".
--    Upserts each label into the shared vocabulary (standardizing via slug) and
--    reconciles the caller's links. SECURITY DEFINER + auth.uid() so the browser
--    can call it directly with just label strings; it can only ever touch the
--    caller's own links.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.set_creator_expertise(p_labels text[])
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path = public
AS $$
DECLARE
  v_uid    uuid := auth.uid();
  v_label  text;
  v_slug   text;
  v_tag_id uuid;
  v_keep   uuid[] := '{}';
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not authenticated';
  END IF;

  FOREACH v_label IN ARRAY coalesce(p_labels, '{}') LOOP
    v_label := btrim(v_label);
    CONTINUE WHEN v_label = '';
    v_slug := public.expertise_slugify(v_label);

    INSERT INTO public.expertise_tags (label, slug, created_by)
      VALUES (v_label, v_slug, v_uid)
      ON CONFLICT (slug) DO NOTHING;
    SELECT id INTO v_tag_id FROM public.expertise_tags WHERE slug = v_slug;

    v_keep := array_append(v_keep, v_tag_id);
    INSERT INTO public.creator_expertise (user_id, tag_id)
      VALUES (v_uid, v_tag_id)
      ON CONFLICT DO NOTHING;
  END LOOP;

  -- Drop links the caller no longer has.
  DELETE FROM public.creator_expertise
    WHERE user_id = v_uid
      AND NOT (tag_id = ANY (v_keep));
END;
$$;

GRANT EXECUTE ON FUNCTION public.set_creator_expertise(text[]) TO authenticated;

-- ============================================================================
-- 5. Fold any existing users.expertise arrays into the new tables before the
--    column is dropped. (Staging has none yet, but prod will run the array
--    migration first, so keep this general.)
-- ============================================================================
INSERT INTO public.expertise_tags (label, slug)
SELECT DISTINCT btrim(tag), public.expertise_slugify(tag)
FROM public.users u
CROSS JOIN LATERAL unnest(u.expertise) AS tag
WHERE btrim(coalesce(tag, '')) <> ''
ON CONFLICT (slug) DO NOTHING;

INSERT INTO public.creator_expertise (user_id, tag_id)
SELECT DISTINCT u.auth_user_id, t.id
FROM public.users u
CROSS JOIN LATERAL unnest(u.expertise) AS tag
JOIN public.expertise_tags t ON t.slug = public.expertise_slugify(tag)
WHERE btrim(coalesce(tag, '')) <> ''
ON CONFLICT DO NOTHING;

-- ============================================================================
-- 6. Tear down the array-based pieces from 20260526105653. The view depends on
--    both expertise and the generated search_vector, so drop it first.
-- ============================================================================
DROP VIEW IF EXISTS public.creator_search;

DROP INDEX IF EXISTS public.users_expertise_idx;
ALTER TABLE public.users DROP COLUMN IF EXISTS search_vector;   -- generated col read expertise
ALTER TABLE public.users DROP COLUMN IF EXISTS expertise;
DROP FUNCTION IF EXISTS public.expertise_search_text(text[]);

-- ============================================================================
-- 7. Re-add the creator search_vector WITHOUT the tag dependency. Tag matching
--    on the search page goes through the aggregated expertise array on the view
--    (.overlaps); free-text still covers name / headline / bio.
-- ============================================================================
ALTER TABLE public.users
  ADD COLUMN search_vector tsvector
    GENERATED ALWAYS AS (
      setweight(to_tsvector('simple', coalesce(display_name, '')), 'A') ||
      setweight(to_tsvector('simple', coalesce(headline, '')), 'B') ||
      setweight(to_tsvector('simple', coalesce(bio, '')), 'B')
    ) STORED;

COMMENT ON COLUMN public.users.search_vector IS
  'GIN-indexed tsvector for Insyter Search free-text. Weights: A=display_name, '
  'B=headline+bio. Expertise is matched via creator_search.expertise (.overlaps).';

CREATE INDEX IF NOT EXISTS users_search_vector_idx ON public.users USING GIN (search_vector);

-- ============================================================================
-- 8. Rebuild creator_search: expose each creator's tags as aggregated label +
--    slug arrays so the public search page can display them and filter with
--    .overlaps('expertise_slugs', [...]). security_invoker = off bypasses the
--    read-own RLS on users + creator_expertise (same trick as author_profiles).
-- ============================================================================
CREATE VIEW public.creator_search AS
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
    ) AS expertise_slugs
  FROM public.users u
  WHERE u.is_creator = true;

ALTER VIEW public.creator_search SET (security_invoker = off);

GRANT SELECT ON public.creator_search TO anon, authenticated;
