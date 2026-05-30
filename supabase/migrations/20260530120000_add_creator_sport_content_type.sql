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

-- 2. Expose the new sports/content_types on creator_search.
--    CREATE OR REPLACE (append-only) preserves the existing security_invoker = off
--    and grants; the two new columns are appended last. This reproduces the live
--    definition from 20260529130000_add_follows.sql VERBATIM (report_count and
--    follower_count are maintained users columns, search_vector is a stored column,
--    expertise is a correlated subquery — NOT aggregates), then appends sports +
--    content_types. Re-assert security_invoker/grants as belt-and-braces.
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
    coalesce(u.content_types, '{}') as content_types
  from public.users u
  where u.is_creator = true;

alter view public.creator_search set (security_invoker = off);
grant select on public.creator_search to anon, authenticated;

comment on view public.creator_search is 'Denormalized creator directory for /insyters search + filters (incl. sports + content_types).';

commit;
