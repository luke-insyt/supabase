-- Add creator-profile Sport + Content-Type fields and expose them in
-- creator_search so the /insyters directory can filter on them (multi-select).
--
-- Decision (2026-05-30): an *insyt* keeps a single sport/content_type; a
-- *creator profile* can list MULTIPLE sports/content-types they cover. The
-- /insyters filter is multi-select and matches on these profile fields.
--
-- Storage: simple text[] columns on public.users (the vocabulary is a fixed,
-- code-owned list — js/lib/insyt-taxonomy.js — so no shared-vocab tables /
-- RPC are needed, unlike free-form expertise).
--
-- creator_search is a VIEW: it must be dropped + recreated to add columns. This
-- recreation reproduces the FULL current column set (expertise, report_count,
-- follower_count, search_vector) so nothing regresses, then appends the two new
-- label arrays. Verify against the live view definition before running.

begin;

-- 1. New profile columns (canonical labels from the shared taxonomy).
alter table public.users
  add column if not exists sports        text[] not null default '{}',
  add column if not exists content_types text[] not null default '{}';

comment on column public.users.sports is 'Sports this creator covers (canonical labels from js/lib/insyt-taxonomy.js).';
comment on column public.users.content_types is 'Content types this creator produces (canonical labels).';

-- 2. Recreate creator_search with the full column set + new sports/content_types.
drop view if exists public.creator_search;

create view public.creator_search as
select
  u.auth_user_id,
  u.display_name,
  u.username,
  u.headline,
  u.bio,
  u.profile_image_url,
  u.experience_years,
  u.is_creator,
  coalesce(
    array_agg(distinct et.label) filter (where et.label is not null),
    '{}'
  ) as expertise,
  coalesce(
    array_agg(distinct et.slug) filter (where et.slug is not null),
    '{}'
  ) as expertise_slugs,
  coalesce(u.sports, '{}')        as sports,
  coalesce(u.content_types, '{}') as content_types,
  (
    select count(*)::int
    from public.creator_reports cr
    where cr.creator_id = u.auth_user_id
  ) as report_count,
  (
    select count(*)::int
    from public.user_follows uf
    where uf.creator_id = u.auth_user_id
  ) as follower_count,
  to_tsvector(
    'simple',
    coalesce(u.display_name, '') || ' ' ||
    coalesce(u.headline, '') || ' ' ||
    coalesce(u.bio, '') || ' ' ||
    coalesce(string_agg(et.label, ' '), '')
  ) as search_vector
from public.users u
left join public.creator_expertise ce on ce.user_id = u.auth_user_id
left join public.expertise_tags et on et.id = ce.tag_id
where u.is_creator = true
group by
  u.auth_user_id,
  u.display_name,
  u.username,
  u.headline,
  u.bio,
  u.profile_image_url,
  u.experience_years,
  u.is_creator,
  u.sports,
  u.content_types;

comment on view public.creator_search is 'Denormalized creator directory for /insyters search + filters (incl. sports + content_types).';

commit;
