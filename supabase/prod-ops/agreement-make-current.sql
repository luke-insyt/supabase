begin; select set_config('app.agreement_version', 'v1.1', true);  -- ← edit the version here, nothing else
-- ============================================================================
-- GET-357 — make ONE Creator Agreement version current (the flip, and its undo).
--
-- NOT a migration, on purpose: it lives outside migrations/ so a flip can never
-- reach a project through `db push` or a branch merge (R1-AC2, R1-AC4). Run it
-- by hand, per project, staging first:
--   staging  xeqjairmlwnjtmselyvo — SQL editor / SQL API, or psql -f
--   prod     krapqgxrqprtajatxjzd — only with the Inquiries prod flip, after
--            legal sign-off of §8 and the prod upload (runbook, prod section)
--
-- Edit ONLY the version on line 1. `begin` shares that line on purpose: the
-- setting is transaction-local (set_config(..., true)), so it must be set
-- inside the transaction that reads it — in psql's autocommit a bare `select
-- set_config(..., true)` on its own line would be gone before the next statement.
-- The same file then runs unchanged in psql and through the SQL API, with no
-- psql \set.
--
-- Pre-flight (runbook): the version's body is uploaded to THIS project's
-- `creator-agreements` bucket, and `GET <url>` returns 200 — become-insyter
-- fetches `url`, and a current row pointing at a missing object breaks
-- onboarding.
--
-- Refuses (raises, nothing changes) unless exactly one row has that version and
-- its url is set: a typo can never commit a state with zero current versions,
-- and the agreement_versions_one_current index rules out two.
--
-- Undo: run it again with the previous version. The notice ledger is per
-- version, so nothing else needs cleaning — but everyone who accepted the newer
-- version becomes stale against the older one (the clean way back is a
-- corrected new version, feature.md §8).
--
-- Every Insyter not on this version must re-accept before they publish or send
-- a proposal. After a flip, the RN admin notify (POST /api/cs/agreement/notify)
-- emails them.
-- ============================================================================

do $$
declare
  v text := nullif(btrim(current_setting('app.agreement_version', true)), '');
  n integer;
begin
  if v is null then
    raise exception 'agreement-make-current: set the version on line 1';
  end if;
  select count(*) into n
    from public.agreement_versions
   where version = v
     and url is not null
     and btrim(url) <> '';
  if n <> 1 then
    raise exception 'agreement-make-current: no agreement_versions row % with a url (matches: %); nothing changed', v, n;
  end if;
end;
$$;

-- Two statements, in this order: clearing first keeps the per-row check of the
-- one-current unique index happy whatever order rows are visited in (a single
-- `set is_current = (version = v)` could briefly see two current rows).
update public.agreement_versions
   set is_current = false
 where is_current
   and version <> current_setting('app.agreement_version');

update public.agreement_versions
   set is_current = true
 where version = current_setting('app.agreement_version');

-- Belt and braces: exactly one current row, and it's the one asked for.
do $$
declare
  v text := current_setting('app.agreement_version');
  n integer;
  cur text;
begin
  select count(*), max(version) into n, cur from public.agreement_versions where is_current;
  if n <> 1 or cur is distinct from v then
    raise exception 'agreement-make-current: expected % current, found % row(s) (%); rolled back', v, n, cur;
  end if;
end;
$$;

commit;

select version, is_current, effective_date, url
  from public.agreement_versions
 order by version;
