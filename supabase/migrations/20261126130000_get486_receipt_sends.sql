-- GET-486 A2 (S1, feature.md §2.2): dedupe table for the n8n subscription receipt.
--
-- n8n "Purchase Completed" claims a row per Stripe Checkout session before it sends the
-- subscription-confirmation email:
--   POST /rest/v1/receipt_sends  Prefer: resolution=ignore-duplicates,return=representation
-- An empty array back means another run (a Stripe retry or replay) already claimed the session,
-- so that run stops: exactly one email per subscription (AC1.1). After the send n8n PATCHes the
-- row to 'sent', or to 'failed' on error. Rows stuck in 'claimed' are picked up by the workflow's
-- 15-minute stale-claim alert; resending is a manual runbook step (no automatic retry, by design).
--
-- Only n8n writes it, with the service-role key. RLS on with no policies, and anon/authenticated
-- lose every grant, so no client can read or write it.

create table if not exists public.receipt_sends (
  stripe_session_id text primary key,
  kind              text not null
                    constraint receipt_sends_kind_check check (kind in ('subscription_confirmation')),
  status            text not null default 'claimed'
                    constraint receipt_sends_status_check check (status in ('claimed', 'sent', 'failed')),
  claimed_at        timestamptz not null default now(),
  sent_at           timestamptz
);

comment on table public.receipt_sends is
  'GET-486: one row per Stripe Checkout session whose receipt n8n claimed (dedupe for the subscription confirmation). Service role only.';

alter table public.receipt_sends enable row level security;

revoke all on table public.receipt_sends from anon, authenticated;
grant all on table public.receipt_sends to service_role;

-- The stale-claim check filters on status + claimed_at.
create index if not exists receipt_sends_claimed_idx
  on public.receipt_sends (claimed_at)
  where status = 'claimed';
