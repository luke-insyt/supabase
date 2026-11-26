-- GET-470 P2 — destructive DB checks that can't go through PostgREST (AC1.4, AC2.2, AC8.1–8.3).
--
-- psql ONLY, against a Supabase BRANCH or a local DB, never live staging/prod. Everything runs
-- in one transaction that is rolled back at the end, but it still inserts registry rows,
-- creates/deletes an auth user and exercises triggers — so it refuses the two live projects:
--   psql "$BRANCH_DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/sql/legal_destructive.sql
-- GET-486 A1 (= GET-470 P7) dropped the legacy table; re-run after that migration (AC2.5): the
-- user-delete block must still pass with the ledger as the only acceptance record.
--
-- The same cases run offline on PGlite in supabase/tests/get470_legal_registry_test.ts.

-- ---------------------------------------------------------------- refuse live projects
-- Direct host db.<ref>.supabase.co or pooler user postgres.<ref>: both carry the project ref.
select (:'HOST' || ' ' || :'USER') ~ '(xeqjairmlwnjtmselyvo|krapqgxrqprtajatxjzd)' as gi_live_db \gset
\if :gi_live_db
  \echo 'REFUSED: legal_destructive.sql must not run against the staging or prod project. Use a Supabase branch or local DB.'
  \quit
\endif

begin;

do $$
declare
  u        uuid := gen_random_uuid();
  keep     uuid := gen_random_uuid();
  sha_b    text := repeat('b', 64);
  raised   boolean;
  r        record;
begin
  -- fixtures (rolled back) -----------------------------------------------------
  insert into auth.users (id, email, aud, role) values
    (u,    'get470-destructive-gone@getinsyts.test', 'authenticated', 'authenticated'),
    (keep, 'get470-destructive-keep@getinsyts.test', 'authenticated', 'authenticated');
  insert into public.agreement_versions (document_type, version, title, url, effective_date, is_current, sha256)
  values ('privacy', 'vtest-destructive', 'Privacy test', 'https://example.test/p.html', current_date, false, sha_b);

  -- AC1.4: registry update of a frozen column raises (incl. as service role) -----
  set local role service_role;
  begin
    update public.agreement_versions set title = 'changed' where version = 'vtest-destructive';
    raised := false;
  exception when others then raised := true;
  end;
  if not raised then raise exception 'FAIL (AC1.4): registry title update as service_role did not raise'; end if;

  begin
    delete from public.agreement_versions where version = 'vtest-destructive';
    raised := false;
  exception when others then raised := true;
  end;
  if not raised then raise exception 'FAIL (AC1.4): registry delete as service_role did not raise'; end if;
  reset role;

  begin
    delete from public.agreement_versions where document_type = 'insyter_agreement' and version = 'v1.0';
    raised := false;
  exception when others then raised := true;
  end;
  if not raised then raise exception 'FAIL (AC1.4): delete of insyter_agreement v1.0 did not raise'; end if;
  raise notice 'PASS (AC1.4): registry update/delete refused';

  -- ledger rows (insyter acceptance for u, privacy for keep) ------------------------
  perform public.record_insyter_acceptance(u, null, 'Gone Tester', (select version from public.agreement_versions
                                            where document_type = 'insyter_agreement' and is_current), '203.0.113.1', 'UA');
  perform public.record_terms_acceptance(keep, null, 'privacy', 'vtest-destructive', 'fixture', null, null, '203.0.113.2', 'UA', false);

  -- AC2.2: truncate / delete / non-anonymise update refused ------------------------
  begin
    truncate public.terms_acceptances;
    raised := false;
  exception when others then raised := true;
  end;
  if not raised then raise exception 'FAIL (AC2.2): truncate terms_acceptances did not raise'; end if;

  begin
    delete from public.terms_acceptances where auth_user_id = keep;
    raised := false;
  exception when others then raised := true;
  end;
  if not raised then raise exception 'FAIL (AC2.2): delete from terms_acceptances did not raise'; end if;

  begin
    update public.terms_acceptances set version = 'v0' where auth_user_id = keep;
    raised := false;
  exception when others then raised := true;
  end;
  if not raised then raise exception 'FAIL (AC2.2): ledger version update did not raise'; end if;
  raise notice 'PASS (AC2.2): ledger truncate/delete/update refused';

  -- AC8.1–8.2, GET-486 AC2.5: deleting a user with ledger rows succeeds and anonymises them --
  delete from auth.users where id = u;

  for r in select * from public.terms_acceptances where auth_user_id = u loop
    if r.email is not null or r.signature_name is not null or r.ip is not null
       or r.user_agent is not null or r.anonymised_at is null then
      raise exception 'FAIL (AC8.1/8.2): ledger row % not anonymised', r.id;
    end if;
  end loop;
  if not found then raise exception 'FAIL (AC8.2): ledger row of the deleted user vanished (must be kept)'; end if;

  if (select email from public.terms_acceptances where auth_user_id = keep) is null then
    raise exception 'FAIL: another user''s ledger row was anonymised';
  end if;
  raise notice 'PASS (AC8.1–8.2, AC2.5): user delete succeeded, ledger anonymised';
end;
$$;

-- ---------------------------------------------------------------- GET-486 B3 (AC5.4, AC5.8)
-- insyter_deductions: delete / truncate / non-settle update refused (also as service_role), and
-- deleting an Insyter with deduction rows succeeds and leaves them unchanged (no FK to users).
-- Skipped until 20261126160000_get486_insyter_deductions.sql is applied on the branch.
do $$
declare
  u      uuid := gen_random_uuid();
  d      uuid;
  raised boolean;
  before jsonb;
begin
  if to_regclass('public.insyter_deductions') is null then
    raise notice 'SKIP (GET-486 B3): insyter_deductions not present';
    return;
  end if;
  insert into auth.users (id, email, aud, role) values
    (u, 'get486-destructive-insyter@getinsyts.test', 'authenticated', 'authenticated');
  if not exists (select 1 from public.users where auth_user_id = u) then
    insert into public.users (auth_user_id, email) values (u, 'get486-destructive-insyter@getinsyts.test');
  end if;
  d := public.record_insyter_deduction(u, u, 'hold', 500, null, null, null, 'destructive test', null, null);
  select to_jsonb(x) into before from public.insyter_deductions x where x.id = d;

  set local role service_role;
  begin
    delete from public.insyter_deductions where id = d;
    raised := false;
  exception when others then raised := true;
  end;
  if not raised then raise exception 'FAIL (AC5.4): delete from insyter_deductions as service_role did not raise'; end if;
  reset role;

  begin
    delete from public.insyter_deductions where id = d;
    raised := false;
  exception when others then raised := true;
  end;
  if not raised then raise exception 'FAIL (AC5.4): delete from insyter_deductions did not raise'; end if;

  begin
    truncate public.insyter_deductions;
    raised := false;
  exception when others then raised := true;
  end;
  if not raised then raise exception 'FAIL (AC5.4): truncate insyter_deductions did not raise'; end if;

  begin
    update public.insyter_deductions set reason = 'changed' where id = d;
    raised := false;
  exception when others then raised := true;
  end;
  if not raised then raise exception 'FAIL (AC5.4): insyter_deductions reason update did not raise'; end if;
  raise notice 'PASS (AC5.4): deductions delete/truncate/update refused';

  -- AC5.8: the account delete succeeds and the row is kept unchanged.
  delete from public.users where auth_user_id = u;
  delete from auth.users where id = u;
  if (select to_jsonb(x) from public.insyter_deductions x where x.id = d) is distinct from before then
    raise exception 'FAIL (AC5.8): the deduction row changed or vanished on user delete';
  end if;
  raise notice 'PASS (AC5.8): user delete succeeded, deduction row unchanged';
end;
$$;

-- GET-486 B4 (AC4.10, D-9): deleting a reporter keeps the report with the deleted-user marker.
-- Runs whether or not B2's insyt_rules_confirmations exists (the follow-up trigger guards each
-- table with to_regclass); skips with a notice before the B4 migration is on this DB.
do $$
declare
  rep  uuid := gen_random_uuid();
  r    record;
begin
  if to_regclass('public.insyt_reports') is null then
    raise notice 'SKIP (AC4.10): public.insyt_reports not on this DB yet';
    return;
  end if;
  insert into auth.users (id, email, aud, role)
  values (rep, 'get486-reporter-destructive@getinsyts.test', 'authenticated', 'authenticated');
  insert into public.insyt_reports (insyt_id, reporter_auth_user_id, reporter_email, reporter_ip, reason, note)
  values ('get486-destructive', rep, 'get486-reporter-destructive@getinsyts.test', '203.0.113.9', 'copied', 'the notice');

  delete from auth.users where id = rep;

  select * into r from public.insyt_reports where insyt_id = 'get486-destructive';
  if not found then raise exception 'FAIL (AC4.10): the deleted reporter''s report vanished (must be kept)'; end if;
  if r.reporter_auth_user_id is not null or r.reporter_email is not null or r.reporter_ip is not null
     or r.reporter_deleted_at is null then
    raise exception 'FAIL (AC4.10): report % not marked as from a deleted user', r.id;
  end if;
  if r.note is distinct from 'the notice' then raise exception 'FAIL (AC4.10): the note was not kept'; end if;
  raise notice 'PASS (AC4.10, D-9): reporter delete succeeded (confirmations table present: %), report kept with marker',
    to_regclass('public.insyt_rules_confirmations') is not null;
end;
$$;

rollback;
