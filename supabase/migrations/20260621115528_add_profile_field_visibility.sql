-- GET-68: let creators hide individual public-profile fields.
-- Adds hide_* flags on users (location/website/email) and a per-row hidden flag
-- on user_social_links. Defaults false so every existing profile is unchanged.
--
-- creator_search is the anon-readable VIEW the public profile reads location/website
-- from; we CREATE OR REPLACE it to NULL out hidden values at the source, so a hidden
-- value never leaves the DB (no client-side flag to leak) and the existing
-- setOptionalPill() empty-hides the pill with no frontend change for non-owners.
-- Email + socials reach visitors via the Webflow CMS sync (sync-creator-to-webflow),
-- which is updated separately to blank hidden values there.
--
-- The SELECT below reproduces 20260530140000_add_creator_search_location_website.sql
-- VERBATIM, changing ONLY location/website to CASE expressions. Re-assert
-- security_invoker/grants/comment as belt-and-braces.

begin;

alter table public.users
  add column if not exists hide_location boolean not null default false,
  add column if not exists hide_website  boolean not null default false,
  add column if not exists hide_email    boolean not null default false;

alter table public.user_social_links
  add column if not exists hidden boolean not null default false;

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
    case when u.hide_location then null else u.location end as location,
    case when u.hide_website  then null else u.website  end as website
  from public.users u
  where u.is_creator = true;

alter view public.creator_search set (security_invoker = off);
grant select on public.creator_search to anon, authenticated;

comment on view public.creator_search is 'Denormalized creator directory for /insyters search + filters + public profile fields (location, website); hidden fields (GET-68) are NULLed here.';

commit;
