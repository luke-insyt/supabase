-- GET-181: the RN Stripe webhook (getinsyts-native/server webhooks/stripe.ts)
-- guards against duplicate deliveries by upserting the event id into
-- `stripe_events` and bailing out ("duplicate") when the row already exists.
-- That table was referenced (review finding #9) but NEVER created — so the
-- upsert errored, `fresh` came back empty, and EVERY webhook returned early as a
-- "duplicate" WITHOUT inserting the purchase. Net effect: no RN purchase was
-- ever recorded and buyers never got access ("I bought this insyt. I should see
-- the content"). Create the table so first-delivery wins and retries no-op.
create table if not exists public.stripe_events (
  event_id    text primary key,
  received_at timestamptz not null default now()
);

-- Only the trusted server (service_role) touches this table; RLS on + no policy
-- keeps it locked to service_role (which bypasses RLS).
alter table public.stripe_events enable row level security;
