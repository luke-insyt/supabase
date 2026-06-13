-- Stores the Webflow CMS Creators item id once we've synced a user's
-- profile to Webflow. Lets sync-creator-to-webflow PATCH the same item
-- on subsequent saves instead of looking it up by slug each time, and
-- lets submit-create-insyt forward the id to n8n so newly published
-- Insyts get the `creator` reference set in one shot.

ALTER TABLE public.users
  ADD COLUMN IF NOT EXISTS webflow_creator_id text;

CREATE INDEX IF NOT EXISTS idx_users_webflow_creator_id
  ON public.users (webflow_creator_id)
  WHERE webflow_creator_id IS NOT NULL;
