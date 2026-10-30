-- Waiting-list GDPR marketing consent (follow-up to 20260717224901_get198_waitlist).
--
-- The waiting-list confirmation email + the batched Brevo invites are marketing to a
-- list, so we need a recorded lawful basis per person. The form now carries a REQUIRED
-- consent checkbox; the edge fn rejects a submit without it. This stores the answer and
-- WHEN it was given, because "we have consent" is worthless without a timestamp if it is
-- ever challenged.
--
-- `consent_at` is nullable on purpose: rows written BEFORE this migration have no
-- recorded consent and must not be back-dated into looking compliant. They are
-- distinguishable forever as marketing_consent = false / consent_at IS NULL — see the
-- backfill note in waitlist-landing-features.md §6.
--
-- Additive + idempotent (add-column-if-not-exists), matching the house style of the
-- original waitlist migration.

alter table public.waitlist
  add column if not exists marketing_consent boolean not null default false;

alter table public.waitlist
  add column if not exists consent_at timestamptz;

comment on column public.waitlist.marketing_consent is
  'GDPR: visitor ticked the required consent box. False on pre-consent rows (2026-07-21 and earlier) — do NOT email those without re-consent.';

comment on column public.waitlist.consent_at is
  'When consent was given (server clock). NULL = never recorded; never back-fill it.';
