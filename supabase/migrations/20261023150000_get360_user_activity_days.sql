-- GET-360 · per-day user activity → weekly active users + a real "Last seen".
-- Spec: webflow-app-documentation/features/user-activity-tracking/requirements.md
--
--   1. user_activity_days — one row per (user, UTC day, surface). Presence of a
--      row = "active that day"; WAU = count(distinct user_id) over 7 days. A
--      single last-active timestamp can't answer "WAU for week N", hence rows.
--   2. touch_user_activity() — the ONLY writer. Web calls it with the user's own
--      JWT (auth.uid()); the RN API server calls it with the service role on
--      behalf of the already-verified caller, so p_user_id is honoured for
--      service_role only — an end user can never mark someone else active.
--      It also stamps users.last_logged_in_at, which existed but nothing wrote
--      (null on every prod row), so the admin "Last seen" column was blank.
--   3. One-off seed of last_logged_in_at from auth.users.last_sign_in_at so
--      "Last seen" isn't empty until each user next shows up.

-- ============================================================================
-- 1. Table
-- ============================================================================
create table if not exists public.user_activity_days (
  user_id uuid not null references auth.users (id) on delete cascade,
  day date not null,
  source text not null check (source in ('web', 'app')),
  first_seen_at timestamptz not null default now(),
  primary key (user_id, day, source)
);

create index if not exists user_activity_days_day_idx on public.user_activity_days (day);

-- RLS on with NO policies: nobody reads or writes it through PostgREST; the
-- RPC below (security definer) and service-role reporting are the only paths.
alter table public.user_activity_days enable row level security;
revoke all on public.user_activity_days from anon, authenticated;

-- ============================================================================
-- 2. Writer
-- ============================================================================
create or replace function public.touch_user_activity(
  p_source text,
  p_user_id uuid default null
)
  returns void
  language plpgsql
  security definer
  set search_path = public
as $$
declare
  v_user uuid := case when auth.role() = 'service_role' then p_user_id else auth.uid() end;
begin
  if v_user is null then
    return;
  end if;
  if p_source not in ('web', 'app') then
    raise exception 'invalid source %', p_source using errcode = '22023';
  end if;

  insert into public.user_activity_days (user_id, day, source)
  values (v_user, (now() at time zone 'utc')::date, p_source)
  on conflict do nothing;

  update public.users
     set last_logged_in_at = now()
   where auth_user_id = v_user;
end;
$$;

revoke all on function public.touch_user_activity(text, uuid) from public, anon;
grant execute on function public.touch_user_activity(text, uuid) to authenticated, service_role;

-- ============================================================================
-- 3. Seed "Last seen" from the last real sign-in
-- ============================================================================
update public.users u
   set last_logged_in_at = a.last_sign_in_at
  from auth.users a
 where a.id = u.auth_user_id
   and u.last_logged_in_at is null
   and a.last_sign_in_at is not null;
