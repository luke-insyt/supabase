-- Players found by Social Search: one row per real person, and how each
-- search's players were matched to them. Only players a search showed are
-- stored (16+, see the search configuration); their facts and sources stay in
-- that search's result file in the social-search-traces bucket.
--
-- Matching (server/src/agent/social-search/matcher.ts): a shared profile id
-- (player_identifiers) links directly; otherwise candidates come from
-- player_match_candidates() and are scored. A high score links automatically,
-- a middle one waits for an admin, a low one creates a new player.
-- Server-only like the other Social Search tables.

create table public.players (
  id            uuid primary key default gen_random_uuid(),
  display_name  text not null check (char_length(display_name) <= 200),
  -- lowercase, accents and punctuation removed: what matching compares
  name_key      text not null check (char_length(name_key) <= 200),
  birth_date    date,
  birth_year    smallint check (birth_year between 1950 and 2030),
  nationality   text,
  position      text,
  foot          text check (foot in ('left', 'right', 'both')),
  height_cm     smallint check (height_cm between 140 and 220),
  club          text,
  club_country  text,
  sightings     integer not null default 0,
  -- a merge never deletes: the duplicate points at the player that survives
  merged_into   uuid references public.players (id) on delete set null,
  first_seen_at timestamptz not null default now(),
  last_seen_at  timestamptz not null default now(),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

create index players_name_key_trgm_idx on public.players using gin (name_key extensions.gin_trgm_ops) where merged_into is null;
create index players_birth_year_idx on public.players (birth_year) where merged_into is null;
create index players_last_seen_idx on public.players (last_seen_at desc) where merged_into is null;

-- Profile ids that identify a player for certain, e.g. ('fotmob', '1362137')
-- or ('instagram', 'handle').
create table public.player_identifiers (
  kind       text not null check (kind ~ '^[a-z0-9_-]{1,30}$'),
  value      text not null check (char_length(value) between 1 and 200),
  player_id  uuid not null references public.players (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (kind, value)
);

create index player_identifiers_player_idx on public.player_identifiers (player_id);

-- One row per player a search showed. local_id is the player's id inside
-- searches/<search_id>/result.json.gz; the columns are what that search saw.
create table public.player_sightings (
  id              uuid primary key default gen_random_uuid(),
  search_id       uuid not null references public.social_searches (id) on delete cascade,
  local_id        text not null check (char_length(local_id) <= 200),
  player_id       uuid references public.players (id) on delete set null,
  -- the best candidate while an admin decides (match_method = 'review')
  candidate_id    uuid references public.players (id) on delete set null,
  name            text not null check (char_length(name) <= 200),
  name_key        text not null check (char_length(name_key) <= 200),
  age             smallint,
  birth_year      smallint,
  club            text,
  position        text,
  foot            text,
  nationality     text,
  match_pct       smallint,
  match_score     numeric(4, 3),
  match_method    text not null default 'pending'
                  check (match_method in ('pending', 'auto', 'review', 'new', 'admin')),
  matcher_version smallint,
  resolved_by     text,
  resolved_at     timestamptz,
  created_at      timestamptz not null default now(),
  unique (search_id, local_id)
);

create index player_sightings_player_idx on public.player_sightings (player_id);
create index player_sightings_review_idx on public.player_sightings (created_at desc) where match_method in ('pending', 'review');

-- Every admin verdict on "is this sighting that player?": the labelled pairs
-- the matcher's weights are tuned against.
create table public.player_match_decisions (
  id          uuid primary key default gen_random_uuid(),
  sighting_id uuid not null references public.player_sightings (id) on delete cascade,
  player_id   uuid not null references public.players (id) on delete cascade,
  same        boolean not null,
  score       numeric(4, 3),
  decided_by  text not null,
  created_at  timestamptz not null default now()
);

create index player_match_decisions_sighting_idx on public.player_match_decisions (sighting_id);

alter table public.players enable row level security;
alter table public.player_identifiers enable row level security;
alter table public.player_sightings enable row level security;
alter table public.player_match_decisions enable row level security;
revoke all on table public.players, public.player_identifiers, public.player_sightings, public.player_match_decisions
  from anon, authenticated;

-- Candidates for one sighting: similar names (trigram) or the same surname
-- born within a year. The server scores them; this only narrows the field.
create function public.player_match_candidates(p_name_key text, p_birth_year smallint, p_limit integer default 10)
returns setof public.players
language sql
stable
set search_path = public, extensions
as $$
  select p.*
  from public.players p
  where p.merged_into is null
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

revoke execute on function public.player_match_candidates(text, smallint, integer) from public, anon, authenticated;
grant execute on function public.player_match_candidates(text, smallint, integer) to service_role;
