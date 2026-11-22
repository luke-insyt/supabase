-- GET-459 — one RN-webhook purchase row per Stripe checkout.
--
-- Design: webflow-app-documentation/features/inquiries/open-mode-feature.md §4.3 (step 2).
-- Test:   supabase/tests/get459_purchases_rn_session_unique_test.ts (PGlite, offline).
-- Mirror: getinsyts-native/db/schema.sql (local-dev approximation).
--
-- The RN Stripe webhook writes the mark LAST (Stripe retries until every write succeeded), so
-- its purchase insert must be idempotent per checkout. It skips the insert when its own row
-- exists, but two overlapping deliveries of one event can both pass that check. This partial
-- unique index makes the second insert fail with 23505, which the webhook reads as "already
-- inserted".
--
-- Scope of the index: the RN webhook's rows only — stripe_blob IS NULL (buildPurchaseInsert
-- never sets it). n8n's "Purchase Completed" twin row for the same checkout copies the session
-- into stripe_blob (20261017120000_get332_sales_anonymity.sql header), so it stays outside and
-- either row still grants access. Rows with no session id ('' or null) are left alone.
--
-- PRE-CHECK: an existing duplicate would make CREATE UNIQUE INDEX fail with a bare 23505. The
-- DO block fails first, naming the sessions, so whoever applies this can resolve them by hand
-- (never automatically: they are purchase records). Nothing is deleted here.
--
-- Additive. Rollback: drop index if exists public.purchases_rn_session_uidx;

begin;
set local lock_timeout      = '3s';   -- CREATE INDEX blocks purchase writes while it builds
set local statement_timeout = '60s';

do $$
declare dupes text;
begin
  select string_agg(format('%s (%s rows)', stripe_session_id, n), ', ')
    into dupes
    from (select stripe_session_id, count(*) as n
            from public.purchases
           where stripe_blob is null and stripe_session_id <> ''
           group by stripe_session_id
          having count(*) > 1
           order by stripe_session_id
           limit 20) d;
  if dupes is not null then
    raise exception 'GET-459: purchases has duplicate RN-webhook rows (same stripe_session_id, stripe_blob null) — resolve them before adding purchases_rn_session_uidx: %', dupes;
  end if;
end $$;

create unique index if not exists purchases_rn_session_uidx
  on public.purchases (stripe_session_id)
  where stripe_blob is null and stripe_session_id <> '';

comment on index public.purchases_rn_session_uidx is
  'GET-459: one RN-webhook purchase row (stripe_blob null) per Stripe checkout session; '
  'n8n''s twin row carries stripe_blob and is outside the index.';

commit;
