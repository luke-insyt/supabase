-- GET-84: creator sponsor links on the public profile.
--
-- A creator can list up to 5 sponsor links (title + description + outbound URL) that
-- render on /creators/<slug> below the specialties. Stored as a JSONB array of
-- { title, description, url } on public.users — the same row the Edit-Profile modal
-- already owns (display_name, headline, bio, *_image_url). The frontend reads it
-- defensively (missing/empty -> section hidden) and normalizes shape + https-only URL
-- + the cap of 5 client-side (src/lib/sponsor-links.ts), so this column is just storage.
--
-- Additive + backwards-compatible: a single nullable JSONB column with a '[]' default.
-- No new RLS policy needed — public.users already exposes owner-only UPDATE (the avatar/
-- cover/profile saves use .update().eq('auth_user_id', auth.uid())) and public SELECT of
-- creator profile rows; a new column inherits those row-level policies.

ALTER TABLE public.users
  ADD COLUMN IF NOT EXISTS sponsor_links jsonb NOT NULL DEFAULT '[]'::jsonb;

COMMENT ON COLUMN public.users.sponsor_links IS
  'GET-84: ordered array of {title, description, url} sponsor links shown on the public creator profile (max 5, https-only; normalized client-side).';
