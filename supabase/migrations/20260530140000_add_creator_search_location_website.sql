-- Expose location + website on creator_search so the public creator profile
-- (/creators/<auth_user_id>) can paint these optional fields for ALL viewers
-- straight from Supabase, instead of relying on Webflow CMS bindings that
-- weren't wired (bug: optional fields never appeared even when filled). (#1)
--
-- creator_search is a VIEW: CREATE OR REPLACE appends the two new columns while
-- preserving the rest. This reproduces the full column set from
-- 20260530120000_add_creator_sport_content_type.sql VERBATIM, then appends
-- location + website. Re-assert security_invoker/grants as belt-and-braces.

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
    u.website
  from public.users u
  where u.is_creator = true;

alter view public.creator_search set (security_invoker = off);
grant select on public.creator_search to anon, authenticated;

comment on view public.creator_search is 'Denormalized creator directory for /insyters search + filters + public profile fields (location, website).';

commit;
