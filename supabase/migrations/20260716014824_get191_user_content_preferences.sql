-- GET-191: reader content preferences (gathering-only).
--
-- A dedicated, per-reader store for the content a signed-in reader wants to
-- READ (sports + content-types from the shared taxonomy + free-flow interest
-- tags), plus a prompt-dismissed flag so the one-time /insyts capture prompt
-- never re-nags across devices. This is distinct from users.sports/content_types
-- (the CREATOR profile — "what you publish"): reader-interest lives here so the
-- two meanings never blur. Private to the reader (owner-only RLS, AC7).
--
-- Web writes user-scoped via supabase-js (RLS enforces ownership); RN writes via
-- its Fastify server (supabaseForUser, same RLS). Additive + backwards-compatible
-- so the frontend PR can merge ahead of this staging migration (reads defensive).
-- Idempotent (create-if-not-exists + drop-then-create policies), repo house style
-- (to authenticated, touch_*_updated_at trigger — cf. insyt_ratings migrations).

create table if not exists public.user_content_preferences (
  user_id       uuid primary key references auth.users(id) on delete cascade,
  sports        text[] not null default '{}',
  content_types text[] not null default '{}',
  interests     text[] not null default '{}',   -- custom free-flow tags
  prompt_dismissed_at timestamptz,               -- non-null => never show the /insyts prompt
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

alter table public.user_content_preferences enable row level security;

-- reader owns exactly their own row (private — AC7); authenticated role only
drop policy if exists ucp_select_own on public.user_content_preferences;
create policy ucp_select_own on public.user_content_preferences
  for select to authenticated using (auth.uid() = user_id);
drop policy if exists ucp_insert_own on public.user_content_preferences;
create policy ucp_insert_own on public.user_content_preferences
  for insert to authenticated with check (auth.uid() = user_id);
drop policy if exists ucp_update_own on public.user_content_preferences;
create policy ucp_update_own on public.user_content_preferences
  for update to authenticated using (auth.uid() = user_id) with check (auth.uid() = user_id);
drop policy if exists ucp_delete_own on public.user_content_preferences;
create policy ucp_delete_own on public.user_content_preferences
  for delete to authenticated using (auth.uid() = user_id);

-- keep updated_at fresh (repo convention: the touch_*_updated_at trigger pattern)
create or replace function public.touch_user_content_preferences_updated_at()
returns trigger language plpgsql as $$
begin new.updated_at = now(); return new; end $$;
drop trigger if exists trg_ucp_touch_updated_at on public.user_content_preferences;
create trigger trg_ucp_touch_updated_at before update on public.user_content_preferences
  for each row execute function public.touch_user_content_preferences_updated_at();

-- GET-191 §2b: "Popular interests" suggestions — surface example interest tags
-- other readers use, WITHOUT exposing who uses them. This SECURITY DEFINER
-- aggregate reads across all rows but returns ONLY de-identified {tag, reader_count}
-- and ONLY for tags >= 5 distinct readers share (the privacy floor: a reader's
-- own rare/unique interest can never be echoed back — upholds AC7). Matches the
-- repo's aggregate-RPC convention (creator_subscriber_names / my_viewed_insyts:
-- SECURITY DEFINER + set search_path + revoke from public,anon + grant to
-- authenticated + a GREATEST/LEAST limit clamp so null/negative can't uncap).
create or replace function public.get_popular_interest_tags(_limit int default 20)
returns table (tag text, reader_count int)
language sql stable security definer set search_path = public as $$
  select lower(t) as tag, count(distinct user_id)::int as reader_count
  from public.user_content_preferences, unnest(interests) as t
  where btrim(t) <> ''
  group by lower(t)
  having count(distinct user_id) >= 5   -- privacy + quality floor
  order by reader_count desc, tag
  limit greatest(least(coalesce(_limit, 20), 50), 0);
$$;
revoke all on function public.get_popular_interest_tags(int) from public, anon;
grant execute on function public.get_popular_interest_tags(int) to authenticated;
