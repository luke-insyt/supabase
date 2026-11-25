-- GET-470 P1 — migration A: agreement_versions becomes typed (additive only).
--
-- Design: webflow-app-documentation/features/legal-terms-acceptance/feature.md §2.2 (1–2)
-- Plan:   webflow-app-documentation/features/legal-terms-acceptance/implementation.md "P1" item 1
--
-- Purely additive, so every current reader keeps working. It ships BEFORE the readers add
-- `.eq('document_type', 'insyter_agreement')` (PostgREST rejects a filter on a missing column
-- with 42703), and they must all be deployed BEFORE migration B and before any non-Insyter
-- row is made current (feature.md §2.2 deploy-order hazard).
--
--   document_type  default 'insyter_agreement' backfills the existing rows (AC1.1). The
--                  default is dropped again in migration B, so every new row names its type.
--   sha256         hex SHA-256 of the served bytes of the frozen file (AC1.2); nullable here,
--                  pinned for v1.0 and set NOT NULL in migration B.
--   display_text   the inline sentence for `withdrawal_waiver` rows; null for the others.

begin;

alter table public.agreement_versions
  add column if not exists document_type text not null default 'insyter_agreement'
    constraint agreement_versions_document_type_check
      check (document_type in ('buyer_terms', 'insyter_agreement', 'privacy', 'withdrawal_waiver')),
  add column if not exists sha256 text
    constraint agreement_versions_sha256_check check (sha256 ~ '^[0-9a-f]{64}$'),
  add column if not exists display_text text;

comment on column public.agreement_versions.document_type is
  'GET-470: which legal document this version belongs to. One current row per type.';
comment on column public.agreement_versions.sha256 is
  'GET-470: lowercase hex SHA-256 of the served bytes of the frozen file at url (AC1.2).';
comment on column public.agreement_versions.display_text is
  'GET-470: inline sentence shown with a withdrawal_waiver version (checkout pre-step + Stripe custom_text).';

commit;
