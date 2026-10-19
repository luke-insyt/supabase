-- GET-345 (search_enhancements_v2): structured data sources per area version
-- (typed connector adapters: wikidata, api-football, sportmonks), saved with
-- the rest of the area's package by social_search_save_area.
--
-- Scalar columns only (no jsonb stored in Search tables; jsonb is only the
-- argument format of social_search_save_area). No key material here: keys live
-- in GCP Secret Manager (server env vars) and never in a table, version file
-- or argument. Server-only like every Search table: RLS on, no policies, no
-- anon/authenticated grants. Re-runnable.

-- ============================================================================
-- 1. social_search_area_data_sources
-- ============================================================================

-- One row per area and connector type (each type at most once per area).
-- type: only the adapters written in code — never a free-form URL (decision 2026-10-18).
-- leagues: provider league names or ids; empty = any league. The regex check
--   is "no element longer than 80 chars" without a subquery (checks can't have one):
--   joined with U+0001, no run of 81 non-separator chars may appear.
-- daily_cap: informational (calls past it are logged, never blocked).
-- plan_*: price per call = plan_price_usd / plan_requests per plan_period, computed in code.
create table if not exists public.social_search_area_data_sources (
  area_id        text not null references public.social_search_areas (id) on delete cascade,
  type           text not null check (type in ('wikidata', 'api-football', 'sportmonks')),
  roles          text[] not null check (cardinality(roles) between 1 and 3 and roles <@ array['discovery', 'lookup', 'verify']::text[]),
  leagues        text[] not null default '{}' check (
                   cardinality(leagues) <= 50
                   and array_position(leagues, null) is null
                   and array_to_string(leagues, chr(1)) !~ ('[^' || chr(1) || ']{81}')
                 ),
  priority       integer not null default 0 check (priority between 0 and 100),
  enabled        boolean not null default true,
  daily_cap      integer check (daily_cap is null or daily_cap between 1 and 10000000),
  plan_price_usd numeric(10, 2) not null default 0 check (plan_price_usd >= 0),
  plan_requests  integer check (plan_requests is null or plan_requests > 0),
  plan_period    text not null default 'month' check (plan_period in ('day', 'month')),
  sort_order     integer not null default 0,
  primary key (area_id, type)
);

alter table public.social_search_area_data_sources enable row level security;
revoke all on table public.social_search_area_data_sources from anon, authenticated;

-- ============================================================================
-- 2. social_search_save_area: + p_data_sources
-- ============================================================================

-- A new parameter is a new signature, so drop the GET-343 one and recreate.
-- p_data_sources defaults to NULL = keep the stored rows (a server that
-- predates GET-345 can still save during the deploy window); '[]' clears them.
-- Otherwise the rows are replaced in the same transaction as the sources; a
-- bad value (unknown type, role, a type twice) raises and rolls the save back.
-- Everything else is unchanged from 20261018151603_get343_search_enhancements.sql.
drop function if exists public.social_search_save_area(text, integer, text, text[], text, jsonb, jsonb, jsonb, text, text[], jsonb, jsonb);

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
  p_targets jsonb default null,
  p_data_sources jsonb default null
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

  -- GET-345: NULL = keep the stored data sources; an array replaces them (incl. '[]').
  if p_data_sources is not null then
    delete from social_search_area_data_sources where area_id = p_id;
    insert into social_search_area_data_sources (area_id, type, roles, leagues, priority, enabled, daily_cap,
                                                 plan_price_usd, plan_requests, plan_period, sort_order)
    select p_id,
           e.val ->> 'type',
           array(select jsonb_array_elements_text(coalesce(e.val -> 'roles', '[]'::jsonb))),
           array(select jsonb_array_elements_text(coalesce(e.val -> 'leagues', '[]'::jsonb))),
           coalesce((e.val ->> 'priority')::integer, 0),
           coalesce((e.val ->> 'enabled')::boolean, true),
           (e.val ->> 'dailyCap')::integer,
           coalesce((e.val ->> 'planPriceUsd')::numeric, 0),
           (e.val ->> 'planRequests')::integer,
           coalesce(e.val ->> 'planPeriod', 'month'),
           e.ord - 1
      from jsonb_array_elements(p_data_sources) with ordinality as e (val, ord);
  end if;

  return v;
end;
$$;

revoke execute on function public.social_search_save_area(text, integer, text, text[], text, jsonb, jsonb, jsonb, text, text[], jsonb, jsonb, jsonb)
  from public, anon, authenticated;
grant execute on function public.social_search_save_area(text, integer, text, text[], text, jsonb, jsonb, jsonb, text, text[], jsonb, jsonb, jsonb)
  to service_role;
