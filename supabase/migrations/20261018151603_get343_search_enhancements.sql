-- GET-343 (search_enhancements_v1): one vote per target, area versions with a
-- public one, per-version gates and targets, benchmark sets and runs, and a
-- scorecard on every search. Spec: webflow-app-documentation
-- features/social-search/search_enhancements_v1/ (requirements SE9, SE11–SE14;
-- implementation.md W1).
--
-- Scalar columns only (no jsonb stored in Search tables; jsonb is only the
-- argument format of social_search_save_area). Server-only like every Search
-- table: RLS on, no policies, no anon/authenticated grants. Re-runnable
-- (if not exists / drop … if exists / create or replace).

-- ============================================================================
-- 1. Votes: one per voter and target (SE11)
-- ============================================================================

-- Changing a vote used to insert a second row, so a player could be counted
-- twice. Keep each voter's latest row per target (created_at, then id as the
-- tie-break so the delete is deterministic), drop the rest.
delete from public.social_search_reviews r
 using (
   select id,
          row_number() over (
            partition by search_id, auth_user_id, target_kind, target_id
            order by created_at desc, id desc
          ) as rn
     from public.social_search_reviews
    where auth_user_id is not null
 ) d
 where r.id = d.id
   and d.rn > 1;

-- auth_user_id is nullable (on delete set null: a deleted user's votes stay as
-- anonymous history). The index keeps the default NULLS DISTINCT on purpose:
-- with NULLS NOT DISTINCT, deleting a second user who voted on the same target
-- would make the FK's set-null action violate the index and block the user
-- delete. The server always writes auth_user_id, so every live vote is unique,
-- and a plain index still serves `on conflict (search_id, auth_user_id,
-- target_kind, target_id)` upserts (a partial index would need its predicate
-- repeated in every upsert).
create unique index if not exists social_search_reviews_one_per_target
  on public.social_search_reviews (search_id, auth_user_id, target_kind, target_id);

-- When the vote last changed; created_at stays the first vote. Backfilled from
-- created_at so existing rows read as "never changed".
alter table public.social_search_reviews add column if not exists updated_at timestamptz;
update public.social_search_reviews set updated_at = created_at where updated_at is null;
alter table public.social_search_reviews alter column updated_at set default now();
alter table public.social_search_reviews alter column updated_at set not null;

-- ============================================================================
-- 2. Areas: the public version, gates and targets (SE9, SE12, SE13)
-- ============================================================================

-- `version` is the latest saved content; `public_version` is what user searches
-- run on. Backfilled to `version` so every existing area keeps running on its
-- latest save (SE9-AC7).
alter table public.social_search_areas add column if not exists public_version integer;
update public.social_search_areas set public_version = version where public_version is null;
alter table public.social_search_areas alter column public_version set default 1;
alter table public.social_search_areas alter column public_version set not null;
alter table public.social_search_areas drop constraint if exists social_search_areas_public_version_check;
alter table public.social_search_areas
  add constraint social_search_areas_public_version_check check (public_version between 1 and version);

-- Gates (who is shown) and targets (what a good scorecard is), per area
-- version. Defaults = DEFAULT_GATES / DEFAULT_TARGETS in the RN server's
-- agent/social-search/config.ts — keep the two in step. The minimum age stays
-- global (SE12-AC3), so it isn't here.
alter table public.social_search_areas
  add column if not exists min_match                  integer      not null default 80,
  add column if not exists min_verified               integer      not null default 60,
  add column if not exists min_hosts                  integer      not null default 2,
  add column if not exists strong_fit                 integer      not null default 95,
  add column if not exists good_fit                   integer      not null default 88,
  add column if not exists minutes_floor              integer      not null default 900,
  add column if not exists season_calendar            text         not null default 'aug-may',
  add column if not exists max_web_queries            integer      not null default 40,
  add column if not exists show_maybe                 boolean      not null default true,
  add column if not exists max_shown                  integer      not null default 20,
  add column if not exists target_freshness_pct       numeric(5,1) not null default 90,
  add column if not exists target_coverage_pct        numeric(5,1) not null default 80,
  add column if not exists target_league_accuracy_pct numeric(5,1) not null default 100,
  add column if not exists target_min_results         integer      not null default 8,
  add column if not exists target_approval_pct        numeric(5,1) not null default 70;

-- Bounds an admin can't sensibly leave: percentages are 0..100, at least one
-- independent source, a strong fit is never easier than a good fit, and the
-- web-query / shown caps stay within what one search can afford.
alter table public.social_search_areas drop constraint if exists social_search_areas_gates_check;
alter table public.social_search_areas
  add constraint social_search_areas_gates_check check (
    min_match between 0 and 100
    and min_verified between 0 and 100
    and min_hosts between 1 and 10
    and good_fit between 0 and 100
    and strong_fit between good_fit and 100
    and minutes_floor between 0 and 5000
    and season_calendar in ('aug-may', 'calendar')
    and max_web_queries between 1 and 200
    and max_shown between 1 and 100
  );

alter table public.social_search_areas drop constraint if exists social_search_areas_targets_check;
alter table public.social_search_areas
  add constraint social_search_areas_targets_check check (
    target_freshness_pct between 0 and 100
    and target_coverage_pct between 0 and 100
    and target_league_accuracy_pct between 0 and 100
    and target_min_results between 0 and 100
    and target_approval_pct between 0 and 100
  );

-- ============================================================================
-- 3. social_search_save_area: gates + targets; saves no longer go live
-- ============================================================================

-- A new parameter is a new signature, so drop the GET-340 one and recreate.
-- p_gates / p_targets default to NULL = keep the stored values (a server that
-- predates GET-343 can still save during the deploy window); a key missing
-- from the object also keeps its stored value (column default on a create).
-- A create's first save is its public version (SE9-AC2); an update adds a
-- version and never touches public_version (SE9-AC1) — making a version public
-- is social_search_make_area_public. A bad value (wrong type, out of the
-- checks above) raises and rolls the whole save back.
drop function if exists public.social_search_save_area(text, integer, text, text[], text, jsonb, jsonb, jsonb, text, text[]);

create or replace function public.social_search_save_area(
  p_id text,
  p_base_version integer,
  p_name text,
  p_search_terms text[],
  p_follow_up text,
  p_sources jsonb,
  p_questions jsonb,
  p_prompts jsonb,
  p_by text,
  p_insyt_sports text[] default null,
  p_gates jsonb default null,
  p_targets jsonb default null
)
returns integer
language plpgsql
set search_path = public
as $$
declare
  v integer;
  g jsonb := coalesce(p_gates, '{}'::jsonb);
  t jsonb := coalesce(p_targets, '{}'::jsonb);
begin
  if p_base_version = 0 then
    insert into social_search_areas (id, name, search_terms, follow_up_instructions, insyt_sports, sort_order,
                                     version, public_version, updated_by)
    values (p_id, p_name, p_search_terms, p_follow_up, coalesce(p_insyt_sports, '{}'),
            coalesce((select max(sort_order) + 1 from social_search_areas), 0), 1, 1, p_by)
    on conflict (id) do nothing;
    if not found then
      return null;
    end if;
    v := 1;
  else
    update social_search_areas
       set name = p_name, search_terms = p_search_terms, follow_up_instructions = p_follow_up,
           insyt_sports = coalesce(p_insyt_sports, insyt_sports),
           version = version + 1, updated_by = p_by, updated_at = now()
     where id = p_id and version = p_base_version
    returning version into v;
    if v is null then
      return null;
    end if;
  end if;

  update social_search_areas
     set min_match                  = coalesce((g ->> 'minMatch')::integer, min_match),
         min_verified               = coalesce((g ->> 'minVerified')::integer, min_verified),
         min_hosts                  = coalesce((g ->> 'minHosts')::integer, min_hosts),
         strong_fit                 = coalesce((g ->> 'strongFit')::integer, strong_fit),
         good_fit                   = coalesce((g ->> 'goodFit')::integer, good_fit),
         minutes_floor              = coalesce((g ->> 'minutesFloor')::integer, minutes_floor),
         season_calendar            = coalesce(g ->> 'seasonCalendar', season_calendar),
         max_web_queries            = coalesce((g ->> 'maxWebQueries')::integer, max_web_queries),
         show_maybe                 = coalesce((g ->> 'showMaybe')::boolean, show_maybe),
         max_shown                  = coalesce((g ->> 'maxShown')::integer, max_shown),
         target_freshness_pct       = coalesce((t ->> 'freshnessPct')::numeric, target_freshness_pct),
         target_coverage_pct        = coalesce((t ->> 'coveragePct')::numeric, target_coverage_pct),
         target_league_accuracy_pct = coalesce((t ->> 'leagueAccuracyPct')::numeric, target_league_accuracy_pct),
         target_min_results         = coalesce((t ->> 'minResults')::integer, target_min_results),
         target_approval_pct        = coalesce((t ->> 'approvalPct')::numeric, target_approval_pct)
   where id = p_id
     and (p_gates is not null or p_targets is not null);

  delete from social_search_area_sources where area_id = p_id;
  insert into social_search_area_sources (area_id, domain, discovery, lookup, sort_order)
  select p_id, e.val ->> 'domain', (e.val ->> 'discovery')::boolean, (e.val ->> 'lookup')::boolean, e.ord - 1
    from jsonb_array_elements(coalesce(p_sources, '[]'::jsonb)) with ordinality as e (val, ord);

  delete from social_search_area_questions where area_id = p_id;
  insert into social_search_area_questions (area_id, id, question, options, sort_order)
  select p_id, e.val ->> 'id', e.val ->> 'question',
         array(select jsonb_array_elements_text(e.val -> 'options')), e.ord - 1
    from jsonb_array_elements(coalesce(p_questions, '[]'::jsonb)) with ordinality as e (val, ord);

  delete from social_search_area_prompts where area_id = p_id;
  insert into social_search_area_prompts (area_id, key, prompt)
  select p_id, p.key, p.value from jsonb_each_text(coalesce(p_prompts, '{}'::jsonb)) as p;

  return v;
end;
$$;

revoke execute on function public.social_search_save_area(text, integer, text, text[], text, jsonb, jsonb, jsonb, text, text[], jsonb, jsonb)
  from public, anon, authenticated;
grant execute on function public.social_search_save_area(text, integer, text, text[], text, jsonb, jsonb, jsonb, text, text[], jsonb, jsonb)
  to service_role;

-- ============================================================================
-- 4. social_search_make_area_public (SE9-AC6)
-- ============================================================================

-- Any saved version can be made public, older ones too (rollback). Returns the
-- new public version, or NULL when the area doesn't exist or p_version isn't
-- 1..version. Doesn't touch version/updated_at: the content didn't change.
create or replace function public.social_search_make_area_public(p_id text, p_version integer)
returns integer
language plpgsql
set search_path = public
as $$
declare
  v integer;
begin
  update social_search_areas
     set public_version = p_version
   where id = p_id
     and p_version between 1 and version
  returning public_version into v;
  return v;
end;
$$;

revoke execute on function public.social_search_make_area_public(text, integer) from public, anon, authenticated;
grant execute on function public.social_search_make_area_public(text, integer) to service_role;

-- ============================================================================
-- 5. Benchmark sets (SE14-AC1)
-- ============================================================================

-- The test requests an admin runs against a version before making it public.
-- Belongs to the area, not a version: the same set compares every version.
create table if not exists public.social_search_area_benchmarks (
  id         uuid primary key default gen_random_uuid(),
  area_id    text not null references public.social_search_areas (id) on delete cascade,
  request    text not null check (char_length(request) between 3 and 2000),
  sort_order integer not null default 0,
  created_at timestamptz not null default now()
);

create index if not exists social_search_area_benchmarks_area_idx
  on public.social_search_area_benchmarks (area_id, sort_order);

alter table public.social_search_area_benchmarks enable row level security;
revoke all on table public.social_search_area_benchmarks from anon, authenticated;

-- ============================================================================
-- 6. Seed: soccer's set from Matthias's review
-- ============================================================================

-- The four bad searches, then the two good ones, in that order. Texts come from
-- the searches themselves so no request is copied into git. Only staging has
-- these rows; on prod (or with no soccer area, or a set already there) this
-- inserts nothing — the admin builds the set in the app instead.
insert into public.social_search_area_benchmarks (area_id, request, sort_order)
select 'soccer', btrim(s.query), array_position(ids.list, s.id) - 1
  from public.social_searches s,
       (select array[
          '62af224c-2454-46bd-862b-0ae0676b4d28',
          '71790dcd-c35b-4bb2-8ba4-21a93b70b402',
          'e9f21b19-ca7d-4b2b-8317-07ecd98f7e86',
          '19ca9818-a3aa-4514-bf85-2e6ed78dd36a',
          'e2e28a6f-208c-435f-9147-d7b881a41142',
          '35899f4c-1238-40c1-a349-eec2c63f5c77'
        ]::uuid[] as list) ids
 where s.id = any (ids.list)
   and char_length(btrim(s.query)) between 3 and 2000
   and exists (select 1 from public.social_search_areas where id = 'soccer')
   and not exists (select 1 from public.social_search_area_benchmarks where area_id = 'soccer');

-- ============================================================================
-- 7. Benchmark runs (SE14-AC2, AC3)
-- ============================================================================

-- One row per "Run benchmark": which version, who, progress. Its searches point
-- back via social_searches.benchmark_run_id. area_id has no FK, like
-- social_searches.area_id: a run is history and outlives an area's deletion.
create table if not exists public.social_search_benchmark_runs (
  id           uuid primary key default gen_random_uuid(),
  area_id      text not null,
  area_version integer not null check (area_version >= 1),
  started_by   text,
  started_at   timestamptz not null default now(),
  finished_at  timestamptz,
  status       text not null default 'running' check (status in ('running', 'done', 'failed')),
  requests     integer not null check (requests >= 0),
  done         integer not null default 0 check (done between 0 and requests)
);

create index if not exists social_search_benchmark_runs_area_idx
  on public.social_search_benchmark_runs (area_id, area_version, started_at desc);

alter table public.social_search_benchmark_runs enable row level security;
revoke all on table public.social_search_benchmark_runs from anon, authenticated;

-- ============================================================================
-- 8. Searches: version, benchmark marker, scorecard (SE10, SE13, SE14)
-- ============================================================================

-- area_version is the version the search ran on: the public one, except for a
-- benchmark run. Benchmark searches are flagged so budgets and the daily
-- backstop skip them (SE14-AC2) while cost reporting still sums them.
-- Scorecard percentages are NULL when they don't apply (e.g. league accuracy
-- without requested leagues = "n/a").
alter table public.social_searches
  add column if not exists area_id             text,
  add column if not exists area_version        integer check (area_version >= 1),
  add column if not exists is_benchmark        boolean not null default false,
  add column if not exists benchmark_run_id    uuid references public.social_search_benchmark_runs (id) on delete set null,
  add column if not exists freshness_pct       numeric(5,1) check (freshness_pct between 0 and 100),
  add column if not exists coverage_pct        numeric(5,1) check (coverage_pct between 0 and 100),
  add column if not exists league_accuracy_pct numeric(5,1) check (league_accuracy_pct between 0 and 100),
  add column if not exists maybe_count         integer check (maybe_count >= 0),
  add column if not exists approval_pct        numeric(5,1) check (approval_pct between 0 and 100);

-- Per-version averages (benchmark vs public) and a run's searches.
create index if not exists social_searches_area_version_idx
  on public.social_searches (area_id, area_version, created_at desc);
create index if not exists social_searches_benchmark_run_idx
  on public.social_searches (benchmark_run_id) where benchmark_run_id is not null;
