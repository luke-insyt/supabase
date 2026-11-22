-- GET-472 (Player search: search_enhancements_v5, part 4): the area's value model — our own value band
-- (no third-party market values). Estimated value = base value for (country, tier) × one multiplier per
-- enabled factor; the factors themselves are typed plug-ins in code (server value/factors.ts), so the
-- tables hold only their settings: on/off and a bracket table (range → multiplier). Saved with the rest
-- of the area by social_search_save_area (+ p_value_model), so every change is a new area version and
-- the version file carries the model too (never an overwrite of the live one).
--
-- No rows for an area = the code defaults (the GET-472 proposals of 2026-11-21). Scalar columns only
-- (jsonb is only the argument format of social_search_save_area). Server-only like every Search table:
-- RLS on, no policies, no anon/authenticated grants. Re-runnable.

-- ============================================================================
-- 1. bands: A..G ascending by sort_order; the last has no upper limit (max_eur null)
-- ============================================================================
create table if not exists public.social_search_area_value_bands (
  area_id    text not null references public.social_search_areas (id) on delete cascade,
  band       text not null check (band ~ '^[A-Z]$'),
  max_eur    bigint check (max_eur is null or max_eur between 1 and 1000000000),
  sort_order integer not null default 0,
  primary key (area_id, band)
);
alter table public.social_search_area_value_bands enable row level security;
revoke all on table public.social_search_area_value_bands from anon, authenticated;

-- ============================================================================
-- 2. base-value grid: € of a regular starter in their prime, per country per tier
-- ============================================================================
create table if not exists public.social_search_area_value_base (
  area_id  text not null references public.social_search_areas (id) on delete cascade,
  country  text not null check (char_length(country) between 2 and 40),
  tier     integer not null check (tier between 1 and 9),
  base_eur bigint not null check (base_eur between 0 and 1000000000),
  primary key (area_id, country, tier)
);
alter table public.social_search_area_value_base enable row level security;
revoke all on table public.social_search_area_value_base from anon, authenticated;

-- ============================================================================
-- 3. factors (switch) + their brackets (values up to and including up_to get mult; null = no upper limit)
-- ============================================================================
create table if not exists public.social_search_area_value_factors (
  area_id   text not null references public.social_search_areas (id) on delete cascade,
  factor_id text not null check (factor_id ~ '^[a-z][a-z0-9_-]{0,39}$'),
  enabled   boolean not null default true,
  primary key (area_id, factor_id)
);
alter table public.social_search_area_value_factors enable row level security;
revoke all on table public.social_search_area_value_factors from anon, authenticated;

create table if not exists public.social_search_area_value_brackets (
  area_id    text not null,
  factor_id  text not null,
  up_to      numeric check (up_to is null or up_to between 0 and 1000000),
  mult       numeric(6, 3) not null check (mult between 0 and 10),
  sort_order integer not null default 0,
  primary key (area_id, factor_id, sort_order),
  foreign key (area_id, factor_id) references public.social_search_area_value_factors (area_id, factor_id) on delete cascade
);
alter table public.social_search_area_value_brackets enable row level security;
revoke all on table public.social_search_area_value_brackets from anon, authenticated;

-- ============================================================================
-- 4. social_search_save_area: + p_value_model (the GET-355 body otherwise unchanged)
-- ============================================================================
-- A new parameter is a new signature, so drop the GET-355 one and recreate.
drop function if exists public.social_search_save_area(text, integer, text, text[], text, jsonb, jsonb, jsonb, text, text[], jsonb, jsonb, jsonb, jsonb);

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
  p_data_sources jsonb default null,
  p_channels jsonb default null,
  p_value_model jsonb default null
)
returns integer
language plpgsql
set search_path = public
as $$
declare
  v integer;
  g jsonb := coalesce(p_gates, '{}'::jsonb);
  t jsonb := coalesce(p_targets, '{}'::jsonb);
  -- a server from before kinds sends none: each question keeps the kind stored for its id
  old_kinds jsonb := coalesce((select jsonb_object_agg(id, kind) from social_search_area_questions where area_id = p_id), '{}'::jsonb);
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
  insert into social_search_area_questions (area_id, id, question, options, kind, sort_order)
  select p_id, e.val ->> 'id', e.val ->> 'question',
         array(select jsonb_array_elements_text(coalesce(e.val -> 'options', '[]'::jsonb))),
         coalesce(e.val ->> 'kind', old_kinds ->> (e.val ->> 'id'), 'choice'), e.ord - 1
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

  -- GET-355: NULL = keep the stored channels; an array replaces them (incl. '[]').
  if p_channels is not null then
    delete from social_search_area_channels where area_id = p_id;
    insert into social_search_area_channels (area_id, platform, handle, channel_id, label, enabled, sort_order)
    select p_id, e.val ->> 'platform', e.val ->> 'handle', nullif(e.val ->> 'channelId', ''),
           nullif(e.val ->> 'label', ''), coalesce((e.val ->> 'enabled')::boolean, true), e.ord - 1
      from jsonb_array_elements(p_channels) with ordinality as e (val, ord);
  end if;

  -- GET-472: NULL = keep the stored value model; an object replaces it whole (bands, base grid, factors + brackets).
  if p_value_model is not null then
    delete from social_search_area_value_bands where area_id = p_id;
    insert into social_search_area_value_bands (area_id, band, max_eur, sort_order)
    select p_id, e.val ->> 'id', (e.val ->> 'maxEur')::bigint, e.ord - 1
      from jsonb_array_elements(coalesce(p_value_model -> 'bands', '[]'::jsonb)) with ordinality as e (val, ord);

    delete from social_search_area_value_base where area_id = p_id;
    insert into social_search_area_value_base (area_id, country, tier, base_eur)
    select p_id, c.key, t.key::integer, (t.value #>> '{}')::bigint
      from jsonb_each(coalesce(p_value_model -> 'baseGrid', '{}'::jsonb)) as c
     cross join lateral jsonb_each(c.value) as t;

    -- brackets cascade with their factor
    delete from social_search_area_value_factors where area_id = p_id;
    insert into social_search_area_value_factors (area_id, factor_id, enabled)
    select p_id, f.key, coalesce((f.value ->> 'enabled')::boolean, true)
      from jsonb_each(coalesce(p_value_model -> 'factors', '{}'::jsonb)) as f;
    insert into social_search_area_value_brackets (area_id, factor_id, up_to, mult, sort_order)
    select p_id, f.key, (b.val ->> 'upTo')::numeric, (b.val ->> 'mult')::numeric, b.ord - 1
      from jsonb_each(coalesce(p_value_model -> 'factors', '{}'::jsonb)) as f
     cross join lateral jsonb_array_elements(coalesce(f.value -> 'brackets', '[]'::jsonb)) with ordinality as b (val, ord);
  end if;

  return v;
end;
$$;

revoke execute on function public.social_search_save_area(text, integer, text, text[], text, jsonb, jsonb, jsonb, text, text[], jsonb, jsonb, jsonb, jsonb, jsonb)
  from public, anon, authenticated;
grant execute on function public.social_search_save_area(text, integer, text, text[], text, jsonb, jsonb, jsonb, text, text[], jsonb, jsonb, jsonb, jsonb, jsonb)
  to service_role;
