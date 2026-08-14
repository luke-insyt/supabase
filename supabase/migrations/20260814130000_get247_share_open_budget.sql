-- GET-247 · make the anonymous open-rate limiter able to trip at all.
--
-- The bug: shares.ts guarded the anonymous open endpoint (S9-AC10) by COUNTING
-- rows in share_ref_opens whose dedupe_key equalled
--     HMAC("bucket\0<minute>\0<coarsened-ip>")
-- while every row that path ever INSERTS is keyed
--     HMAC("<ref>\0<hour>\0<coarsened-ip>\0<ua-family>")
-- and only for kind='plain'. The two strings can never collide, so the count was
-- always 0 and the ceiling could never be reached. It failed OPEN — nothing was
-- broken for users, the protection simply was not there.
--
-- Why a separate table rather than reusing share_ref_opens:
--   1. that table is per-ref (ref_id is NOT NULL and half the primary key), and a
--      per-IP budget has no ref — there is nothing honest to put in that column;
--   2. S9-AC4(c) forbids a per-open row for a NOTED invite, so anything counted
--      out of share_ref_opens would be blind to exactly the traffic an abuser of
--      an addressed invite would generate. This table is not per-ref, so it sees
--      every anonymous open while still writing no per-open row about a ref.
--
-- What is stored is NOT a new identifier: the key is the same construction §5
-- already uses — HMAC(server-held secret, coarsened IP + minute bucket) — so it
-- is not invertible, the IP is coarsened (/24, /64) BEFORE hashing, and the key
-- rotates every minute, which means it cannot join a visitor across two minutes
-- let alone across links. No ref, no user agent, no user id.
create table if not exists public.share_open_budget (
  bucket_key text primary key,
  hits       integer not null default 0,
  created_at timestamptz not null default now()
);

-- Deny-all RLS, exactly like the other three GET-228 tables: anon must never
-- touch this, and the server reaches it with the service role.
alter table public.share_open_budget enable row level security;

-- Sweepable: the key is only meaningful for its own minute, so anything older is
-- dead weight. Indexed so the retention delete does not scan.
create index if not exists share_open_budget_created_at_idx
  on public.share_open_budget (created_at);

-- One statement, so two concurrent opens cannot both read "under budget" and
-- both pass. Returns the count INCLUDING this hit, so the caller compares against
-- the ceiling directly.
--
-- SECURITY DEFINER with a pinned search_path: the function is the only way this
-- table is written, and callers never pass anything but the already-hashed key.
create or replace function public.share_open_budget_hit(p_key text)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_hits integer;
begin
  insert into public.share_open_budget (bucket_key, hits)
  values (p_key, 1)
  on conflict (bucket_key)
  do update set hits = public.share_open_budget.hits + 1
  returning hits into v_hits;
  return v_hits;
end;
$$;

revoke all on function public.share_open_budget_hit(text) from public, anon, authenticated;
