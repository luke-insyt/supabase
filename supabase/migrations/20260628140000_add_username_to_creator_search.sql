-- Expose username on creator_search so the public creator profile
-- (/creators/<auth_user_id>) can paint the @handle for ALL viewers straight
-- from Supabase. The handle element (#cp-username) was a static Webflow
-- placeholder ("@username") only ever overwritten on the OWNER's own view, so
-- every *visited* profile showed the literal "@username" — and creators with no
-- username had nothing to hide it. (GET-95)
--
-- creator_search is a VIEW: CREATE OR REPLACE appends the new column while
-- preserving the rest. Reproduces the full column set from
-- 20260530140000_add_creator_search_location_website.sql VERBATIM, then appends
-- username. Re-assert security_invoker/grants as belt-and-braces. Username is a
-- public handle (already shown as @username on public profiles), so exposing it
-- on the anon-readable directory view is safe.

begin;

create or replace view public.creator_search as
  select
    u.auth_user_id,
    u.display_name,
    u.headline,
    u.bio,
    u.profile_image_url,
    u.experience_years,
    u.search_vector,
    u.creator_activated_at,
    u.created_at,
    coalesce(
      (select array_agg(t.label order by t.label)
         from public.creator_expertise ce
         join public.expertise_tags t on t.id = ce.tag_id
        where ce.user_id = u.auth_user_id),
      '{}'
    ) as expertise,
    coalesce(
      (select array_agg(t.slug order by t.slug)
         from public.creator_expertise ce
         join public.expertise_tags t on t.id = ce.tag_id
        where ce.user_id = u.auth_user_id),
      '{}'
    ) as expertise_slugs,
    u.report_count,
    u.follower_count,
    coalesce(u.sports, '{}')        as sports,
    coalesce(u.content_types, '{}') as content_types,
    u.location,
    u.website,
    u.username
  from public.users u
  where u.is_creator = true;

alter view public.creator_search set (security_invoker = off);
grant select on public.creator_search to anon, authenticated;

comment on view public.creator_search is 'Denormalized creator directory for /insyters search + filters + public profile fields (location, website, username).';

commit;
