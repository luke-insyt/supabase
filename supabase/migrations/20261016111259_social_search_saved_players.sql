-- GET-335: My players — the players a Search user saved from their own
-- searches (My Insyts → My players). One row per user per player (area +
-- name); saving the same player again from a newer search refreshes the facts
-- and keeps the note. Scalar columns only (no jsonb in Search tables); the
-- posts stay in the search's result file, reached by search_id.
-- Only players with a confirmed age at or above the minimum age are saved
-- (enforced by the server, like players). Server-only: RLS on, no policies,
-- no anon/authenticated grants. Re-runnable.

create table if not exists public.social_search_saved_players (
  id           uuid primary key default gen_random_uuid(),
  auth_user_id uuid not null references auth.users (id) on delete cascade,
  area        text not null default 'soccer' check (area ~ '^[a-z0-9-]{1,40}$'),
  -- the search it was saved from; the row outlives the search
  search_id    uuid references public.social_searches (id) on delete set null,
  local_id     text not null check (char_length(local_id) <= 200),
  name         text not null check (char_length(name) <= 200),
  name_key     text not null check (char_length(name_key) <= 200),
  age          text check (char_length(age) <= 200),
  position     text check (char_length(position) <= 200),
  foot         text check (char_length(foot) <= 200),
  club         text check (char_length(club) <= 200),
  nationality  text check (char_length(nationality) <= 200),
  match_pct    smallint check (match_pct between 0 and 100),
  note         text check (char_length(note) <= 1000),
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  unique (auth_user_id, area, name_key)
);

create index if not exists social_search_saved_players_user_idx
  on public.social_search_saved_players (auth_user_id, updated_at desc);

alter table public.social_search_saved_players enable row level security;
revoke all on table public.social_search_saved_players from anon, authenticated;
