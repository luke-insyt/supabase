-- GET-335: costs that happen after a search finished (today: a player
-- profile's brief — summary + English headlines, one cheap model call on first
-- open). Dated when they happen, so the daily budget counts them on the day
-- they were spent, whatever day the search ran. Scalar columns only.
-- Server-only: RLS on, no policies, no anon/authenticated grants. Re-runnable.

create table if not exists public.social_search_extra_costs (
  id           uuid primary key default gen_random_uuid(),
  auth_user_id uuid not null references auth.users (id) on delete cascade,
  -- the search it belongs to; the cost stays (and counts) if the search is deleted
  search_id    uuid references public.social_searches (id) on delete set null,
  kind         text not null check (kind in ('brief')),
  cost_usd     numeric(10, 4) not null check (cost_usd >= 0),
  created_at   timestamptz not null default now()
);

create index if not exists social_search_extra_costs_user_day_idx
  on public.social_search_extra_costs (auth_user_id, created_at);

alter table public.social_search_extra_costs enable row level security;
revoke all on table public.social_search_extra_costs from anon, authenticated;
