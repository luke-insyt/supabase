-- GET-335: Search configuration per area, as a package: one row per area
-- (name, search terms, follow-up instructions) with its sources, fixed
-- questions and prompts in child tables. Shared settings (minimum age, budget,
-- prices, providers) stay in the versioned config file in the bucket.
--
-- An area is saved whole, with a compare-and-set on `version`
-- (social_search_save_area): a save on top of a newer version changes nothing.
-- The server keeps each saved version as a file too (config/areas/<id>/v<n>),
-- and every search records the area and version it ran with.
-- The first area by sort_order is the default. The server seeds the table
-- from the config file on first read, so nothing is seeded here.
-- Scalar and text[] columns only (no jsonb in Search tables). Server-only:
-- RLS on, no policies, no anon/authenticated grants. Re-runnable.

create table if not exists public.social_search_areas (
  id                     text primary key check (id ~ '^[a-z0-9-]{1,40}$'),
  name                   text not null unique check (char_length(name) between 2 and 40),
  -- added to a player's name in the lookup query: "Name" (footballer OR "soccer player")
  search_terms           text[] not null check (cardinality(search_terms) between 1 and 5),
  follow_up_instructions text not null default '' check (char_length(follow_up_instructions) <= 2000),
  sort_order             integer not null default 0,
  version                integer not null default 1 check (version >= 1),
  updated_by             text,
  updated_at             timestamptz not null default now(),
  created_at             timestamptz not null default now()
);

create table if not exists public.social_search_area_sources (
  area_id    text not null references public.social_search_areas (id) on delete cascade,
  domain     text not null check (char_length(domain) <= 100 and domain ~ '^[a-z0-9-]+(\.[a-z0-9-]+)+$'),
  discovery  boolean not null,
  lookup     boolean not null,
  sort_order integer not null default 0,
  primary key (area_id, domain)
);

create table if not exists public.social_search_area_questions (
  area_id    text not null references public.social_search_areas (id) on delete cascade,
  id         text not null check (id ~ '^[a-z0-9_-]{1,40}$'),
  question   text not null check (char_length(question) between 3 and 160),
  options    text[] not null check (cardinality(options) between 2 and 6),
  sort_order integer not null default 0,
  primary key (area_id, id)
);

create table if not exists public.social_search_area_prompts (
  area_id text not null references public.social_search_areas (id) on delete cascade,
  key     text not null check (key in ('clarify', 'understand', 'plan', 'extract', 'triage', 'enrich', 'score')),
  prompt  text not null check (char_length(prompt) between 20 and 8000),
  primary key (area_id, key)
);

alter table public.social_search_areas enable row level security;
alter table public.social_search_area_sources enable row level security;
alter table public.social_search_area_questions enable row level security;
alter table public.social_search_area_prompts enable row level security;
revoke all on table public.social_search_areas, public.social_search_area_sources,
  public.social_search_area_questions, public.social_search_area_prompts
  from anon, authenticated;

-- Saves one area whole. p_base_version 0 creates it (null if the id exists);
-- otherwise the row must still be at p_base_version (null if someone saved
-- since). Returns the new version. The children are replaced in the same
-- transaction. jsonb is only the argument format, never stored.
create or replace function public.social_search_save_area(
  p_id text,
  p_base_version integer,
  p_name text,
  p_search_terms text[],
  p_follow_up text,
  p_sources jsonb,
  p_questions jsonb,
  p_prompts jsonb,
  p_by text
)
returns integer
language plpgsql
set search_path = public
as $$
declare
  v integer;
begin
  if p_base_version = 0 then
    insert into social_search_areas (id, name, search_terms, follow_up_instructions, sort_order, version, updated_by)
    values (p_id, p_name, p_search_terms, p_follow_up,
            coalesce((select max(sort_order) + 1 from social_search_areas), 0), 1, p_by)
    on conflict (id) do nothing;
    if not found then
      return null;
    end if;
    v := 1;
  else
    update social_search_areas
       set name = p_name, search_terms = p_search_terms, follow_up_instructions = p_follow_up,
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

revoke execute on function public.social_search_save_area(text, integer, text, text[], text, jsonb, jsonb, jsonb, text)
  from public, anon, authenticated;
grant execute on function public.social_search_save_area(text, integer, text, text[], text, jsonb, jsonb, jsonb, text)
  to service_role;
