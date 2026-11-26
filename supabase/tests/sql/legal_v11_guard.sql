-- GET-470 P0 — Creator Agreement v1.1 removal: guard dry-run + post-check (AC0.1–AC0.3).
--
-- READ-ONLY (begin … rollback), so it is safe on any project, including the prod dry-run the
-- P0 gate asks for. Run with psql:
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/sql/legal_v11_guard.sql
--
-- Before 20261125120000_get470_drop_agreement_v1_1.sql is applied it answers "would the
-- migration's guard pass here?" (it raises with the same counts the migration would). After it
-- is applied it asserts v1.1 is gone and v1.0 is untouched.
-- GET-486 A1 dropped the legacy acceptance table; v1.1 acceptances are counted in the
-- terms_acceptances ledger (the only acceptance record), which holds every backfilled row.
-- The migration itself (raise with a v1.1 acceptance; delete without) is exercised end-to-end
-- offline in supabase/tests/get470_legal_registry_test.ts ("P0: …").

begin;

do $$
declare
  has_v11   boolean;
  n_accept  integer;
  n_users   integer;
  n_current integer;
  n_v10     integer;
  n_objects integer;
begin
  select exists (select 1 from public.agreement_versions where version = 'v1.1') into has_v11;
  select count(*) into n_accept  from public.terms_acceptances
   where document_type = 'insyter_agreement' and version = 'v1.1';
  select count(*) into n_users   from public.users where agreement_version = 'v1.1';
  select count(*) into n_current from public.agreement_versions where version = 'v1.1' and is_current;

  if n_accept > 0 or n_users > 0 or n_current > 0 then
    raise exception 'FAIL (AC0.1): v1.1 in use — acceptances %, users stamped %, current % — the migration would refuse',
      n_accept, n_users, n_current;
  end if;

  if has_v11 then
    raise notice 'PRE-MIGRATION: v1.1 exists, unused and not current — the P0 guard would pass and delete it';
  else
    raise notice 'PASS (AC0.2): no v1.1 row';
  end if;

  select count(*) into n_v10 from public.agreement_versions where version = 'v1.0';
  if n_v10 <> 1 then
    raise exception 'FAIL (AC0.2): expected exactly one v1.0 row, found %', n_v10;
  end if;
  raise notice 'PASS (AC0.2): v1.0 present';

  -- AC0.3: the v1.1 body is no longer in the bucket (ops step; staging only — prod never had it).
  select count(*) into n_objects
    from storage.objects
   where bucket_id = 'creator-agreements'
     and name like '%v1.1%';
  if n_objects > 0 then
    raise exception 'FAIL (AC0.3): % creator-agreements object(s) still named like v1.1 — delete them via the Storage API', n_objects;
  end if;
  raise notice 'PASS (AC0.3): no v1.1 object in creator-agreements';
end;
$$;

rollback;
