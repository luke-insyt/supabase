-- GET-121 (SF2) step 2/2 — drop email from author_profiles (the PII fix).
--
-- Apply AFTER the frontend re-route (insyt-detail loadAuthor + create-insyt-native
-- loadAuthorProfile now filter by auth_user_id) has merged to the target env, else
-- those author-name/bio loads break. Removing a column needs DROP+CREATE (CREATE OR
-- REPLACE cannot drop a view column). Re-grant SELECT to anon/authenticated (a fresh
-- view has no grants). After this, `select=email` on the view errors — email is no
-- longer reachable via PostgREST with the publishable key.
drop view if exists public.author_profiles;
create view public.author_profiles as
  select auth_user_id, display_name, bio
  from public.users;
grant select on public.author_profiles to anon, authenticated;
