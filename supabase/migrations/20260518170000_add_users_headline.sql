-- Short single-line role/title shown under a creator's name on their public
-- profile (e.g. "Football tactics analyst"). Edited from /edit-creator-profile
-- and mirrored into the Webflow Creators CMS by sync-creator-to-webflow.
-- Length capped at 80 chars on the frontend.

ALTER TABLE public.users
  ADD COLUMN IF NOT EXISTS headline text;
