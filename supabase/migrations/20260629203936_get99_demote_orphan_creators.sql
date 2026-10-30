-- GET-99: creators are now activated at profile completion, not at terms acceptance
-- (accept-agreement no longer sets is_creator; sync-creator-to-webflow flips it once a
-- display name is saved). Clean up the existing half-created creators produced by the
-- old flow: users who accepted the agreement but never set a display name were left
-- is_creator = true, appearing nameless in listings with a 404 profile page.
-- Decision A (Lukas, 2026-06-30): "when no display name is set we should not mark the
-- user as creator." Idempotent: a no-op once these rows are demoted.
begin;

update public.users
   set is_creator = false,
       updated_at = now()
 where is_creator = true
   and coalesce(btrim(display_name), '') = '';

commit;
