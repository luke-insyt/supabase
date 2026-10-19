-- GET-340: Player search shows GetInsyt insyts (locked, free fields only).
--
-- THE HARD RULE: the search pipeline (and every model call) only ever sees an
-- insyt's freely available fields — never body_html / body_text, attachments,
-- video_url / video_storage_path, storage_path, creator_email, stripe_* or any
-- other paid/internal column. Enforced HERE, not in the prompt or the app:
--
--   * role insyt_search_reader (LOGIN, no grants on any table) — the RN server's
--     data/insyt-search.ts connects as it (INSYT_SEARCH_DB_URL) and nothing else does;
--   * schema insyt_search — NOT in PostgREST's exposed schemas, and Supabase's
--     default privileges (ALL to anon/authenticated) only cover `public`, so
--     nothing here is reachable through /rest/v1;
--   * insyt_search.eligible — the ONE allow-list (columns) + eligibility WHERE;
--     no grants to anyone: only the definer functions below read it;
--   * insyt_search.match / insyt_search.by_ids — SECURITY DEFINER, EXECUTE for
--     the reader only. Their RETURNS TABLE is the shape the server can ever get.
--
-- Why definer functions over a view: a view in `public` would inherit the default
-- grants (ALL → anon/authenticated) and, owned by postgres, skip RLS; a simple
-- view can even be auto-updatable. Functions give one read-only entry point.
--
-- A column added to public.insyts later is NOT exposed unless it is added to
-- insyt_search.eligible — that is the point.
--
-- The reader's PASSWORD is not set here (no secrets in git). Set it per project
-- with a pre-hashed SCRAM verifier or in the dashboard SQL editor — never inline
-- in a shell command or a Management API call.
--
-- Also: social_search_areas.insyt_sports — which insyts.sport values an area's
-- searches look at (Football (soccer) → Soccer), editable in Admin → Search areas.

-- ============================================================================
-- 1. Search areas: insyt_sports
-- ============================================================================

alter table public.social_search_areas
  add column if not exists insyt_sports text[] not null default '{}'
    check (cardinality(insyt_sports) <= 10);

update public.social_search_areas
   set insyt_sports = '{Soccer}'
 where id = 'soccer' and insyt_sports = '{}';

-- The save takes the sports too. Dropped and recreated (a new parameter is a new
-- signature); p_insyt_sports defaults to NULL = keep the stored value, so a server
-- that predates GET-340 can still save during the deploy window.
drop function if exists public.social_search_save_area(text, integer, text, text[], text, jsonb, jsonb, jsonb, text);

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
  p_insyt_sports text[] default null
)
returns integer
language plpgsql
set search_path = public
as $$
declare
  v integer;
begin
  if p_base_version = 0 then
    insert into social_search_areas (id, name, search_terms, follow_up_instructions, insyt_sports, sort_order, version, updated_by)
    values (p_id, p_name, p_search_terms, p_follow_up, coalesce(p_insyt_sports, '{}'),
            coalesce((select max(sort_order) + 1 from social_search_areas), 0), 1, p_by)
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

revoke execute on function public.social_search_save_area(text, integer, text, text[], text, jsonb, jsonb, jsonb, text, text[])
  from public, anon, authenticated;
grant execute on function public.social_search_save_area(text, integer, text, text[], text, jsonb, jsonb, jsonb, text, text[])
  to service_role;

-- ============================================================================
-- 2. The reader role and its private schema
-- ============================================================================

-- CREATE ROLE is not idempotent; staging applies via the GitHub integration and
-- prod via the Management API, so guard it.
do $$
begin
  if not exists (select 1 from pg_catalog.pg_roles where rolname = 'insyt_search_reader') then
    create role insyt_search_reader login noinherit;
  end if;
end
$$;

alter role insyt_search_reader set statement_timeout = '5s';

create schema if not exists insyt_search;
revoke all on schema insyt_search from public, anon, authenticated;
grant usage on schema insyt_search to insyt_search_reader;

-- ============================================================================
-- 3. The allow-list: the ONLY columns that can ever leave through this schema
-- ============================================================================

-- Owned by postgres, no grants: read only from inside the definer functions.
-- Deduped on insyt_id (nullable, not unique on insyts) — the newest-published wins.
create or replace view insyt_search.eligible as
select distinct on (i.insyt_id)
       i.insyt_id::text              as insyt_id,
       i.title::text                 as title,
       i.abstract                    as abstract,
       i.sport::text                 as sport,
       i.content_type::text          as content_type,
       coalesce(i.tags, '{}')        as tags,
       i.published_at                as published_at,
       i.price_eur                   as price_eur,
       i.rating_avg                  as rating_avg,
       i.rating_count                as rating_count,
       i.creator_auth_user_id        as creator_id,
       i.creator_display_name::text  as creator_display_name,
       u.profile_image_url::text     as creator_avatar
  from public.insyts i
  left join public.users u on u.auth_user_id = i.creator_auth_user_id
 where i.status in ('live', 'published')
   and i.is_hidden = false
   and i.visibility = 'public'
   and i.insyt_id is not null
 order by i.insyt_id, i.published_at desc nulls last, i.updated_at desc nulls last;

revoke all on insyt_search.eligible from public, anon, authenticated, insyt_search_reader;

-- ============================================================================
-- 4. match — candidates for one search round
-- ============================================================================

-- Players: each full name as an exact phrase (phraseto_tsquery, no prefix) in
-- title, tags or abstract — never creator_display_name, so a player "Hansen"
-- doesn't hit every insyt by an Insyter called Hansen. Up to 30, first.
-- Request: any one of the summary terms (plainto_tsquery each, OR'd with ||) —
-- no caller text is ever parsed as tsquery syntax. Fills the rest up to p_max (≤ 40).
-- Both limited to p_sports (case-insensitive: older rows store 'soccer').
-- Input caps: names ≤ 20, terms ≤ 10, each 2..60 chars.
create or replace function insyt_search.match(
  p_names text[],
  p_terms text[],
  p_sports text[],
  p_max integer default 40
)
returns table (
  insyt_id text,
  title text,
  abstract text,
  sport text,
  content_type text,
  tags text[],
  published_at timestamptz,
  price_eur integer,
  rating_avg numeric,
  rating_count integer,
  creator_id uuid,
  creator_display_name text,
  creator_avatar text,
  matched_player text
)
language sql
stable
security definer
set search_path = ''
as $$
  with
  args as (
    select least(greatest(coalesce(p_max, 40), 0), 40) as n,
           array(select pg_catalog.lower(s) from pg_catalog.unnest(coalesce(p_sports, '{}'::text[])) as s
                  where s is not null and pg_catalog.length(s) <= 60) as sports
  ),
  names as (
    select pg_catalog.btrim(x.n) as name, x.i
      from pg_catalog.unnest(coalesce(p_names, '{}'::text[])) with ordinality as x (n, i)
     where x.i <= 20 and pg_catalog.length(pg_catalog.btrim(x.n)) between 2 and 60
  ),
  term_q as (
    select q
      from (
        select pg_catalog.plainto_tsquery('simple', pg_catalog.btrim(x.t)) as q
          from pg_catalog.unnest(coalesce(p_terms, '{}'::text[])) with ordinality as x (t, i)
         where x.i <= 10 and pg_catalog.length(pg_catalog.btrim(x.t)) between 2 and 60
      ) s
     where pg_catalog.numnode(q) > 0
  ),
  docs as (
    select e.*,
           pg_catalog.to_tsvector('simple',
             e.title || ' ' || pg_catalog.array_to_string(e.tags, ' ') || ' ' || e.abstract) as doc
      from insyt_search.eligible e, args
     where pg_catalog.lower(e.sport) = any (args.sports)
  ),
  player_hits as (
    select distinct on (d.insyt_id) d.*, nm.name as matched_player
      from docs d
      join names nm on d.doc @@ pg_catalog.phraseto_tsquery('simple', nm.name)
     order by d.insyt_id, nm.i
  ),
  players as (
    select * from player_hits
     order by published_at desc nulls last
     limit (select least(30, n) from args)
  ),
  request_q as (
    -- OR of every term's query (each already a plainto_tsquery, so its text form is
    -- safe tsquery syntax); NULL when there are no usable terms
    select (select pg_catalog.string_agg('(' || q::text || ')', ' | ') from term_q)::pg_catalog.tsquery as q
  ),
  requests as (
    select d.*, null::text as matched_player, pg_catalog.ts_rank(d.doc, rq.q) as rank
      from docs d, request_q rq
     where rq.q is not null
       and d.doc @@ rq.q
       and d.insyt_id not in (select p.insyt_id from players p)
     order by rank desc, d.published_at desc nulls last
     limit (select greatest(n - (select count(*) from players), 0) from args)
  )
  select insyt_id, title, abstract, sport, content_type, tags, published_at, price_eur,
         rating_avg, rating_count, creator_id, creator_display_name, creator_avatar, matched_player
    from players
  union all
  select insyt_id, title, abstract, sport, content_type, tags, published_at, price_eur,
         rating_avg, rating_count, creator_id, creator_display_name, creator_avatar, matched_player
    from requests
$$;

-- ============================================================================
-- 5. by_ids — display fields for stored ids (no abstract)
-- ============================================================================

-- What a saved search shows on every open: anything no longer eligible (hidden,
-- unpublished, made private) simply isn't returned and drops out.
create or replace function insyt_search.by_ids(p_ids text[])
returns table (
  insyt_id text,
  title text,
  sport text,
  content_type text,
  tags text[],
  published_at timestamptz,
  price_eur integer,
  rating_avg numeric,
  rating_count integer,
  creator_id uuid,
  creator_display_name text,
  creator_avatar text
)
language sql
stable
security definer
set search_path = ''
as $$
  select e.insyt_id, e.title, e.sport, e.content_type, e.tags, e.published_at, e.price_eur,
         e.rating_avg, e.rating_count, e.creator_id, e.creator_display_name, e.creator_avatar
    from insyt_search.eligible e
   where e.insyt_id = any (
     array(select x from pg_catalog.unnest(coalesce(p_ids, '{}'::text[])) with ordinality as u (x, i) where u.i <= 50)
   )
$$;

-- Functions are EXECUTE-able by PUBLIC by default — take that away first.
revoke all on function insyt_search.match(text[], text[], text[], integer) from public, anon, authenticated;
revoke all on function insyt_search.by_ids(text[]) from public, anon, authenticated;
grant execute on function insyt_search.match(text[], text[], text[], integer) to insyt_search_reader;
grant execute on function insyt_search.by_ids(text[]) to insyt_search_reader;

comment on schema insyt_search is
  'GET-340: the only door from Player search to insyts. Not exposed via PostgREST. '
  'Role insyt_search_reader may only EXECUTE match/by_ids, which return the free-field allow-list in insyt_search.eligible.';
