-- GET-355 (Player search: social channels per area): named YouTube / Instagram / X accounts an area's
-- searches always look at, and fixed questions that take a typed answer ("Any specific social channels
-- we should look at?"). Saved with the rest of the area by social_search_save_area (+ p_channels).
--
-- Scalar columns only (jsonb is only the argument format of social_search_save_area). Server-only like
-- every Search table: RLS on, no policies, no anon/authenticated grants. Re-runnable.

-- ============================================================================
-- 1. social_search_area_channels
-- ============================================================================
-- platform: typed (no TikTok; Facebook pages added — decisions 2026-10-22). handle: the canonical handle without '@'
-- (YouTube: the @handle, or the channel id when there is none). channel_id: YouTube's UC… id,
-- resolved once on save; null on Instagram / X.
create table if not exists public.social_search_area_channels (
  area_id    text not null references public.social_search_areas (id) on delete cascade,
  platform   text not null check (platform in ('youtube', 'instagram', 'facebook', 'x')),
  handle     text not null check (handle ~ '^[A-Za-z0-9._-]{1,100}$'),
  channel_id text check (channel_id is null or channel_id ~ '^UC[A-Za-z0-9_-]{22}$'),
  label      text check (char_length(label) <= 80),
  enabled    boolean not null default true,
  sort_order integer not null default 0,
  primary key (area_id, platform, handle)
);

-- re-run on a DB that has the first version of this table (staging): widen the platform check
alter table public.social_search_area_channels drop constraint if exists social_search_area_channels_platform_check;
alter table public.social_search_area_channels add constraint social_search_area_channels_platform_check check (platform in ('youtube', 'instagram', 'facebook', 'x'));

alter table public.social_search_area_channels enable row level security;
revoke all on table public.social_search_area_channels from anon, authenticated;

-- ============================================================================
-- 2. fixed questions: kind 'choice' (2–6 options, as before) or 'text' (a typed answer; options = suggestions, 0–6)
-- ============================================================================
alter table public.social_search_area_questions add column if not exists kind text not null default 'choice';
alter table public.social_search_area_questions drop constraint if exists social_search_area_questions_kind_check;
alter table public.social_search_area_questions add constraint social_search_area_questions_kind_check check (kind in ('choice', 'text'));
alter table public.social_search_area_questions drop constraint if exists social_search_area_questions_options_check;
alter table public.social_search_area_questions add constraint social_search_area_questions_options_check check (
  (kind = 'choice' and cardinality(options) between 2 and 6) or (kind = 'text' and cardinality(options) between 0 and 6)
);

-- ============================================================================
-- 3. social_search_save_area: + p_channels, + question kind
-- ============================================================================
-- A new parameter is a new signature, so drop the GET-345 one and recreate.
drop function if exists public.social_search_save_area(text, integer, text, text[], text, jsonb, jsonb, jsonb, text, text[], jsonb, jsonb, jsonb);

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
  p_channels jsonb default null
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

  return v;
end;
$$;

revoke execute on function public.social_search_save_area(text, integer, text, text[], text, jsonb, jsonb, jsonb, text, text[], jsonb, jsonb, jsonb, jsonb)
  from public, anon, authenticated;
grant execute on function public.social_search_save_area(text, integer, text, text[], text, jsonb, jsonb, jsonb, text, text[], jsonb, jsonb, jsonb, jsonb)
  to service_role;
