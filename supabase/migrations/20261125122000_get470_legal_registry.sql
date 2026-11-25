-- GET-470 P2 — migration B: legal registry, acceptance ledger, RPCs, triggers, columns.
--
-- Design: webflow-app-documentation/features/legal-terms-acceptance/feature.md §2.2 (3–6),
--         §2.3–2.6
-- Plan:   webflow-app-documentation/features/legal-terms-acceptance/implementation.md "P2"
--         items 1–13, in that order (section numbers below = plan item numbers).
-- Tests:  supabase/tests/get470_legal_registry_test.ts (PGlite, offline, runs this file)
--         supabase/tests/legal_registry_test.py + legal_ledger_test.py (PostgREST, staging)
--         supabase/tests/sql/legal_destructive.sql (psql, branch/local DB only)
--
-- DEPLOY ORDER (feature.md §2.2 hazard): only after migration A
-- (20261125121000_get470_registry_columns.sql) AND after every `is_current` reader filters
-- on document_type = 'insyter_agreement' in this environment (RN server requireCurrentAgreement
-- / currentAgreement / agreement-notify, edge fns accept-agreement + submit-create-insyt,
-- prod-ops/legal-make-current.sql). Only then may a non-Insyter row be made current.
--
-- Making a version current is NEVER a migration: supabase/prod-ops/legal-make-current.sql.
--
-- Everything is in one transaction: a failed guard leaves the schema exactly as it was.

begin;

-- ============================================================================
-- 1. Uniqueness per type
-- ============================================================================
-- The legacy FK agreement_acceptances.version → agreement_versions(version): declared inline
-- (`version varchar NOT NULL REFERENCES public.agreement_versions(version)`) in
-- 20260503222540_create_agreement_acceptances.sql, so Postgres named it
-- agreement_acceptances_version_fkey. It depends on the unique key below, so it goes first.
-- No IF EXISTS on purpose: a different name in some environment must fail loudly here, not
-- leave a dangling dependency.
alter table public.agreement_acceptances
  drop constraint agreement_acceptances_version_fkey;

-- agreement_versions_version_key UNIQUE (version): 20260503212044_add_agreement_versions_version_unique.sql
-- (also present in 20260503161943_remote_schema.sql:204-205).
alter table public.agreement_versions
  drop constraint agreement_versions_version_key;

alter table public.agreement_versions
  add constraint agreement_versions_type_version_key unique (document_type, version);

-- Every new row must name its type (AC1.1): the default only backfilled existing rows.
alter table public.agreement_versions
  alter column document_type drop default;

-- ============================================================================
-- 2. One current version PER TYPE (AC1.3)
-- ============================================================================
-- agreement_versions_one_current ON ((true)) WHERE is_current:
-- 20261111130000_get357_agreement_rollout.sql §2.
drop index public.agreement_versions_one_current;

create unique index agreement_versions_one_current_per_type
  on public.agreement_versions (document_type)
  where is_current;

-- ============================================================================
-- 3. Pin the Insyter Agreement v1.0 hash, then sha256 NOT NULL
-- ============================================================================
-- SQL can't fetch a file and a fresh DB never runs ops scripts, so the hash is a literal.
-- Computed 2026-11-25 over the raw bytes served at
--   https://xeqjairmlwnjtmselyvo.supabase.co/storage/v1/object/public/creator-agreements/terms/creator-agreement-v1.0.html (staging)
--   https://krapqgxrqprtajatxjzd.supabase.co/storage/v1/object/public/creator-agreements/terms/creator-agreement-v1.0.html (prod)
-- (bucket_path 'terms/creator-agreement-v1.0.html', 20260519180000_repoint_agreement_v1_0_to_bucket.sql):
-- 6172 bytes, IDENTICAL on both projects. The evidence view's hash_check keeps verifying
-- this value against the live file (AC10.4).
update public.agreement_versions
   set sha256 = '673fb82af840b1e6d2ab16097ad973d35159bb840f1bc44e5bf256a9213c13a0'
 where document_type = 'insyter_agreement'
   and version = 'v1.0'
   and sha256 is null;

do $$
declare
  bad  text;
  pin  text;
begin
  select sha256 into pin
    from public.agreement_versions
   where document_type = 'insyter_agreement' and version = 'v1.0';
  if pin is not null and pin <> '673fb82af840b1e6d2ab16097ad973d35159bb840f1bc44e5bf256a9213c13a0' then
    raise exception 'GET-470: insyter_agreement v1.0 already carries a different sha256 (%) — two different v1.0 texts; escalate, do not overwrite', pin;
  end if;
  select string_agg(format('%s %s', document_type, version), ', ') into bad
    from public.agreement_versions
   where sha256 is null;
  if bad is not null then
    raise exception 'GET-470: agreement_versions rows without sha256 (%) — hash their served file and set sha256 before applying this migration', bad;
  end if;
end;
$$;

alter table public.agreement_versions
  alter column sha256 set not null;

-- ============================================================================
-- 4. Immutable once published (AC1.4) + read-only API grants (AC1.5)
-- ============================================================================
-- Only is_current may change, plus sha256 going null → value once. Triggers fire for the
-- service role too, so this holds for the server and the SQL editor alike. effective_date and
-- title are frozen with the rest (both NOT NULL, remote_schema.sql:73-82): legal-publish
-- supplies them, legal-make-current never touches them.
create or replace function public.agreement_versions_immutable()
  returns trigger
  language plpgsql
  set search_path = public, pg_temp
as $$
begin
  if tg_op in ('DELETE', 'TRUNCATE') then
    raise exception 'agreement_versions: a published legal version can never be removed (GET-470 AC1.4)'
      using errcode = 'P0001';
  end if;
  -- UPDATE
  if (to_jsonb(new) - 'is_current' - 'sha256') is distinct from (to_jsonb(old) - 'is_current' - 'sha256') then
    raise exception 'agreement_versions: % % is published and immutable; only is_current may change (GET-470 AC1.4)',
      old.document_type, old.version
      using errcode = 'P0001';
  end if;
  if new.sha256 is distinct from old.sha256 and old.sha256 is not null then
    raise exception 'agreement_versions: the sha256 of % % is already set and can never change (GET-470 AC1.4)',
      old.document_type, old.version
      using errcode = 'P0001';
  end if;
  return new;
end;
$$;

revoke execute on function public.agreement_versions_immutable() from public, anon, authenticated, service_role;

drop trigger if exists agreement_versions_immutable_update on public.agreement_versions;
create trigger agreement_versions_immutable_update
  before update on public.agreement_versions
  for each row execute function public.agreement_versions_immutable();

drop trigger if exists agreement_versions_no_delete on public.agreement_versions;
create trigger agreement_versions_no_delete
  before delete on public.agreement_versions
  for each row execute function public.agreement_versions_immutable();

drop trigger if exists agreement_versions_no_truncate on public.agreement_versions;
create trigger agreement_versions_no_truncate
  before truncate on public.agreement_versions
  for each statement execute function public.agreement_versions_immutable();

-- remote_schema.sql:484-485 granted ALL to anon/authenticated; the "Public read" SELECT policy
-- (remote_schema.sql:248) stays.
revoke all on public.agreement_versions from anon, authenticated;
grant select on public.agreement_versions to anon, authenticated;

-- ============================================================================
-- 5. The acceptance ledger (AC2.1, AC2.2, AC2.5)
-- ============================================================================
create table if not exists public.terms_acceptances (
  id             uuid primary key default gen_random_uuid(),
  auth_user_id   uuid not null,              -- no FK: rows outlive the account (S8)
  email          text,                       -- the AUTH user's email at the time (never Stripe's
                                             -- editable customer_details.email); nulled on anonymisation
  signature_name text,                       -- typed name (insyter_agreement only); nulled on anonymisation
  document_type  text not null,
  version        text not null,
  sha256         text not null,              -- copied from the registry row at insert, never from a client
  context        text not null
                 constraint terms_acceptances_context_check check (context in
                   ('signup', 'checkout', 'subscription', 'proposal', 'reaccept', 'become_insyter', 'fixture')),
  reference_id   text,                       -- Stripe session id · proposal id · null
  accepted_at    timestamptz not null,       -- the moment the user confirmed
  recorded_at    timestamptz not null default now(),
  ip             inet,
  user_agent     text,
  anonymised_at  timestamptz,
  constraint terms_acceptances_version_fkey
    foreign key (document_type, version) references public.agreement_versions (document_type, version)
);

comment on table public.terms_acceptances is
  'GET-470: append-only ledger of legal acceptances (Terms, Privacy acknowledgement, withdrawal '
  'waiver, Insyter Agreement). Written only through record_terms_acceptance / '
  'record_insyter_acceptance / submit_inquiry_proposal (service role). The only allowed update '
  'is anonymise_terms_acceptances (account deletion).';
comment on column public.terms_acceptances.context is
  'fixture = staging test seeding (legal-seed-fixtures.ts), never written in prod.';

create index if not exists terms_acceptances_user_type_idx
  on public.terms_acceptances (auth_user_id, document_type, accepted_at desc);

-- Webhook retries / replays are no-ops (AC4.4): record_terms_acceptance inserts with
-- ON CONFLICT DO NOTHING against this index.
create unique index if not exists terms_acceptances_ref_once
  on public.terms_acceptances (context, reference_id, document_type)
  where reference_id is not null;

alter table public.terms_acceptances enable row level security;

drop policy if exists terms_acceptances_select_own on public.terms_acceptances;
create policy terms_acceptances_select_own on public.terms_acceptances
  for select
  to authenticated
  using (auth_user_id = auth.uid());

-- Supabase's default privileges grant ALL on a new public table to the API roles.
revoke all on public.terms_acceptances from anon, authenticated;
grant select on public.terms_acceptances to authenticated;
grant all on public.terms_acceptances to service_role;

-- Append-only, even for the service role. The ONE allowed update is the anonymise path:
-- email / signature_name / ip / user_agent → null and anonymised_at set, nothing else, once.
create or replace function public.terms_acceptances_append_only()
  returns trigger
  language plpgsql
  set search_path = public, pg_temp
as $$
declare
  pii constant text[] := array['email', 'signature_name', 'ip', 'user_agent', 'anonymised_at'];
begin
  if tg_op in ('DELETE', 'TRUNCATE') then
    raise exception 'terms_acceptances is append-only: rows can never be deleted (GET-470 AC2.2)'
      using errcode = 'P0001';
  end if;
  if old.anonymised_at is null
     and new.anonymised_at is not null
     and new.email is null
     and new.signature_name is null
     and new.ip is null
     and new.user_agent is null
     and (to_jsonb(new) - pii) = (to_jsonb(old) - pii) then
    return new;
  end if;
  raise exception 'terms_acceptances is append-only: the only allowed update is anonymisation (GET-470 AC2.2, AC8.2)'
    using errcode = 'P0001';
end;
$$;

revoke execute on function public.terms_acceptances_append_only() from public, anon, authenticated, service_role;

drop trigger if exists terms_acceptances_append_only_update on public.terms_acceptances;
create trigger terms_acceptances_append_only_update
  before update on public.terms_acceptances
  for each row execute function public.terms_acceptances_append_only();

drop trigger if exists terms_acceptances_no_delete on public.terms_acceptances;
create trigger terms_acceptances_no_delete
  before delete on public.terms_acceptances
  for each row execute function public.terms_acceptances_append_only();

drop trigger if exists terms_acceptances_no_truncate on public.terms_acceptances;
create trigger terms_acceptances_no_truncate
  before truncate on public.terms_acceptances
  for each statement execute function public.terms_acceptances_append_only();

-- ============================================================================
-- 6. RPCs (service_role only — see the grant block at the end of this section)
-- ============================================================================
-- Null-current rule (implementation.md): a type with no current row is "not yet live" —
-- legal_current() omits it, buyer_terms_status reports it as null + accepted.

-- The current row per type. /api/legal/current and the gates.
create or replace function public.legal_current()
  returns setof public.agreement_versions
  language sql
  stable
  security definer
  set search_path = public, pg_temp
as $$
  select * from public.agreement_versions where is_current order by document_type;
$$;

-- THE one definition of "has this user accepted the current Terms?" — the RN checkout gate
-- and the create-subscription-checkout-session edge fn both call it. Always exactly one row.
create or replace function public.buyer_terms_status(p_user uuid)
  returns table (
    buyer_terms          text,
    privacy              text,
    withdrawal_waiver    text,
    accepted_buyer_terms boolean,
    acknowledged_privacy boolean
  )
  language sql
  stable
  security definer
  set search_path = public, pg_temp
as $$
  with cur as (
    select max(version) filter (where document_type = 'buyer_terms')::text       as bt,
           max(version) filter (where document_type = 'privacy')::text           as pv,
           max(version) filter (where document_type = 'withdrawal_waiver')::text as ww
      from public.agreement_versions
     where is_current
  )
  select cur.bt,
         cur.pv,
         cur.ww,
         cur.bt is null or exists (
           select 1 from public.terms_acceptances t
            where t.auth_user_id = p_user and t.document_type = 'buyer_terms' and t.version = cur.bt),
         cur.pv is null or exists (
           select 1 from public.terms_acceptances t
            where t.auth_user_id = p_user and t.document_type = 'privacy' and t.version = cur.pv)
    from cur;
$$;

-- One ledger row. sha256 is copied from the registry, never taken from the caller.
--   p_require_current = true  → raises 'terms_changed' (P0001) unless p_version is current
--                               for p_type (AC2.3).
--   p_require_current = false → the checkout webhook: the version was checked at session
--                               creation and consented to then.
-- Returns the new row id, or null when terms_acceptances_ref_once already has the
-- (context, reference, type) — a webhook retry/replay.
-- Unknown (type, version) → raises 'unknown_version'. p_email null → auth.users email.
-- p_ip is text and cast leniently: a malformed value is stored as null, never an error.
create or replace function public.record_terms_acceptance(
  p_user            uuid,
  p_email           text,
  p_type            text,
  p_version         text,
  p_context         text,
  p_reference       text        default null,
  p_accepted_at     timestamptz default null,
  p_ip              text        default null,
  p_ua              text        default null,
  p_require_current boolean     default true
)
  returns uuid
  language plpgsql
  volatile
  security definer
  set search_path = public, pg_temp
as $$
declare
  v_sha     text;
  v_current boolean;
  v_ip      inet;
  v_id      uuid;
begin
  if p_user is null then
    raise exception 'record_terms_acceptance: p_user is required' using errcode = '22004';
  end if;

  select av.sha256, coalesce(av.is_current, false)
    into v_sha, v_current
    from public.agreement_versions av
   where av.document_type = p_type
     and av.version = p_version;
  if not found then
    raise exception 'unknown_version'
      using errcode = 'P0001', detail = format('no agreement_versions row %s %s', p_type, p_version);
  end if;
  if coalesce(p_require_current, true) and not v_current then
    raise exception 'terms_changed'
      using errcode = 'P0001', detail = format('%s %s is not the current version', p_type, p_version);
  end if;

  begin
    v_ip := nullif(btrim(p_ip), '')::inet;
  exception when others then
    v_ip := null;
  end;

  insert into public.terms_acceptances (
    auth_user_id, email, signature_name, document_type, version, sha256, context,
    reference_id, accepted_at, ip, user_agent
  ) values (
    p_user,
    coalesce(nullif(btrim(p_email), ''), (select u.email::text from auth.users u where u.id = p_user)),
    null,
    p_type,
    p_version,
    v_sha,
    p_context,
    nullif(btrim(p_reference), ''),
    coalesce(p_accepted_at, now()),
    v_ip,
    nullif(left(p_ua, 1000), '')
  )
  on conflict (context, reference_id, document_type) where reference_id is not null do nothing
  returning id into v_id;

  return v_id;
end;
$$;

-- accept-agreement: the legacy agreement_acceptances row AND the ledger row (with
-- signature_name) in ONE transaction, so the dual write can't half-succeed (feature §2.5,
-- §3.6). Context: become_insyter when the user has no insyter_agreement ledger row yet, else
-- reaccept. Raises 'terms_changed' unless p_version is the current insyter_agreement.
-- Returns the ledger row id. Dual write removed in P7.
create or replace function public.record_insyter_acceptance(
  p_user           uuid,
  p_email          text,
  p_signature_name text,
  p_version        text,
  p_ip             text default null,
  p_ua             text default null
)
  returns uuid
  language plpgsql
  volatile
  security definer
  set search_path = public, pg_temp
as $$
declare
  v_current text;
  v_sha     text;
  v_email   text;
  v_name    text := nullif(btrim(p_signature_name), '');
  v_ip      inet;
  v_at      timestamptz := now();
  v_context text;
  v_id      uuid;
begin
  if p_user is null then
    raise exception 'record_insyter_acceptance: p_user is required' using errcode = '22004';
  end if;
  if v_name is null then
    raise exception 'signature_required' using errcode = 'P0001';
  end if;

  select av.version::text, av.sha256
    into v_current, v_sha
    from public.agreement_versions av
   where av.document_type = 'insyter_agreement'
     and av.is_current;
  if v_current is null or p_version is distinct from v_current then
    raise exception 'terms_changed'
      using errcode = 'P0001',
            detail = format('insyter_agreement %s is not the current version (%s)', p_version, v_current);
  end if;

  v_email := coalesce(nullif(btrim(p_email), ''), (select u.email::text from auth.users u where u.id = p_user));
  if v_email is null then
    -- agreement_acceptances.email is NOT NULL (20260503222540).
    raise exception 'record_insyter_acceptance: no email for user %', p_user using errcode = '22004';
  end if;

  begin
    v_ip := nullif(btrim(p_ip), '')::inet;
  exception when others then
    v_ip := null;
  end;

  v_context := case
    when exists (select 1 from public.terms_acceptances t
                  where t.auth_user_id = p_user and t.document_type = 'insyter_agreement')
      then 'reaccept'
    else 'become_insyter'
  end;

  insert into public.agreement_acceptances (auth_user_id, email, signature_name, version, ip, accepted_at)
  values (p_user, v_email, v_name, v_current, host(v_ip), v_at);

  insert into public.terms_acceptances (
    auth_user_id, email, signature_name, document_type, version, sha256, context,
    reference_id, accepted_at, ip, user_agent
  ) values (
    p_user, v_email, v_name, 'insyter_agreement', v_current, v_sha, v_context,
    null, v_at, v_ip, nullif(left(p_ua, 1000), '')
  )
  returning id into v_id;

  return v_id;
end;
$$;

-- Account deletion (AC8.1–8.3): ledger rows keep auth_user_id raw (OQ-8) but lose email,
-- signature_name, ip, user_agent. Legacy agreement_acceptances (while it exists):
-- email / signature_name are NOT NULL there (20260503222540:4-5), so they become the fixed
-- token 'deleted-user'; ip is nulled. P7 recreates this without the legacy update BEFORE
-- dropping the table. Returns the number of ledger rows anonymised.
create or replace function public.anonymise_terms_acceptances(p_user uuid)
  returns integer
  language plpgsql
  volatile
  security definer
  set search_path = public, pg_temp
as $$
declare
  n integer;
begin
  update public.terms_acceptances
     set email = null,
         signature_name = null,
         ip = null,
         user_agent = null,
         anonymised_at = now()
   where auth_user_id = p_user
     and anonymised_at is null;
  get diagnostics n = row_count;

  update public.agreement_acceptances
     set email = 'deleted-user',
         signature_name = 'deleted-user',
         ip = null
   where auth_user_id = p_user
     and (email <> 'deleted-user' or signature_name <> 'deleted-user' or ip is not null);

  return n;
end;
$$;

-- Postgres grants EXECUTE to PUBLIC by default and Supabase also grants anon/authenticated
-- directly (20261108120000_get375_inquiries_round2.sql:213-222). Without this any signed-in
-- user could forge acceptance rows for anyone.
revoke all on function
  public.legal_current(),
  public.buyer_terms_status(uuid),
  public.record_terms_acceptance(uuid, text, text, text, text, text, timestamptz, text, text, boolean),
  public.record_insyter_acceptance(uuid, text, text, text, text, text),
  public.anonymise_terms_acceptances(uuid)
  from public, anon, authenticated;
grant execute on function
  public.legal_current(),
  public.buyer_terms_status(uuid),
  public.record_terms_acceptance(uuid, text, text, text, text, text, timestamptz, text, text, boolean),
  public.record_insyter_acceptance(uuid, text, text, text, text, text),
  public.anonymise_terms_acceptances(uuid)
  to service_role;

-- ============================================================================
-- 7. Deletion backstop: AFTER DELETE ON auth.users (AC8.1)
-- ============================================================================
-- Covers every deletion path in one place (edge fn delete-account, RN DELETE /api/me, Studio).
-- SECURITY DEFINER: it fires as supabase_auth_admin. Precedent on auth.users:
-- on_auth_user_created (20260503161943_remote_schema.sql:583). A failure here would roll back
-- the user delete itself, hence the legacy NOT NULL columns get a token, not null.
create or replace function public.auth_user_deleted_anonymise_terms()
  returns trigger
  language plpgsql
  security definer
  set search_path = public, pg_temp
as $$
begin
  perform public.anonymise_terms_acceptances(old.id);
  return old;
end;
$$;

revoke execute on function public.auth_user_deleted_anonymise_terms() from public, anon, authenticated, service_role;

drop trigger if exists on_auth_user_deleted_anonymise_terms on auth.users;
create trigger on_auth_user_deleted_anonymise_terms
  after delete on auth.users
  for each row execute function public.auth_user_deleted_anonymise_terms();

-- ============================================================================
-- 8. Columns
-- ============================================================================
-- purchases: all nullable — historic rows predate consent (AC4.5, AC7.1).
alter table public.purchases
  add column if not exists terms_version             text,
  add column if not exists withdrawal_waiver_version text,
  add column if not exists withdrawal_waiver_at      timestamptz,
  add column if not exists tax_amount_cents          integer,
  add column if not exists writer                    text
    constraint purchases_writer_check check (writer in ('rn_webhook', 'n8n'));

comment on column public.purchases.writer is
  'GET-470: which writer inserted the row (rn_webhook | n8n); null = written before GET-470.';

-- The RN webhook's idempotency marker (feature §3.5 (2)). Overlaps GET-459's
-- purchases_rn_session_uidx (stripe_blob IS NULL, 20261123130000), which already makes a second
-- RN row a 23505; this one keys on the explicit marker instead of the absence of stripe_blob.
-- No row carries writer yet, so the build can't hit an existing duplicate.
create unique index if not exists purchases_rn_session_once
  on public.purchases (stripe_session_id)
  where writer = 'rn_webhook';

-- creator_subscriptions: written by the RN webhook's own upsert on (creator_id, subscriber_id).
alter table public.creator_subscriptions
  add column if not exists terms_version             text,
  add column if not exists withdrawal_waiver_version text,
  add column if not exists withdrawal_waiver_at      timestamptz;

-- inquiry_proposals: the Insyter Agreement version the proposal was made under (AC5.1).
alter table public.inquiry_proposals
  add column if not exists agreement_version text;

-- agreement_notices: keyed by document type too, so privacy notices can't collide with
-- Insyter v1.0. agreement_notices_pkey = the inline `primary key (user_id, version)` of
-- 20261111130000_get357_agreement_rollout.sql §3.
alter table public.agreement_notices
  add column if not exists document_type text not null default 'insyter_agreement'
    constraint agreement_notices_document_type_check
      check (document_type in ('buyer_terms', 'insyter_agreement', 'privacy', 'withdrawal_waiver'));

alter table public.agreement_notices
  drop constraint agreement_notices_pkey;
alter table public.agreement_notices
  add constraint agreement_notices_pkey primary key (user_id, document_type, version);

-- ============================================================================
-- 9. agreement_notices RPCs, in the same migration as the PK change
-- ============================================================================
-- Otherwise the live sweep hits 42P10 on `on conflict (user_id, version)`. p_document_type is
-- LAST with a default, so today's agreement-notify.ts named calls keep resolving until P4.
-- Bodies = 20261111130000_get357_agreement_rollout.sql §4 + the type.
drop function if exists public.agreement_notices_claim(text, uuid[]);
drop function if exists public.agreement_notices_record(uuid, text, text, text);

create function public.agreement_notices_claim(
  p_version       text,
  p_user_ids      uuid[],
  p_document_type text default 'insyter_agreement'
)
  returns setof uuid
  language sql
  security definer
  set search_path = public
as $$
  insert into public.agreement_notices (user_id, document_type, version, status)
  select distinct ids.id, coalesce(p_document_type, 'insyter_agreement'), p_version, 'sending'
    from unnest(p_user_ids) as ids(id)
   where ids.id is not null
     and exists (select 1 from auth.users au where au.id = ids.id)
  on conflict (user_id, document_type, version) do update
     set status = 'sending',
         updated_at = now()
   where agreement_notices.status in ('held', 'failed')
      or (agreement_notices.status = 'sending'
          and agreement_notices.updated_at < now() - interval '15 minutes')
  returning user_id;
$$;

create function public.agreement_notices_record(
  p_user_id       uuid,
  p_version       text,
  p_status        text,
  p_error         text,
  p_document_type text default 'insyter_agreement'
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
     and version = p_version
     and document_type = coalesce(p_document_type, 'insyter_agreement');
end;
$$;

revoke all on function
  public.agreement_notices_claim(text, uuid[], text),
  public.agreement_notices_record(uuid, text, text, text, text)
  from public, anon, authenticated;
grant execute on function
  public.agreement_notices_claim(text, uuid[], text),
  public.agreement_notices_record(uuid, text, text, text, text)
  to service_role;

-- ============================================================================
-- 10. Purchase stamps — extend the existing GET-332 trigger, don't add a second one
-- ============================================================================
-- Two writers insert a purchases row per checkout (RN webhook + n8n), in either order, and
-- the RN webhook writes the ledger rows. So the stamp lives in the DB:
--   * BEFORE INSERT on purchases (this function) copies the stamps from ledger rows already
--     there (context 'checkout', reference_id = stripe_session_id);
--   * AFTER INSERT on terms_acceptances (below) back-fills purchases rows already there.
-- Both take the same per-session advisory lock, so two concurrent transactions can't each
-- miss the other's uncommitted row (READ COMMITTED takes a fresh snapshot per statement,
-- after the lock is granted).
--
-- The GET-332 body (20261017120000_get332_sales_anonymity.sql §1) is kept VERBATIM above the
-- GET-470 block, and so are its execute revokes.
create or replace function public.purchases_before_insert_stamp()
  returns trigger
  language plpgsql
  security definer
  set search_path = public
as $$
declare
  v_terms   text;
  v_waiver  text;
  v_waiv_at timestamptz;
begin
  new.is_anonymous := coalesce(new.is_anonymous, false)
    or public.purchases_is_anonymous(
         new.insyt_id,
         new.buyer_email,
         -- n8n's rows carry the checkout's metadata in stripe_blob (= event.data).
         new.stripe_blob -> 'object' -> 'metadata' ->> 'buyer_auth_user_id'
       )
    -- The other writer's row for the same checkout already said so.
    or (coalesce(new.stripe_session_id, '') <> '' and exists (
         select 1 from public.purchases t
          where t.stripe_session_id = new.stripe_session_id and t.is_anonymous
       ));
  -- …and the other way round: the twin written first must not stay readable.
  if new.is_anonymous and coalesce(new.stripe_session_id, '') <> '' then
    update public.purchases
       set is_anonymous = true
     where stripe_session_id = new.stripe_session_id
       and not is_anonymous;
  end if;
  -- Revenue is keyed on creator_email; a row without it is invisible to its
  -- creator (the RN webhook used to leave it blank).
  if coalesce(new.creator_email, '') = '' then
    new.creator_email := (
      select i.creator_email from public.insyts i
       where i.insyt_id = new.insyt_id and coalesce(i.creator_email, '') <> ''
       limit 1
    );
  end if;

  -- GET-470 (AC4.5): the consent stamps from this checkout's ledger rows. Never overwrites a
  -- value the writer set itself.
  if coalesce(new.stripe_session_id, '') <> '' then
    perform pg_advisory_xact_lock(hashtext('get470:purchase-stamp:' || new.stripe_session_id));
    if new.terms_version is null then
      select t.version into v_terms
        from public.terms_acceptances t
       where t.context = 'checkout'
         and t.reference_id = new.stripe_session_id
         and t.document_type = 'buyer_terms'
       order by t.recorded_at
       limit 1;
      new.terms_version := v_terms;
    end if;
    if new.withdrawal_waiver_version is null then
      select t.version, t.accepted_at into v_waiver, v_waiv_at
        from public.terms_acceptances t
       where t.context = 'checkout'
         and t.reference_id = new.stripe_session_id
         and t.document_type = 'withdrawal_waiver'
       order by t.recorded_at
       limit 1;
      if v_waiver is not null then
        new.withdrawal_waiver_version := v_waiver;
        new.withdrawal_waiver_at := coalesce(new.withdrawal_waiver_at, v_waiv_at);
      end if;
    end if;
  end if;
  return new;
end;
$$;

revoke execute on function public.purchases_before_insert_stamp() from public, anon, authenticated, service_role;
-- The trigger itself (purchases_before_insert_stamp BEFORE INSERT, GET-332) is unchanged.

create or replace function public.terms_acceptances_stamp_purchases()
  returns trigger
  language plpgsql
  security definer
  set search_path = public, pg_temp
as $$
begin
  perform pg_advisory_xact_lock(hashtext('get470:purchase-stamp:' || new.reference_id));
  if new.document_type = 'buyer_terms' then
    update public.purchases
       set terms_version = new.version
     where stripe_session_id = new.reference_id
       and terms_version is null;
  elsif new.document_type = 'withdrawal_waiver' then
    update public.purchases
       set withdrawal_waiver_version = new.version,
           withdrawal_waiver_at = coalesce(withdrawal_waiver_at, new.accepted_at)
     where stripe_session_id = new.reference_id
       and withdrawal_waiver_version is null;
  end if;
  return null;
end;
$$;

revoke execute on function public.terms_acceptances_stamp_purchases() from public, anon, authenticated, service_role;

drop trigger if exists terms_acceptances_stamp_purchases on public.terms_acceptances;
create trigger terms_acceptances_stamp_purchases
  after insert on public.terms_acceptances
  for each row
  when (new.context = 'checkout' and new.reference_id is not null)
  execute function public.terms_acceptances_stamp_purchases();

-- ============================================================================
-- 11. submit_inquiry_proposal: + p_ip, p_user_agent, p_agreement_version (S5, D-8)
-- ============================================================================
-- Latest body = 20261108120000_get375_inquiries_round2.sql §5, unchanged except the GET-470
-- lines: it stamps agreement_version with the current insyter_agreement version and inserts
-- the `proposal` ledger row (reference = proposal id, email from auth.users) in the same
-- transaction. A p_agreement_version that isn't the current version raises 'terms_changed'
-- (P0001) instead of stamping the newer one (AC2.3, D-8).
-- Transition: p_agreement_version null (today's server, which doesn't send it yet) skips that
-- comparison and stamps the current version; the P4 server always sends it. Only the service
-- role can call this function.
-- A signature change means drop + recreate + re-apply the service_role-only grant (GET-318/375).
drop function if exists public.submit_inquiry_proposal(uuid, uuid, text, text, integer, integer, date, integer, uuid);

create function public.submit_inquiry_proposal(
  p_inquiry_id        uuid,
  p_insyter           uuid,
  p_abstract          text,
  p_outline_html      text,
  p_read_time_min     integer,
  p_price_cents       integer,
  p_deliver_by        date,
  p_daily_cap         integer,
  p_attached_insyt_id uuid default null,
  p_ip                text default null,
  p_user_agent        text default null,
  p_agreement_version text default null
)
  returns jsonb
  language plpgsql
  security definer
  set search_path = public
as $$
declare
  inq       public.inquiries%rowtype;
  prop      public.inquiry_proposals%rowtype;
  v_filled  integer;
  v_mine    integer;
  v_recent  integer;
  v_agree   text;
begin
  if p_insyter is null then
    return jsonb_build_object('result', 'not_found');
  end if;

  -- Still an Insyter, right now (S8-AC3) — locked FOR SHARE so a concurrent
  -- demotion queues behind this submit (or this submit behind it).
  perform 1 from public.users where auth_user_id = p_insyter and is_creator for share;
  if not found then
    return jsonb_build_object('result', 'not_insyter');
  end if;

  -- GET-470 (AC2.3, D-8): the proposal is made under the agreement the form displayed.
  select av.version::text into v_agree
    from public.agreement_versions av
   where av.document_type = 'insyter_agreement'
     and av.is_current;
  if p_agreement_version is not null and p_agreement_version is distinct from v_agree then
    raise exception 'terms_changed'
      using errcode = 'P0001',
            detail = format('insyter_agreement %s is not the current version (%s)', p_agreement_version, v_agree);
  end if;

  select * into inq from public.inquiries where id = p_inquiry_id for update;
  if not found then
    return jsonb_build_object('result', 'not_found');
  end if;
  if inq.requester_auth_user_id = p_insyter then
    return jsonb_build_object('result', 'own');
  end if;

  -- Audience: a targeted inquiry is invisible to non-targets (S3-AC2).
  if inq.audience = 'specific' and not exists (
    select 1 from public.inquiry_targets
     where inquiry_id = inq.id and creator_auth_user_id = p_insyter
  ) then
    return jsonb_build_object('result', 'not_found');
  end if;

  -- E1 — open / in progress, not expired, filled < N (S8-AC1/2).
  select count(*) into v_filled
    from public.inquiry_proposals
   where inquiry_id = inq.id and status in ('accepted', 'delivering', 'delivered');
  if inq.status not in ('open', 'in_progress')
     or (inq.open_until is not null and inq.open_until <= now())
     or v_filled >= inq.insyts_wanted then
    return jsonb_build_object('result', 'not_open');
  end if;

  -- R2-S9 — up to N ACTIVE proposals per Insyter (unlimited N → 100, the
  -- range ceiling). Withdrawn / declined / cancelled ones free their slot.
  -- Counted under the inquiry-row lock taken above, so it's race-safe.
  select count(*) into v_mine
    from public.inquiry_proposals
   where inquiry_id = inq.id
     and insyter_auth_user_id = p_insyter
     and status in ('submitted', 'accepted', 'delivering', 'delivered');
  if v_mine >= coalesce(inq.insyts_wanted, 100) then
    return jsonb_build_object('result', 'insyter_cap');
  end if;

  -- S4-AC6 — the cap, counted under a per-Insyter lock so parallel submits
  -- queue instead of all reading the same count.
  perform pg_advisory_xact_lock(hashtext('inquiry_proposals:' || p_insyter::text));
  select count(*) into v_recent
    from public.inquiry_proposals
   where insyter_auth_user_id = p_insyter
     and created_at > now() - interval '24 hours';
  if v_recent >= p_daily_cap then
    return jsonb_build_object('result', 'cap');
  end if;

  insert into public.inquiry_proposals (
    inquiry_id, insyter_auth_user_id, abstract, outline_html,
    read_time_min, price_cents, deliver_by, terms_accepted_at, attached_insyt_id,
    agreement_version
  ) values (
    inq.id, p_insyter, p_abstract, p_outline_html,
    p_read_time_min, p_price_cents, p_deliver_by, now(), p_attached_insyt_id,
    v_agree
  )
  returning * into prop;

  -- GET-470 (AC5.2): the proposal ledger row. Skipped only while no Insyter Agreement is
  -- current (null-current rule); p_require_current = false because it was checked above
  -- under the same transaction.
  if v_agree is not null then
    perform public.record_terms_acceptance(
      p_insyter, null, 'insyter_agreement', v_agree, 'proposal', prop.id::text,
      prop.terms_accepted_at, p_ip, p_user_agent, false);
  end if;

  return jsonb_build_object('result', 'ok', 'proposal', to_jsonb(prop));
end;
$$;

revoke execute on function
  public.submit_inquiry_proposal(uuid, uuid, text, text, integer, integer, date, integer, uuid, text, text, text)
  from public, anon, authenticated, service_role;
grant execute on function
  public.submit_inquiry_proposal(uuid, uuid, text, text, integer, integer, date, integer, uuid, text, text, text)
  to service_role;

-- ============================================================================
-- 12. Backfill legacy acceptances → ledger (OQ-2, AC2.6)
-- ============================================================================
-- Every agreement_acceptances row gets a become_insyter twin with signature_name and the
-- pinned registry sha256. agreement_acceptances.ip is free text from the web era: the helper
-- returns null for a malformed value, so one bad row can't abort the migration. 37 rows on
-- prod; a fresh DB has 0. Idempotent (skips rows that already have their twin). The helper is
-- dropped in P7 together with the legacy table.
create or replace function public.get470_safe_inet(p text)
  returns inet
  language plpgsql
  immutable
  set search_path = public, pg_temp
as $$
begin
  return nullif(btrim(p), '')::inet;
exception when others then
  return null;
end;
$$;

revoke execute on function public.get470_safe_inet(text) from public, anon, authenticated;

insert into public.terms_acceptances (
  auth_user_id, email, signature_name, document_type, version, sha256, context,
  reference_id, accepted_at, ip, user_agent
)
select a.auth_user_id, a.email, a.signature_name, 'insyter_agreement', a.version, av.sha256,
       'become_insyter', null, a.accepted_at, public.get470_safe_inet(a.ip), null
  from public.agreement_acceptances a
  join public.agreement_versions av
    on av.document_type = 'insyter_agreement' and av.version = a.version
 where not exists (
   select 1 from public.terms_acceptances t
    where t.auth_user_id = a.auth_user_id
      and t.document_type = 'insyter_agreement'
      and t.version = a.version
      and t.accepted_at = a.accepted_at
 );

do $$
declare
  missing integer;
begin
  select count(*) into missing
    from public.agreement_acceptances a
   where not exists (
     select 1 from public.terms_acceptances t
      where t.auth_user_id = a.auth_user_id
        and t.document_type = 'insyter_agreement'
        and t.version = a.version
        and t.accepted_at = a.accepted_at
   );
  if missing > 0 then
    raise exception 'GET-470: % agreement_acceptances rows have no ledger twin after the backfill (version not in the registry as insyter_agreement?)', missing;
  end if;
end;
$$;

-- ============================================================================
-- 13. Storage: bucket legal-documents (AC1.8)
-- ============================================================================
-- Public read; NO insert/update/delete policies, so only the service role writes
-- (legal-publish.ts, upsert:false). Path: <document_type>/<version>.html. Insyter Agreement
-- v1.0 stays at creator-agreements/terms/creator-agreement-v1.0.html (past acceptances point
-- there). Pattern: 20260519082723_create_creator_agreements_bucket.sql.
insert into storage.buckets (id, name, public)
values ('legal-documents', 'legal-documents', true)
on conflict (id) do nothing;

drop policy if exists "legal-documents public read" on storage.objects;
create policy "legal-documents public read"
  on storage.objects for select
  using (bucket_id = 'legal-documents');

commit;
