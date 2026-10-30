-- Social Search: follow-up rounds, reviews and per-user daily budgets.
-- Details stay in the social-search-traces bucket; these rows hold only what
-- is filtered, sorted or summed. Like social_searches: RLS on with no
-- policies and no anon/authenticated grants, so only the RN server (service
-- role) reads or writes them.

-- One row per follow-up round (the questions the assistant asks before a
-- search). The questions, answers and the round's trace are in
-- clarify/<id>.json.gz. search_id stays null when the user never searched.
create table public.social_search_clarify_rounds (
  id                 uuid primary key,
  search_id          uuid references public.social_searches (id) on delete cascade,
  auth_user_id       uuid references auth.users (id) on delete set null,
  user_email         text,
  query              text not null check (char_length(query) <= 500),
  questions_asked    smallint not null default 0,
  questions_answered smallint,
  skipped            boolean,
  tokens_in          integer not null default 0,
  tokens_out         integer not null default 0,
  cost_usd           numeric(10, 4) not null default 0,
  config_version     integer,
  created_at         timestamptz not null default now(),
  used_at            timestamptz
);

create index social_search_clarify_rounds_user_created_idx
  on public.social_search_clarify_rounds (auth_user_id, created_at desc);
create index social_search_clarify_rounds_search_idx
  on public.social_search_clarify_rounds (search_id);

alter table public.social_search_clarify_rounds enable row level security;
revoke all on table public.social_search_clarify_rounds from anon, authenticated;

-- One row per rating a user gives: a whole search (1–5), or a player or one
-- of its facts (-1 / +1, with a reason and an optional correction).
-- target_id is the player's id inside searches/<search_id>/result.json.gz
-- ("<player id>:<field>" for a fact); player_sightings links it to a player.
create table public.social_search_reviews (
  id           uuid primary key default gen_random_uuid(),
  search_id    uuid not null references public.social_searches (id) on delete cascade,
  auth_user_id uuid references auth.users (id) on delete set null,
  user_email   text,
  target_kind  text not null check (target_kind in ('search', 'player', 'fact')),
  target_id    text not null check (char_length(target_id) <= 200),
  player_name  text check (char_length(player_name) <= 200),
  rating       smallint not null,
  reason       text check (char_length(reason) <= 100),
  comment      text check (char_length(comment) <= 2000),
  correction   text check (char_length(correction) <= 300),
  status       text not null default 'new' check (status in ('new', 'reviewed', 'actioned', 'dismissed')),
  reviewed_by  text,
  reviewed_at  timestamptz,
  created_at   timestamptz not null default now(),
  search_text  tsvector generated always as (
    to_tsvector(
      'simple'::regconfig,
      coalesce(player_name, '') || ' ' || coalesce(reason, '') || ' ' || coalesce(comment, '') || ' ' || coalesce(correction, '')
    )
  ) stored,
  constraint social_search_reviews_rating_scale check (
    (target_kind = 'search' and rating between 1 and 5)
    or (target_kind <> 'search' and rating in (-1, 1))
  )
);

create index social_search_reviews_created_idx on public.social_search_reviews (created_at desc);
create index social_search_reviews_status_created_idx on public.social_search_reviews (status, created_at desc);
create index social_search_reviews_search_idx on public.social_search_reviews (search_id);
create index social_search_reviews_text_idx on public.social_search_reviews using gin (search_text);

alter table public.social_search_reviews enable row level security;
revoke all on table public.social_search_reviews from anon, authenticated;

-- A user's own daily budget, when an admin set one (e.g. after a request to
-- info@getinsyts.com). Everyone else gets the default from the search
-- configuration.
create table public.social_search_budgets (
  auth_user_id     uuid primary key references auth.users (id) on delete cascade,
  user_email       text not null,
  daily_budget_usd numeric(8, 2) not null check (daily_budget_usd >= 0),
  note             text check (char_length(note) <= 500),
  updated_by       text,
  updated_at       timestamptz not null default now()
);

alter table public.social_search_budgets enable row level security;
revoke all on table public.social_search_budgets from anon, authenticated;
