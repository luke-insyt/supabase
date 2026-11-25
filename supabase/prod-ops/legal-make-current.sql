begin; select set_config('app.legal_document_type', 'buyer_terms', true), set_config('app.legal_version', 'v2.0', true);  -- ← edit type + version here, nothing else
-- ============================================================================
-- GET-470 — make ONE legal version current for ONE document type (the flip, and its undo).
-- Replaces GET-357's agreement-make-current.sql, which cleared EVERY current row and would
-- have un-currented every other document type (feature.md §2.2 hazard, §2.7).
--
-- document_type: buyer_terms | insyter_agreement | privacy | withdrawal_waiver
--
-- NOT a migration, on purpose: it lives outside migrations/ so a flip can never reach a
-- project through `db push` or a branch merge. Run it by hand, per project, staging first:
--   staging  xeqjairmlwnjtmselyvo — SQL editor / SQL API, or psql -f
--   prod     krapqgxrqprtajatxjzd — §9 release only (runbook: docs code/legal-versions-runbook.md)
--
-- Edit ONLY line 1. `begin` shares that line on purpose: the settings are transaction-local
-- (set_config(..., true)), so they must be set inside the transaction that reads them. The
-- same file then runs unchanged in psql and through the SQL API, with no psql \set.
--
-- Pre-flight: the version was published with server/scripts/legal-publish.ts (file uploaded
-- with upsert:false, sha256 of the SERVED bytes stored, title + effective_date set). Readers
-- fetch `url`, so a current row pointing at a missing object breaks them.
--
-- Refuses (raises, nothing changes) unless exactly one row has that (type, version), with a
-- url and a sha256. Touches ONLY is_current of rows of that type — never effective_date or any
-- other column (agreement_versions is immutable apart from is_current, GET-470 AC1.4).
-- Commits only if exactly one row of that type is current afterwards and it's the one asked
-- for; other types are checked to be untouched.
--
-- After a flip:
--   * buyer_terms / privacy: users without the new version get the re-accept prompt (S6);
--     checkout stays blocked (409 terms_outdated) until they accept. On staging, re-run
--     server/scripts/legal-seed-fixtures.ts so the fixture users stay current.
--   * insyter_agreement: every Insyter not on it must re-accept before publishing or sending
--     a proposal; the RN admin notify (POST /api/cs/agreement/notify) emails them.
-- Undo: run it again with the previous version of the same type.
-- ============================================================================

-- Snapshot of the other types' current rows, to prove they're untouched at the end.
create temp table legal_make_current_others on commit drop as
  select document_type, version
    from public.agreement_versions
   where is_current
     and document_type <> current_setting('app.legal_document_type');

do $$
declare
  t text := nullif(btrim(current_setting('app.legal_document_type', true)), '');
  v text := nullif(btrim(current_setting('app.legal_version', true)), '');
  n integer;
begin
  if t is null or v is null then
    raise exception 'legal-make-current: set the document type and version on line 1';
  end if;
  if t not in ('buyer_terms', 'insyter_agreement', 'privacy', 'withdrawal_waiver') then
    raise exception 'legal-make-current: unknown document type %', t;
  end if;
  select count(*) into n
    from public.agreement_versions
   where document_type = t
     and version = v
     and url is not null and btrim(url) <> ''
     and sha256 is not null;
  if n <> 1 then
    raise exception 'legal-make-current: no published % row % with a url and sha256 (matches: %); nothing changed', t, v, n;
  end if;
end;
$$;

-- Two statements, in this order: clearing first keeps the per-type one-current unique index
-- (agreement_versions_one_current_per_type) happy whatever order rows are visited in.
update public.agreement_versions
   set is_current = false
 where is_current
   and document_type = current_setting('app.legal_document_type')
   and version <> current_setting('app.legal_version');

update public.agreement_versions
   set is_current = true
 where document_type = current_setting('app.legal_document_type')
   and version = current_setting('app.legal_version')
   and is_current is not true;

-- Belt and braces: exactly one current row of that type, it's the one asked for, and no other
-- type changed.
do $$
declare
  t   text := current_setting('app.legal_document_type');
  v   text := current_setting('app.legal_version');
  n   integer;
  cur text;
  drift integer;
begin
  select count(*), max(version) into n, cur
    from public.agreement_versions
   where is_current and document_type = t;
  if n <> 1 or cur is distinct from v then
    raise exception 'legal-make-current: expected % % current, found % row(s) (%); rolled back', t, v, n, cur;
  end if;
  select count(*) into drift
    from (
      (select document_type, version::text from legal_make_current_others
        except
       select document_type, version::text from public.agreement_versions where is_current and document_type <> t)
      union all
      (select document_type, version::text from public.agreement_versions where is_current and document_type <> t
        except
       select document_type, version::text from legal_make_current_others)
    ) d;
  if drift <> 0 then
    raise exception 'legal-make-current: another document type''s current row changed; rolled back';
  end if;
end;
$$;

commit;

select document_type, version, is_current, effective_date, sha256, url
  from public.agreement_versions
 order by document_type, version;
