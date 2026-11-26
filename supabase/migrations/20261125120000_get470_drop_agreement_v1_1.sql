-- GET-470 P0 (S0) — remove Creator Agreement v1.1.
--
-- Design: webflow-app-documentation/features/legal-terms-acceptance/feature.md §2.1
-- Plan:   webflow-app-documentation/features/legal-terms-acceptance/implementation.md "P0"
-- Test:   supabase/tests/sql/legal_v11_guard.sql (psql, branch/local DB)
--         supabase/tests/get470_legal_registry_test.ts (PGlite, offline)
--
-- v1.1 (seeded, NOT current, by 20261111120000_get330_agreement_v1_1.sql) is superseded by
-- Insyter Agreement v2.0 (GET-470 OQ-11). Nobody may have signed it, nobody may be stamped
-- with it, and it must not be current; otherwise this refuses (AC0.1) and nothing changes.
-- The seed migration is left untouched (already applied): on a fresh DB this deletes what
-- the seed created (AC0.3).
--
-- Ordered BEFORE 20261125122000_get470_legal_registry.sql on purpose: that migration adds
-- a BEFORE DELETE trigger that forbids deleting any agreement_versions row.
--
-- Ops (not SQL): remove creator-agreements/v1.1 body from the staging bucket (already
-- missing on prod); mark docs terms/creator-agreement-v1.1.html as superseded.

begin;

do $$
declare
  n_accept  integer;
  n_users   integer;
  n_current integer;
begin
  select count(*) into n_accept  from public.agreement_acceptances where version = 'v1.1';
  select count(*) into n_users   from public.users where agreement_version = 'v1.1';
  select count(*) into n_current from public.agreement_versions where version = 'v1.1' and is_current;
  if n_accept > 0 or n_users > 0 or n_current > 0 then
    raise exception 'GET-470: Creator Agreement v1.1 is in use (acceptances: %, users stamped: %, current: %) — '
                    'make v1.0 current again and resolve these rows before removing v1.1',
                    n_accept, n_users, n_current;
  end if;
end;
$$;

delete from public.agreement_versions where version = 'v1.1';

commit;
