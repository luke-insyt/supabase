-- GET-357: Creator Agreement v1.1 rollout — data layer.
-- Design: webflow-app-documentation/features/agreement-rollout/feature.md §2.1, §3.3
-- Plan:   webflow-app-documentation/features/agreement-rollout/implementation.md "P1"
--
-- Additive only:
--   1. a guard: refuse to run while more than one agreement version is current;
--   2. agreement_versions_one_current: at most one current version, enforced;
--   3. agreement_notices: the per-(user, version) ledger of "terms updated"
--      emails (sending | sent | held | failed), server-only;
--   4. agreement_notices_claim / agreement_notices_record: the RN server's way
--      to claim-before-send and record the outcome. It bans raw `pg`, and
--      supabase-js can't express a conditional upsert, hence RPCs. Both are
--      SECURITY DEFINER and executable by service_role only.
--
-- Making a version current is NOT here: that's the one-off
-- prod-ops/agreement-make-current.sql, so a flip can never ride to prod on the
-- migration path.

begin;

-- 1. Guard -------------------------------------------------------------------
-- The unique index below would fail anyway; this says why, and in words.
do $$
declare
  n integer;
begin
  select count(*) into n from public.agreement_versions where is_current;
  if n > 1 then
    raise exception 'GET-357: % agreement_versions rows are current; leave exactly one current before applying this migration', n;
  end if;
end;
$$;

-- 2. One current version at most -------------------------------------------
-- Zero is allowed here (a flip clears the old row before setting the new one,
-- in one transaction); the flip script refuses to commit with zero.
create unique index if not exists agreement_versions_one_current
  on public.agreement_versions ((true))
  where is_current;

-- 3. Notice ledger -------------------------------------------------------------
-- One row per Insyter per version: a re-run never re-sends `sent`, and retries
-- `held` / `failed` (R2-AC3). Deleting an account deletes its rows (no PII
-- left behind).
create table if not exists public.agreement_notices (
  user_id    uuid not null references auth.users (id) on delete cascade,
  version    text not null,
  status     text not null check (status in ('sending', 'sent', 'held', 'failed')),
  attempts   integer not null default 0,
  last_error text,
  updated_at timestamptz not null default now(),
  primary key (user_id, version)
);

comment on table public.agreement_notices is
  'GET-357: "Creator Agreement updated" email ledger, one row per (auth user, version). '
  'Written only through agreement_notices_claim / agreement_notices_record (service role).';

-- Server-only, like the inquiry tables: RLS on with no policies, and no table
-- privileges for the API roles (Supabase's default privileges grant them ALL
-- on new public tables).
alter table public.agreement_notices enable row level security;
revoke all on public.agreement_notices from anon, authenticated;

-- 4. RPCs ----------------------------------------------------------------------

-- Claim before sending (R2-AC3): returns only the users THIS call claimed.
--   * new (user, version)          → inserted as 'sending', claimed;
--   * 'held' / 'failed'            → back to 'sending', claimed (a retry);
--   * 'sending' for > 15 minutes   → claimed (the run that held it died);
--   * 'sent', or a live 'sending'  → untouched, not returned.
-- Ids are de-duplicated (one ON CONFLICT DO UPDATE can't touch a row twice),
-- and ids with no auth user are dropped rather than failing the whole batch on
-- the foreign key.
create or replace function public.agreement_notices_claim(p_version text, p_user_ids uuid[])
  returns setof uuid
  language sql
  security definer
  set search_path = public
as $$
  insert into public.agreement_notices (user_id, version, status)
  select distinct ids.id, p_version, 'sending'
    from unnest(p_user_ids) as ids(id)
   where ids.id is not null
     and exists (select 1 from auth.users au where au.id = ids.id)
  on conflict (user_id, version) do update
     set status = 'sending',
         updated_at = now()
   where agreement_notices.status in ('held', 'failed')
      or (agreement_notices.status = 'sending'
          and agreement_notices.updated_at < now() - interval '15 minutes')
  returning user_id;
$$;

-- The outcome of one send. Only final statuses: 'sending' is the claim's alone.
create or replace function public.agreement_notices_record(
  p_user_id uuid,
  p_version text,
  p_status  text,
  p_error   text
)
  returns void
  language plpgsql
  security definer
  set search_path = public
as $$
begin
  if p_status is null or p_status not in ('sent', 'held', 'failed') then
    raise exception 'agreement_notices_record: status must be sent, held or failed (got %)', p_status;
  end if;
  update public.agreement_notices
     set status     = p_status,
         attempts   = attempts + 1,
         last_error = p_error,
         updated_at = now()
   where user_id = p_user_id
     and version = p_version;
end;
$$;

-- A new function is executable by PUBLIC, and Supabase's default privileges
-- also grant anon/authenticated directly: lock both down to the service role.
revoke all on function
  public.agreement_notices_claim(text, uuid[]),
  public.agreement_notices_record(uuid, text, text, text)
  from public, anon, authenticated;
grant execute on function
  public.agreement_notices_claim(text, uuid[]),
  public.agreement_notices_record(uuid, text, text, text)
  to service_role;

commit;
