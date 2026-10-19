-- Pulled into the repo 2026-10-18 from prod's migration history (applied to prod
-- directly, never committed). Statements verbatim.

create table if not exists public.weekly_digest_state (
  user_id uuid primary key references auth.users(id) on delete cascade,
  last_sent_at timestamptz,
  dormant_streak int not null default 0,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table public.weekly_digest_state is 'Tracks weekly-activity-digest send cursor per user: last_sent_at drives the "since last successful send" window (not a fixed calendar week), dormant_streak counts consecutive sends with nothing to show, is_active=false stops further sends after 5 dormant sends in a row (per Lukas, Sep 2026 planning thread).';

alter table public.weekly_digest_state enable row level security;
