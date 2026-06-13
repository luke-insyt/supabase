-- Per-creator social media handles shown as pills on /creators/<slug>.
-- One row per (user, platform) so we can add platforms without migrating
-- a wide users table. sync-creator-to-webflow flattens these rows into
-- the matching PlainText fields on the Webflow Creators item.
--
-- Platforms are CHECK-constrained for v1; expand the list when we add a
-- new pill on the profile page.

CREATE TABLE IF NOT EXISTS public.user_social_links (
  id         uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id    uuid        NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  platform   text        NOT NULL CHECK (platform IN ('youtube','instagram','facebook','tiktok')),
  handle     text        NOT NULL,
  position   smallint    NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (user_id, platform)
);

CREATE INDEX IF NOT EXISTS user_social_links_user_id_idx
  ON public.user_social_links (user_id);

ALTER TABLE public.user_social_links ENABLE ROW LEVEL SECURITY;

-- Public read because /creators/<slug> is a public page; tighten later if
-- profiles ever become private.
DROP POLICY IF EXISTS "user_social_links public read" ON public.user_social_links;
CREATE POLICY "user_social_links public read"
  ON public.user_social_links FOR SELECT
  USING (true);

DROP POLICY IF EXISTS "user_social_links owner insert" ON public.user_social_links;
CREATE POLICY "user_social_links owner insert"
  ON public.user_social_links FOR INSERT
  TO authenticated
  WITH CHECK (auth.uid() = user_id);

DROP POLICY IF EXISTS "user_social_links owner update" ON public.user_social_links;
CREATE POLICY "user_social_links owner update"
  ON public.user_social_links FOR UPDATE
  TO authenticated
  USING (auth.uid() = user_id)
  WITH CHECK (auth.uid() = user_id);

DROP POLICY IF EXISTS "user_social_links owner delete" ON public.user_social_links;
CREATE POLICY "user_social_links owner delete"
  ON public.user_social_links FOR DELETE
  TO authenticated
  USING (auth.uid() = user_id);
