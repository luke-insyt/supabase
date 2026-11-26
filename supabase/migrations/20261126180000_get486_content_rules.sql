-- GET-486 B2 (S3) — Content & Image Rules in the registry, the per-Insyt rules confirmations,
-- and the order-proof account-deletion follow-up trigger.
--
-- Design: webflow-app-documentation/features/legal-follow-up/feature.md §2.3, §2.4, §2.7, §3.1
-- Plan:   webflow-app-documentation/features/legal-follow-up/implementation.md B2 item 1, D-3, D-9
-- Tests:  supabase/tests/get486_content_rules_test.ts (PGlite, offline, runs this file)
--         supabase/tests/legal_rules_test.py (PostgREST, staging, after the merge applies this)
--         supabase/tests/sql/legal_destructive.sql (psql, branch/local DB only)
--
-- NULL-CURRENT SAFE: nothing here makes a content_rules version current. Until
-- prod-ops/legal-make-current.sql does (AFTER the app with the panel is deployed),
-- rules_confirmation_needed() returns false and the edge fns don't gate anything.
--
-- Which id (feature §2.4): confirmations are keyed on insyts.correlation_id, which exists before
-- the row (public submit; n8n creates the row with it). Legacy rows without a correlation_id
-- (web-era Insyts) are keyed on their row id instead: the key is always
-- coalesce(insyts.correlation_id, insyts.id), and insyt_row_id is matched as well.
--
-- One transaction: a failure leaves the schema as it was.

begin;

-- ============================================================================
-- 1. content_rules in the registry (feature §2.3)
-- ============================================================================
-- agreement_versions_document_type_check: 20261125121000_get470_registry_columns.sql.
-- agreement_notices_document_type_check stays: no notice is ever sent for the rules.
alter table public.agreement_versions
  drop constraint agreement_versions_document_type_check;
alter table public.agreement_versions
  add constraint agreement_versions_document_type_check
    check (document_type in ('buyer_terms', 'content_rules', 'insyter_agreement', 'privacy', 'withdrawal_waiver'));

comment on column public.agreement_versions.display_text is
  'GET-470: inline sentence shown with a withdrawal_waiver version (checkout pre-step + Stripe custom_text). '
  'GET-486: the "In short" paragraph of a content_rules version (always-visible panel header).';

-- ============================================================================
-- 2. insyts.content_rev (feature §2.4)
-- ============================================================================
-- Bumped by submit-create-insyt persistEditAndRepublish when an edit changes content fields
-- (title, abstract, body, cover, attachments). Price-, tag- and taxonomy-only edits don't bump
-- it. n8n never writes it. Only the edge fns (service role) use it. On staging (checked
-- 2026-11-26) anon/authenticated read insyts through COLUMN grants, so a new column isn't
-- readable by them; their table-level UPDATE has no RLS policy, so it can't be written either.
-- The revoke below states the intent explicitly for a fresh DB.
alter table public.insyts
  add column if not exists content_rev integer not null default 0;

comment on column public.insyts.content_rev is
  'GET-486: content revision, +1 per content edit. A rules confirmation covers one revision.';

revoke select (content_rev), insert (content_rev), update (content_rev)
  on public.insyts from anon, authenticated;

-- ============================================================================
-- 3. insyt_rules_confirmations — append-only (AC3.4, AC3.9)
-- ============================================================================
create table if not exists public.insyt_rules_confirmations (
  id             uuid primary key default gen_random_uuid(),
  correlation_id uuid not null,                 -- coalesce(insyts.correlation_id, insyts.id)
  insyt_row_id   uuid,                          -- insyts.id when known; no FK, rows outlive the Insyt
  auth_user_id   uuid not null,                 -- from the JWT; no FK, kept raw on deletion (GET-470 OQ-8)
  document_type  text not null default 'content_rules'
                 constraint insyt_rules_confirmations_type_check check (document_type = 'content_rules'),
  rules_version  text not null,
  ticks          text[] not null,               -- exactly content_rules_tick_ids(), sorted
  context        text not null
                 constraint insyt_rules_confirmations_context_check
                   check (context in ('publish', 'delivery', 'update_published', 'unhide')),
  content_rev    integer not null,              -- the insyts.content_rev this confirmation covers
  confirmed_at   timestamptz not null default now(),  -- server time, never client-supplied
  ip             inet,
  user_agent     text,
  anonymised_at  timestamptz,
  constraint insyt_rules_confirmations_version_fkey
    foreign key (document_type, rules_version) references public.agreement_versions (document_type, version)
);

comment on table public.insyt_rules_confirmations is
  'GET-486: append-only record that an Insyter ticked the five Content & Image Rules for an Insyt '
  '(publish, delivery, content edit, unhide). Written only through record_rules_confirmation '
  '(service role). The only allowed update is the anonymise path on account deletion.';

create index if not exists insyt_rules_confirmations_key_idx
  on public.insyt_rules_confirmations (correlation_id, auth_user_id, confirmed_at desc);
create index if not exists insyt_rules_confirmations_row_idx
  on public.insyt_rules_confirmations (insyt_row_id, auth_user_id, confirmed_at desc)
  where insyt_row_id is not null;
create index if not exists insyt_rules_confirmations_user_idx
  on public.insyt_rules_confirmations (auth_user_id);

alter table public.insyt_rules_confirmations enable row level security;

drop policy if exists insyt_rules_confirmations_select_own on public.insyt_rules_confirmations;
create policy insyt_rules_confirmations_select_own on public.insyt_rules_confirmations
  for select
  to authenticated
  using (auth_user_id = auth.uid());

-- Supabase's default privileges grant ALL on a new public table to the API roles.
revoke all on public.insyt_rules_confirmations from anon, authenticated;
grant select on public.insyt_rules_confirmations to authenticated;
grant all on public.insyt_rules_confirmations to service_role;

-- Append-only, even for the service role (the ledger's rule, GET-470 §2.4). The ONE allowed
-- update: ip / user_agent → null and anonymised_at set, nothing else, once.
create or replace function public.insyt_rules_confirmations_append_only()
  returns trigger
  language plpgsql
  set search_path = public, pg_temp
as $$
declare
  pii constant text[] := array['ip', 'user_agent', 'anonymised_at'];
begin
  if tg_op in ('DELETE', 'TRUNCATE') then
    raise exception 'insyt_rules_confirmations is append-only: rows can never be deleted (GET-486 AC3.4)'
      using errcode = 'P0001';
  end if;
  if old.anonymised_at is null
     and new.anonymised_at is not null
     and new.ip is null
     and new.user_agent is null
     and (to_jsonb(new) - pii) = (to_jsonb(old) - pii) then
    return new;
  end if;
  raise exception 'insyt_rules_confirmations is append-only: the only allowed update is anonymisation (GET-486 AC3.4, AC3.9)'
    using errcode = 'P0001';
end;
$$;

revoke execute on function public.insyt_rules_confirmations_append_only() from public, anon, authenticated, service_role;

drop trigger if exists insyt_rules_confirmations_append_only_update on public.insyt_rules_confirmations;
create trigger insyt_rules_confirmations_append_only_update
  before update on public.insyt_rules_confirmations
  for each row execute function public.insyt_rules_confirmations_append_only();

drop trigger if exists insyt_rules_confirmations_no_delete on public.insyt_rules_confirmations;
create trigger insyt_rules_confirmations_no_delete
  before delete on public.insyt_rules_confirmations
  for each row execute function public.insyt_rules_confirmations_append_only();

drop trigger if exists insyt_rules_confirmations_no_truncate on public.insyt_rules_confirmations;
create trigger insyt_rules_confirmations_no_truncate
  before truncate on public.insyt_rules_confirmations
  for each statement execute function public.insyt_rules_confirmations_append_only();

-- ============================================================================
-- 4. The five tick ids (D-3: a code constant tied to content_rules v1.0)
-- ============================================================================
-- Mirrored by RULE_TICKS in getinsyts-native/app/src/lib/content-rules.ts and RULE_TICK_IDS in
-- functions/submit-create-insyt/rules.ts; a test on each side pins the literal. A future §4
-- change needs a code release (new migration + app + edge fn), not just a new rules version.
create or replace function public.content_rules_tick_ids()
  returns text[]
  language sql
  immutable
  set search_path = public, pg_temp
as $$
  select array['images_licensed', 'minors_initials', 'no_confidential', 'opinions', 'own_work']::text[];
$$;

-- ============================================================================
-- 5. RPCs (service_role only — grant block at the end)
-- ============================================================================

-- The owner of an insyts row: creator_auth_user_id, or (legacy rows without it) the auth user
-- whose email is creator_email. Internal helper.
create or replace function public.get486_insyt_owner(p_row_id uuid)
  returns uuid
  language sql
  stable
  security definer
  set search_path = public, pg_temp
as $$
  select coalesce(
           i.creator_auth_user_id,
           (select au.id from auth.users au
             where lower(au.email::text) = lower(i.creator_email::text)
             order by au.created_at
             limit 1))
    from public.insyts i
   where i.id = p_row_id;
$$;

-- One confirmation row. auth_user_id = p_user (the edge fn passes the verified JWT subject);
-- confirmed_at = now().
--   p_row_id set   → the row must exist and belong to p_user; the key is the row's own
--                    coalesce(correlation_id, id) (p_correlation is ignored).
--   p_row_id null  → first public submit: p_correlation is the key; any insyts row that
--                    already carries it (a draft) must belong to p_user.
-- Raises (P0001): 'rules_not_live' (no current content_rules), 'rules_changed' (p_version
-- isn't current; detail = current version), 'rules_ticks_invalid' (ticks ≠ the five ids),
-- 'not_owner', 'insyt_not_found', 'rules_context_invalid'.
-- p_ip is cast leniently (a malformed value is stored as null).
create or replace function public.record_rules_confirmation(
  p_user        uuid,
  p_correlation uuid,
  p_row_id      uuid,
  p_version     text,
  p_ticks       text[],
  p_context     text,
  p_rev         integer,
  p_ip          text default null,
  p_ua          text default null
)
  returns uuid
  language plpgsql
  volatile
  security definer
  set search_path = public, pg_temp
as $$
declare
  v_current text;
  v_ticks   text[];
  v_key     uuid;
  v_ip      inet;
  v_id      uuid;
  v_found   boolean;
  v_rowcorr uuid;
begin
  if p_user is null then
    raise exception 'record_rules_confirmation: p_user is required' using errcode = '22004';
  end if;
  if p_context is null or p_context not in ('publish', 'delivery', 'update_published', 'unhide') then
    raise exception 'rules_context_invalid' using errcode = 'P0001';
  end if;

  select av.version::text into v_current
    from public.agreement_versions av
   where av.document_type = 'content_rules'
     and av.is_current;
  if v_current is null then
    raise exception 'rules_not_live' using errcode = 'P0001';
  end if;
  if p_version is distinct from v_current then
    raise exception 'rules_changed'
      using errcode = 'P0001', detail = v_current;
  end if;

  select coalesce(array_agg(t order by t), '{}') into v_ticks
    from (select distinct unnest(coalesce(p_ticks, '{}'::text[])) t) s;
  if v_ticks is distinct from public.content_rules_tick_ids()
     or coalesce(array_length(p_ticks, 1), 0) <> array_length(public.content_rules_tick_ids(), 1) then
    raise exception 'rules_ticks_invalid' using errcode = 'P0001';
  end if;

  if p_row_id is not null then
    select true, i.correlation_id into v_found, v_rowcorr
      from public.insyts i
     where i.id = p_row_id;
    if not coalesce(v_found, false) then
      raise exception 'insyt_not_found' using errcode = 'P0001';
    end if;
    if public.get486_insyt_owner(p_row_id) is distinct from p_user then
      raise exception 'not_owner' using errcode = 'P0001';
    end if;
    v_key := coalesce(v_rowcorr, p_row_id);
  else
    if p_correlation is null then
      raise exception 'record_rules_confirmation: p_correlation or p_row_id is required' using errcode = '22004';
    end if;
    if exists (
      select 1 from public.insyts i
       where i.correlation_id = p_correlation
         and public.get486_insyt_owner(i.id) is distinct from p_user
    ) then
      raise exception 'not_owner' using errcode = 'P0001';
    end if;
    v_key := p_correlation;
  end if;

  begin
    v_ip := nullif(btrim(p_ip), '')::inet;
  exception when others then
    v_ip := null;
  end;

  insert into public.insyt_rules_confirmations (
    correlation_id, insyt_row_id, auth_user_id, document_type, rules_version, ticks, context,
    content_rev, ip, user_agent
  ) values (
    v_key, p_row_id, p_user, 'content_rules', v_current, v_ticks, p_context,
    coalesce(p_rev, 0), v_ip, nullif(left(p_ua, 1000), '')
  )
  returning id into v_id;

  return v_id;
end;
$$;

-- Does unhiding this row need a fresh confirmation (AC3.5)? false while no content_rules
-- version is current (null-current safe). Otherwise true unless the latest confirmation BY THE
-- OWNER for this Insyt covers the row's current content_rev under the current rules version.
-- Filtering on the owner means a stranger's row can never count. An unknown row → false (the
-- caller has already 404'd it).
create or replace function public.rules_confirmation_needed(p_row_id uuid)
  returns boolean
  language plpgsql
  stable
  security definer
  set search_path = public, pg_temp
as $$
declare
  v_current text;
  v_rev     integer;
  v_corr    uuid;
  v_owner   uuid;
  v_latest  record;
begin
  select av.version::text into v_current
    from public.agreement_versions av
   where av.document_type = 'content_rules'
     and av.is_current;
  if v_current is null then
    return false;
  end if;

  select i.content_rev, coalesce(i.correlation_id, i.id) into v_rev, v_corr
    from public.insyts i
   where i.id = p_row_id;
  if not found then
    return false;
  end if;
  v_owner := public.get486_insyt_owner(p_row_id);

  select c.content_rev, c.rules_version into v_latest
    from public.insyt_rules_confirmations c
   where c.auth_user_id = v_owner
     and (c.correlation_id = v_corr or c.insyt_row_id = p_row_id)
   order by c.confirmed_at desc, c.content_rev desc
   limit 1;
  if not found then
    return true;
  end if;
  return not (v_latest.content_rev = v_rev and v_latest.rules_version = v_current);
end;
$$;

-- Postgres grants EXECUTE to PUBLIC by default and Supabase grants anon/authenticated directly.
-- Without this any signed-in user could forge confirmations.
revoke all on function
  public.content_rules_tick_ids(),
  public.get486_insyt_owner(uuid),
  public.record_rules_confirmation(uuid, uuid, uuid, text, text[], text, integer, text, text),
  public.rules_confirmation_needed(uuid)
  from public, anon, authenticated;
grant execute on function
  public.content_rules_tick_ids(),
  public.get486_insyt_owner(uuid),
  public.record_rules_confirmation(uuid, uuid, uuid, text, text[], text, integer, text, text),
  public.rules_confirmation_needed(uuid)
  to service_role;

-- ============================================================================
-- 6. Account deletion follow-up (feature §2.7, AC3.9, AC4.10) — D-9 order-proof body
-- ============================================================================
-- B2 (this file) and B4 (20261126170000_get486_insyt_reports.sql) write the SAME full body and
-- the same trigger name (on_auth_user_deleted_anonymise_followup); each table's block runs only
-- when that table exists. plpgsql prepares a statement only when it is reached, so the
-- reference to a not-yet-created table never breaks a delete, and B2/B4 can merge in either
-- order. Every update filters on "not yet anonymised", so it never trips an append-only
-- trigger (which would roll back the user delete itself).
create or replace function public.auth_user_deleted_anonymise_followup()
  returns trigger
  language plpgsql
  security definer
  set search_path = public, pg_temp
as $$
begin
  -- GET-486 S3 (AC3.9): rules confirmations keep auth_user_id, lose IP/UA.
  if to_regclass('public.insyt_rules_confirmations') is not null then
    update public.insyt_rules_confirmations
       set ip = null,
           user_agent = null,
           anonymised_at = now()
     where auth_user_id = old.id
       and anonymised_at is null;
  end if;

  -- GET-486 S4 (AC4.10): a deleted reporter's reports stay, with the deleted-user marker;
  -- id, email and IP are nulled, the note (the content of the notice) stays.
  if to_regclass('public.insyt_reports') is not null then
    update public.insyt_reports
       set reporter_auth_user_id = null,
           reporter_email = null,
           reporter_ip = null,
           reporter_deleted_at = now()
     where reporter_auth_user_id = old.id
       and reporter_deleted_at is null;
  end if;

  return old;
end;
$$;

revoke execute on function public.auth_user_deleted_anonymise_followup() from public, anon, authenticated, service_role;

drop trigger if exists on_auth_user_deleted_anonymise_followup on auth.users;
create trigger on_auth_user_deleted_anonymise_followup
  after delete on auth.users
  for each row execute function public.auth_user_deleted_anonymise_followup();

commit;
