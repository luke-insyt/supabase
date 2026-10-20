-- GET-348 (search_enhancements_v3): deterministic player facts for Player search.
--
-- Hard facts (club, league, age, position, foot, minutes…) now come only from
-- structured sources in code (API-Football, and the FuPa / Transfermarkt profile
-- parsers when an area enables them). These tables let those facts build up
-- over time instead of being re-fetched every search:
--   - player_facts: one row per fact a source returned, keyed by the source's own
--     person id (facts exist before the matcher creates a players row). Append-only;
--     the newest valid row per (source, person, field) wins. A reviewer's 👎 appends
--     an 'expiry' marker row instead of updating anything.
--   - club_league_seasons: which clubs a league has in a season (one row per club per
--     fetch of that league's club list). Append-only; the newest fetch wins.
--   - fact_eval_cases: the golden eval set (expected facts for real players), read by
--     `npm run eval:facts`. Kept in a table, not in git, so a player can be erased.
--
-- Scalar columns only (no jsonb in Search tables). Server-only like every Search
-- table: RLS on, no policies, no anon/authenticated grants. Re-runnable.

-- ============================================================================
-- 1. player_facts
-- ============================================================================
create table if not exists public.player_facts (
  id           uuid primary key default gen_random_uuid(),
  area_id      text not null check (char_length(area_id) between 1 and 40),
  kind         text not null default 'fact' check (kind in ('fact', 'expiry')),
  source_kind  text not null check (source_kind in ('wikidata', 'api-football', 'sportmonks', 'fupa', 'transfermarkt')),
  source_id    text not null check (char_length(source_id) between 1 and 200),
  -- for finding a known source person by name before calling the provider again
  name_key     text not null check (char_length(name_key) between 1 and 200),
  birth_year   smallint check (birth_year between 1950 and 2030),
  player_id    uuid references public.players (id) on delete cascade,
  field        text not null check (field in ('age', 'club', 'position', 'foot', 'league', 'nationality', 'gender', 'minutes', 'appearances', 'goals', 'assists')),
  -- null only on an expiry marker
  value        text check (char_length(value) <= 200),
  as_of        text check (char_length(as_of) <= 20),
  ref          text check (char_length(ref) <= 200),
  source_url   text check (char_length(source_url) <= 1000),
  fetched_at   timestamptz not null default now(),
  valid_until  timestamptz,
  review_id    uuid,
  constraint player_facts_value_by_kind check ((kind = 'fact') = (value is not null))
);

create index if not exists player_facts_source_idx on public.player_facts (source_kind, source_id, field, fetched_at desc);
create index if not exists player_facts_name_idx on public.player_facts (area_id, source_kind, name_key);
create index if not exists player_facts_player_idx on public.player_facts (player_id) where player_id is not null;

alter table public.player_facts enable row level security;
revoke all on table public.player_facts from anon, authenticated;

-- ============================================================================
-- 2. club_league_seasons
-- ============================================================================
create table if not exists public.club_league_seasons (
  id               uuid primary key default gen_random_uuid(),
  source_kind      text not null check (source_kind in ('api-football', 'sportmonks', 'fupa', 'transfermarkt')),
  league_source_id text not null check (char_length(league_source_id) between 1 and 100),
  league_name      text not null check (char_length(league_name) between 1 and 200),
  season           text not null check (season ~ '^\d{4}(-\d{2})?$'),
  club_source_id   text not null check (char_length(club_source_id) between 1 and 100),
  club_name        text not null check (char_length(club_name) between 1 and 200),
  -- one fetch of the league's club list = one batch; the newest batch wins
  fetched_at       timestamptz not null default now()
);

create index if not exists club_league_seasons_league_idx on public.club_league_seasons (source_kind, league_source_id, season, fetched_at desc);

alter table public.club_league_seasons enable row level security;
revoke all on table public.club_league_seasons from anon, authenticated;

-- ============================================================================
-- 3. fact_eval_cases
-- ============================================================================
create table if not exists public.fact_eval_cases (
  id                  uuid primary key default gen_random_uuid(),
  area_id             text not null default 'soccer' check (char_length(area_id) between 1 and 40),
  player_name         text not null check (char_length(player_name) between 2 and 200),
  player_id           uuid references public.players (id) on delete cascade,
  birth_year          smallint check (birth_year between 1950 and 2030),
  -- a hint the search had (discovery club), used to anchor the identity like a search would
  hint_club           text check (char_length(hint_club) <= 200),
  season              text not null check (season ~ '^\d{4}(-\d{2})?$'),
  expected_club       text check (char_length(expected_club) <= 200),
  expected_league     text check (char_length(expected_league) <= 200),
  -- "never played Oberliga BW": the player must NOT be in this league this season
  expected_not_league text check (char_length(expected_not_league) <= 200),
  min_minutes         integer check (min_minutes >= 0),
  max_minutes         integer check (max_minutes >= 0),
  note                text check (char_length(note) <= 500),
  review_id           uuid,
  added_by            text check (char_length(added_by) <= 320),
  active              boolean not null default true,
  created_at          timestamptz not null default now(),
  constraint fact_eval_cases_expects_something check (
    expected_club is not null or expected_league is not null or expected_not_league is not null or min_minutes is not null or max_minutes is not null
  )
);

alter table public.fact_eval_cases enable row level security;
revoke all on table public.fact_eval_cases from anon, authenticated;

-- ============================================================================
-- 4. data source types: + fupa / transfermarkt (profile parsers, no key)
-- ============================================================================
alter table public.social_search_area_data_sources drop constraint if exists social_search_area_data_sources_type_check;
alter table public.social_search_area_data_sources
  add constraint social_search_area_data_sources_type_check check (type in ('wikidata', 'api-football', 'sportmonks', 'fupa', 'transfermarkt'));

-- ============================================================================
-- 5. retention: superseded fact rows older than 12 months
-- ============================================================================
-- No pg_cron on the project: the RN server calls this at most once a day per instance.
-- Keeps the newest row per (source, person, field, kind) whatever its age.
create or replace function public.player_facts_prune()
returns integer
language sql
security definer
set search_path = public
as $$
  with ranked as (
    select id, fetched_at,
           row_number() over (partition by source_kind, source_id, field, kind order by fetched_at desc) as rn
    from public.player_facts
  ), gone as (
    delete from public.player_facts f
    using ranked r
    where f.id = r.id and r.rn > 1 and r.fetched_at < now() - interval '12 months'
    returning 1
  )
  select count(*)::integer from gone
$$;

revoke execute on function public.player_facts_prune() from public, anon, authenticated;
grant execute on function public.player_facts_prune() to service_role;
