-- Extra public profile fields shown on /creators/<slug>. Edited from the
-- Edit Profile modal on that page and mirrored into the Webflow Creators
-- CMS by sync-creator-to-webflow.
--
--   username  - "@handle" shown under the display name. Normalized client-side
--               to [a-z0-9_]{1,30}; no uniqueness check (two users may pick
--               the same handle until we add one).
--   location  - free-form city/region string.
--   website   - personal site URL; stored as plain text so empty/garbage
--               values don't break the row.

ALTER TABLE public.users
  ADD COLUMN IF NOT EXISTS username text,
  ADD COLUMN IF NOT EXISTS location text,
  ADD COLUMN IF NOT EXISTS website  text;
