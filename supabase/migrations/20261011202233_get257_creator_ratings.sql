-- GET-257 — rate an Insyter's profile as a whole + the owner-only followers list.
-- Design: webflow-app-documentation/features/creator-profile-rating/feature.md §2.
--
-- Surfaces (RN app only — every read and write goes through the RN API server):
--   * /creators/<auth_user_id> — rating summary (#cp-rating-summary), rate control
--     (#cp-rating-input), owner "Followers · N" list (#cp-followers-open)
--
-- Mirrors 20260529173913_add_insyt_ratings.sql, with these deliberate differences:
--   * integer 1–5 (smallint) — the RN app rates in whole stars;
--   * NO public SELECT policy on either table — who rated a *person* is more
--     sensitive than an insyt rating, and the server (service role) does every read;
--   * the aggregate lives in its own table, not on public.users, so a creator can
--     never write their own average and creator_search needs no rewrite;
--   * refresh_creator_rating deletes the stats row at count 0 and never inserts for a
--     creator whose auth.users row is gone — deleting a rated creator cascades
--     creator_ratings deletes, and this keeps that cascade from tripping the stats FK
--     whatever order Postgres runs the cascades in;
--   * neither function is callable over /rpc;
--   * a DB-level self-rating guard backs up the server check.
--
-- Purely additive. Rollback = drop both tables, both functions, the touch function
-- and follows_creator_id_created_at_idx.

begin;

-- ============================================================================
-- 1. Ratings — one row per (creator, rater); re-rates upsert on the PK.
-- ============================================================================
create table public.creator_ratings (
  creator_id uuid not null references auth.users(id) on delete cascade,
  user_id    uuid not null references auth.users(id) on delete cascade,
  rating     smallint not null check (rating between 1 and 5),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (creator_id, user_id),
  constraint creator_ratings_no_self check (creator_id <> user_id)
);

-- creator_id has the PK prefix; add the reverse for the rater's own-rating lookups
-- and for the user_id cascade on account deletion.
create index creator_ratings_user_id_idx on public.creator_ratings (user_id);

-- RLS on with NO policies → service role only.
alter table public.creator_ratings enable row level security;

-- ============================================================================
-- 2. Aggregate — the row only exists while rating_count > 0.
-- ============================================================================
create table public.creator_rating_stats (
  creator_id   uuid primary key references auth.users(id) on delete cascade,
  rating_avg   numeric(3,2) not null,
  rating_count int not null check (rating_count > 0)
);

-- RLS on with NO policies → service role only (the server exposes the aggregate).
alter table public.creator_rating_stats enable row level security;

-- ============================================================================
-- 3. updated_at is authoritative regardless of the writer.
-- ============================================================================
create or replace function public.touch_creator_ratings_updated_at()
  returns trigger
  language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists touch_creator_ratings_updated_at on public.creator_ratings;
create trigger touch_creator_ratings_updated_at
  before update on public.creator_ratings
  for each row
  execute function public.touch_creator_ratings_updated_at();

-- ============================================================================
-- 4. Recompute one creator's aggregate from scratch (can't drift). SECURITY
--    DEFINER so the trigger can write the stats table regardless of the writer.
-- ============================================================================
create or replace function public.refresh_creator_rating(p uuid)
  returns void
  language plpgsql
  security definer
  set search_path = public
as $$
declare
  c int;
  a numeric(3,2);
begin
  select count(*)::int, round(avg(rating)::numeric, 2)
    into c, a
    from public.creator_ratings
   where creator_id = p;

  if c = 0 then
    delete from public.creator_rating_stats where creator_id = p;
  elsif exists (select 1 from auth.users where id = p) then
    -- the creator is not mid-deletion, so the stats FK can't be violated
    insert into public.creator_rating_stats (creator_id, rating_avg, rating_count)
    values (p, a, c)
    on conflict (creator_id) do update
      set rating_avg   = excluded.rating_avg,
          rating_count = excluded.rating_count;
  end if;
end;
$$;

revoke execute on function public.refresh_creator_rating(uuid) from public, anon, authenticated;

create or replace function public.creator_ratings_stats_sync()
  returns trigger
  language plpgsql
  security definer
  set search_path = public
as $$
begin
  if tg_op = 'INSERT' then
    perform public.refresh_creator_rating(new.creator_id);
    return new;
  elsif tg_op = 'UPDATE' then
    perform public.refresh_creator_rating(new.creator_id);
    if new.creator_id is distinct from old.creator_id then
      perform public.refresh_creator_rating(old.creator_id);
    end if;
    return new;
  else -- DELETE
    perform public.refresh_creator_rating(old.creator_id);
    return old;
  end if;
end;
$$;

revoke execute on function public.creator_ratings_stats_sync() from public, anon, authenticated;

drop trigger if exists creator_ratings_stats_sync on public.creator_ratings;
create trigger creator_ratings_stats_sync
  after insert or update or delete on public.creator_ratings
  for each row
  execute function public.creator_ratings_stats_sync();

-- ============================================================================
-- 5. Owner followers list — newest-first paging over one creator's follows.
--    Supersedes follows_creator_id_idx for these reads; that index is kept to
--    avoid churn.
-- ============================================================================
create index if not exists follows_creator_id_created_at_idx
  on public.follows (creator_id, created_at desc);

commit;
