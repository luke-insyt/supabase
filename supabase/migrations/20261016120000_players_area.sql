-- GET-335: players are per area. Search runs per area (football, and any an
-- admin adds), and a namesake in another area must never be matched to a
-- football player. Existing rows are football ('soccer', the config's built-in
-- area id). Profile ids stay global: a site's player id is one person.
--
-- Backward compatible: the new columns default to 'soccer', and the candidates
-- function keeps its old arguments (p_area defaults to 'soccer'), so a server
-- from before areas keeps working. Re-runnable.

alter table public.players
  add column if not exists area text not null default 'soccer' check (area ~ '^[a-z0-9-]{1,40}$');
alter table public.player_sightings
  add column if not exists area text not null default 'soccer' check (area ~ '^[a-z0-9-]{1,40}$');

create index if not exists players_area_idx on public.players (area, last_seen_at desc) where merged_into is null;

-- Candidates for one sighting, now only among players of its area.
drop function if exists public.player_match_candidates(text, smallint, integer);
create or replace function public.player_match_candidates(
  p_name_key text,
  p_birth_year smallint,
  p_limit integer default 10,
  p_area text default 'soccer'
)
returns setof public.players
language sql
stable
set search_path = public, extensions
as $$
  select p.*
  from public.players p
  where p.merged_into is null
    and p.area = p_area
    and (
      p.name_key % p_name_key
      or (
        p_birth_year is not null
        and p.birth_year between p_birth_year - 1 and p_birth_year + 1
        and regexp_replace(p.name_key, '^.* ', '') = regexp_replace(p_name_key, '^.* ', '')
      )
    )
  order by similarity(p.name_key, p_name_key) desc
  limit least(greatest(p_limit, 1), 25)
$$;

revoke execute on function public.player_match_candidates(text, smallint, integer, text) from public, anon, authenticated;
grant execute on function public.player_match_candidates(text, smallint, integer, text) to service_role;
