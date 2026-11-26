-- GET-486 A1 (closes GET-470 P7) — drop the legacy agreement_acceptances table.
--
-- Requirements: webflow-app-documentation/features/legal-follow-up/requirements.md S2 (AC2.2, AC2.3)
-- Design:       webflow-app-documentation/features/legal-follow-up/feature.md §2.1
-- Plan:         webflow-app-documentation/features/legal-follow-up/implementation.md A1
-- Pre-check:    supabase/prod-ops/get486-legacy-precheck.sql (read-only; run on the target
--               project right before this migration, output in the PR)
-- Tests:        supabase/tests/get470_legal_registry_test.ts (PGlite, offline, runs this file)
--
-- From here on terms_acceptances is the ONLY acceptance record.
--
-- DEPLOY ORDER: this migration → `supabase functions deploy accept-agreement`. The deployed
-- edge fn keeps working in between: it only calls record_insyter_acceptance, whose signature
-- doesn't change.
--
-- Everything is in one transaction: a failed guard leaves the schema exactly as it was.

begin;

-- ============================================================================
-- 0. Guard + orphan cleanup
-- ============================================================================
-- Every legacy row must have its ledger twin (AC2.2 rule — the same predicate as the
-- pre-check; keep the two in sync). Any unmatched row aborts: nothing is patched by hand.
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
        and t.version = a.version::text
        and t.accepted_at = a.accepted_at
        and (t.signature_name = a.signature_name
             or (a.signature_name = 'deleted-user'
                 and t.anonymised_at is not null
                 and t.signature_name is null))
   );
  if missing > 0 then
    raise exception 'GET-486: % agreement_acceptances rows have no ledger twin (AC2.2) — run prod-ops/get486-legacy-precheck.sql and escalate; nothing was dropped', missing;
  end if;
end;
$$;

-- Backfilled twins of users deleted BEFORE GET-470: the delete trigger never fired for them,
-- so they still carry email / name / ip. Anonymise them now (this still runs the old body,
-- which also tokenises their legacy rows — harmless, the table goes in step 4).
do $$
declare
  u uuid;
begin
  for u in
    select distinct t.auth_user_id
      from public.terms_acceptances t
     where t.document_type = 'insyter_agreement'
       and t.anonymised_at is null
       and not exists (select 1 from auth.users au where au.id = t.auth_user_id)
  loop
    perform public.anonymise_terms_acceptances(u);
  end loop;
end;
$$;

-- ============================================================================
-- 1. anonymise_terms_acceptances — ledger only
-- ============================================================================
-- Account deletion (GET-470 AC8.1–8.3): ledger rows keep auth_user_id raw but lose email,
-- signature_name, ip, user_agent. Same signature and return value; called by the
-- AFTER DELETE ON auth.users trigger auth_user_deleted_anonymise_terms.
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

  return n;
end;
$$;

-- ============================================================================
-- 2. record_insyter_acceptance — ledger only
-- ============================================================================
-- accept-agreement: one ledger row with signature_name. Context: become_insyter when the user
-- has no insyter_agreement ledger row yet, else reaccept. Raises 'terms_changed' unless
-- p_version is the current insyter_agreement, 'signature_required' without a name. Returns
-- the ledger row id. Same signature as GET-470's dual-write version.
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
    -- Kept on purpose after the legacy NOT NULL column is gone (AC2.3 step 2): an Insyter
    -- acceptance without an email at the time is weak evidence, and every OTP account has one.
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

  insert into public.terms_acceptances (
    auth_user_id, email, signature_name, document_type, version, sha256, context,
    reference_id, accepted_at, ip, user_agent
  ) values (
    p_user, v_email, v_name, 'insyter_agreement', v_current, v_sha, v_context,
    null, now(), v_ip, nullif(left(p_ua, 1000), '')
  )
  returning id into v_id;

  return v_id;
end;
$$;

-- create or replace keeps the grants; re-applied anyway so this file alone states them.
revoke all on function
  public.record_insyter_acceptance(uuid, text, text, text, text, text),
  public.anonymise_terms_acceptances(uuid)
  from public, anon, authenticated;
grant execute on function
  public.record_insyter_acceptance(uuid, text, text, text, text, text),
  public.anonymise_terms_acceptances(uuid)
  to service_role;

-- ============================================================================
-- 3. The backfill helper (only ever used for the legacy ip column)
-- ============================================================================
drop function public.get470_safe_inet(text);

-- ============================================================================
-- 4. The legacy table
-- ============================================================================
-- No cascade: a hidden dependency must fail this migration loudly, not vanish with it.
drop table public.agreement_acceptances;

commit;
