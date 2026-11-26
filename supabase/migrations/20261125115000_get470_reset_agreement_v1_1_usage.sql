-- GET-470 (S0): Creator Agreement v2.0 replaces v1.1. Staging made v1.1 current while
-- testing GET-357, so test Insyters accepted it and the v1.1 removal guard
-- (20261125120000) refused to run. Those users accept v2.0 when it goes current; until
-- then they're back on v1.0, the version that is current everywhere else.
--
-- Prod has no v1.1 usage (v1.1 never current there), so every statement is a no-op there.
-- Runs before the guard, which still raises if anything points at v1.1 afterwards.

do $$
begin
  if exists (select 1 from public.agreement_versions where version = 'v1.1' and is_current) then
    -- one-current index: clear first, then set
    update public.agreement_versions set is_current = false where version = 'v1.1';
    update public.agreement_versions set is_current = true  where version = 'v1.0';
  end if;
end $$;

-- FK agreement_acceptances.version → agreement_versions(version) blocks the v1.1 delete
delete from public.agreement_acceptances where version = 'v1.1';

-- guard_users_privileged_cols (GET-117) only lets the service role change
-- agreement_version; a migration carries no JWT, so claim it for this transaction only.
-- (one DO block, so the claim and the update share a transaction however the file runs)
do $$
begin
  perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
  update public.users set agreement_version = 'v1.0' where agreement_version = 'v1.1';
  perform set_config('request.jwt.claims', '', true);
end $$;
