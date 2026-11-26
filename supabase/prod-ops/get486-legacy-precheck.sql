-- ============================================================================
-- GET-486 A1 (S2, AC2.2) — read-only pre-check before dropping agreement_acceptances.
--
-- SELECT ONLY. Writes nothing, takes no locks beyond a normal read. Safe on prod.
-- Run it per project, staging first, right before the merge (staging) and again right before
-- the prod apply of 20261126120000_get470_drop_legacy_acceptances.sql:
--   staging  xeqjairmlwnjtmselyvo — Supabase MCP execute_sql / SQL editor / psql -f
--   prod     krapqgxrqprtajatxjzd — Management API POST /v1/projects/<ref>/database/query
-- Paste the one-row result into the PR.
--
-- Go / no-go:
--   unmatched_legacy_rows        must be 0   (else STOP: escalate, patch nothing by hand)
--   ledger_rows >= legacy_rows   must be true
--   functions_reading_legacy     must list only record_insyter_acceptance and
--                                anonymise_terms_acceptances (both recreated by the migration)
--   orphan_ledger_users          informational: these ledger rows belong to users deleted
--                                before GET-470; the migration anonymises them before the drop
--
-- Twin rule (AC2.2) — the SAME predicate as the migration's guard; keep the two in sync:
-- same auth_user_id, version, document_type = 'insyter_agreement', accepted_at; and either
-- signature_name equal, or the legacy row tokenised ('deleted-user') with the twin anonymised
-- (anonymised_at set, signature_name null).
-- ============================================================================
with legacy as (
  select a.id, a.auth_user_id, a.version::text as version, a.accepted_at, a.signature_name
    from public.agreement_acceptances a
),
unmatched as (
  select l.*
    from legacy l
   where not exists (
     select 1 from public.terms_acceptances t
      where t.auth_user_id = l.auth_user_id
        and t.document_type = 'insyter_agreement'
        and t.version = l.version
        and t.accepted_at = l.accepted_at
        and (t.signature_name = l.signature_name
             or (l.signature_name = 'deleted-user'
                 and t.anonymised_at is not null
                 and t.signature_name is null))
   )
),
orphans as (
  select t.auth_user_id, count(*) as n
    from public.terms_acceptances t
   where t.document_type = 'insyter_agreement'
     and t.anonymised_at is null
     and not exists (select 1 from auth.users u where u.id = t.auth_user_id)
   group by t.auth_user_id
)
select
  (select count(*) from legacy)                                                     as legacy_rows,
  (select count(*) from public.terms_acceptances where document_type = 'insyter_agreement')
                                                                                    as ledger_rows,
  (select count(*) from public.terms_acceptances where document_type = 'insyter_agreement')
    >= (select count(*) from legacy)                                                as ledger_ge_legacy,
  (select count(*) from unmatched)                                                  as unmatched_legacy_rows,
  -- ids + timestamps only (no email / name), so the output can go into a PR
  (select coalesce(jsonb_agg(jsonb_build_object(
            'id', id, 'auth_user_id', auth_user_id, 'version', version,
            'accepted_at', accepted_at, 'tokenised', signature_name = 'deleted-user')
          order by accepted_at), '[]'::jsonb)
     from unmatched)                                                                as unmatched_detail,
  (select count(*) from orphans)                                                    as orphan_ledger_users,
  (select coalesce(sum(n), 0) from orphans)                                         as orphan_ledger_rows,
  (select coalesce(jsonb_agg(auth_user_id order by auth_user_id), '[]'::jsonb) from orphans)
                                                                                    as orphan_user_ids,
  -- plpgsql bodies aren't catalog dependencies: a drifted function that still reads the table
  -- wouldn't block the drop and would only fail at call time.
  (select coalesce(jsonb_agg(n.nspname || '.' || p.proname order by n.nspname, p.proname), '[]'::jsonb)
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where p.prosrc ilike '%agreement_acceptances%')                                 as functions_reading_legacy,
  -- views / rules / FKs that depend on the table (the drop has no cascade, so these would fail it)
  (select coalesce(jsonb_agg(distinct d.classid::regclass::text || ':' || d.objid), '[]'::jsonb)
     from pg_depend d
    where d.refobjid = 'public.agreement_acceptances'::regclass
      and d.deptype = 'n'
      and d.classid <> 'pg_class'::regclass)                                        as catalog_dependents;
