-- Adds the "subscribe to a creator" feature. A subscriber pays a monthly
-- recurring fee; while the subscription is active (or trialing / in past_due
-- grace) they can read EVERY insyt by that creator. Surfaces:
--   * /creators/<auth_user_id> — #cp-subscribe-btn + owner #cp-subscription-settings-btn
--   * /insyts/<slug>           — subscribe CTA on the locked state
--   * /my-insyts               — subscriber's Subscriptions tab + creator subscriber stats
--
-- Source of truth for subscription STATE is public.creator_subscriptions,
-- written exclusively by the n8n Stripe-webhook workflow + the subscription
-- edge functions (service-role). Mirrors public.follows: auth-uuid keys, a
-- denormalised counter on public.users kept in sync by a SECURITY DEFINER
-- trigger, and RLS that lets each side READ its own rows while all writes are
-- service-role. See webflow-app-documentation/features/creator-subscriptions-features.md
--
-- Payout/Connect routing is deliberately OUT OF SCOPE here (v1 collects on the
-- platform account); it lands with the separate payouts feature.

-- ============================================================================
-- 1. The subscription relationship. subscriber_id / creator_id are auth uuids
--    (like public.follows) — every public creator key in the system is
--    auth_user_id, and the access gate / my-insyts both key on it. Stripe ids
--    let the webhook upsert idempotently by stripe_subscription_id.
-- ============================================================================
CREATE TABLE public.creator_subscriptions (
  id                     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  subscriber_id          uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  creator_id             uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  stripe_subscription_id text UNIQUE,
  stripe_customer_id     text,
  status                 text NOT NULL DEFAULT 'incomplete',  -- mirrors Stripe: active|trialing|past_due|canceled|incomplete|unpaid
  amount_cents           integer,
  currency               text,                                -- creator-set currency, e.g. 'eur'|'usd'
  current_period_end     timestamptz,
  trial_end              timestamptz,
  cancel_at_period_end   boolean NOT NULL DEFAULT false,
  started_at             timestamptz NOT NULL DEFAULT now(),
  canceled_at            timestamptz,
  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now(),
  CHECK (subscriber_id <> creator_id)
);

-- "who am I subscribed to" (access gate + my-insyts) is the hot read; add the
-- reverse for creator-side subscriber counts/stats.
CREATE INDEX creator_subscriptions_subscriber_idx ON public.creator_subscriptions (subscriber_id);
CREATE INDEX creator_subscriptions_creator_idx    ON public.creator_subscriptions (creator_id);

-- At most one LIVE subscription per (subscriber, creator). Canceled rows are
-- kept for history (my-insyts payments + churn stats), so uniqueness is partial
-- over the active-ish statuses.
CREATE UNIQUE INDEX creator_subscriptions_one_active
  ON public.creator_subscriptions (subscriber_id, creator_id)
  WHERE status IN ('active', 'trialing', 'past_due', 'unpaid');

-- ============================================================================
-- 2. RLS. Each side reads its own rows; no anon/public read (these are private
--    payment relationships, unlike follows). NO write policies — only
--    service_role (n8n webhook + edge functions) writes, bypassing RLS.
-- ============================================================================
ALTER TABLE public.creator_subscriptions ENABLE ROW LEVEL SECURITY;

CREATE POLICY cs_select_own_subscriber ON public.creator_subscriptions
  FOR SELECT TO authenticated USING (subscriber_id = auth.uid());

CREATE POLICY cs_select_own_creator ON public.creator_subscriptions
  FOR SELECT TO authenticated USING (creator_id = auth.uid());

-- ============================================================================
-- 3. Per-paid-invoice ledger so /my-insyts can show subscription payments
--    without re-querying Stripe. Written by n8n on invoice.payment_succeeded /
--    invoice.payment_failed. Mirrors public.purchases (the one-off equivalent).
-- ============================================================================
CREATE TABLE public.subscription_invoices (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  subscription_id   uuid REFERENCES public.creator_subscriptions(id) ON DELETE SET NULL,
  subscriber_id     uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  creator_id        uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  stripe_invoice_id text UNIQUE,
  amount_cents      integer NOT NULL,
  currency          text NOT NULL,
  status            text NOT NULL,            -- paid | failed
  period_start      timestamptz,
  period_end        timestamptz,
  paid_at           timestamptz,
  stripe_blob       jsonb,
  created_at        timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX subscription_invoices_subscriber_idx ON public.subscription_invoices (subscriber_id);
CREATE INDEX subscription_invoices_creator_idx    ON public.subscription_invoices (creator_id);

ALTER TABLE public.subscription_invoices ENABLE ROW LEVEL SECURITY;

CREATE POLICY si_select_own_subscriber ON public.subscription_invoices
  FOR SELECT TO authenticated USING (subscriber_id = auth.uid());

CREATE POLICY si_select_own_creator ON public.subscription_invoices
  FOR SELECT TO authenticated USING (creator_id = auth.uid());

-- ============================================================================
-- 4. Creator-side columns on public.users. subscriber_count is the
--    denormalised count of ACTIVE subscribers (status active|trialing), kept in
--    sync by trigger. subscription_currency + subscription_trial_days are set by
--    the set-subscription-price edge function (the amount stays in the existing
--    subscription_price_usd column — name is legacy, currency is explicit).
-- ============================================================================
ALTER TABLE public.users
  ADD COLUMN subscriber_count             integer NOT NULL DEFAULT 0,
  ADD COLUMN subscription_currency        text,
  ADD COLUMN subscription_trial_days      integer,
  ADD COLUMN stripe_subscription_product_id text;  -- one Stripe Product per creator; reused across price changes

-- Recompute (vs +/- deltas) so it can't drift — same shape as
-- refresh_follow_counts (20260529130000). Lookups hit the creator_id index.
CREATE OR REPLACE FUNCTION public.refresh_subscriber_count(p_creator_id uuid)
  RETURNS void
  LANGUAGE sql
  SECURITY DEFINER
  SET search_path = public
AS $$
  UPDATE public.users u
     SET subscriber_count = (
       SELECT count(*)::int
         FROM public.creator_subscriptions
        WHERE creator_id = p_creator_id
          AND status IN ('active', 'trialing')
     )
   WHERE u.auth_user_id = p_creator_id;
$$;

-- Fires on INSERT/DELETE and on UPDATE (a status flip active<->canceled changes
-- the active count without any row count change, so UPDATE matters here —
-- unlike the immutable follows rows).
CREATE OR REPLACE FUNCTION public.creator_subscriptions_count_sync()
  RETURNS trigger
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path = public
AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    PERFORM public.refresh_subscriber_count(OLD.creator_id);
    RETURN OLD;
  END IF;
  PERFORM public.refresh_subscriber_count(NEW.creator_id);
  -- A creator_id change (shouldn't happen, but be safe) refreshes the old one too.
  IF TG_OP = 'UPDATE' AND OLD.creator_id IS DISTINCT FROM NEW.creator_id THEN
    PERFORM public.refresh_subscriber_count(OLD.creator_id);
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS creator_subscriptions_count_sync ON public.creator_subscriptions;
CREATE TRIGGER creator_subscriptions_count_sync
  AFTER INSERT OR UPDATE OR DELETE ON public.creator_subscriptions
  FOR EACH ROW
  EXECUTE FUNCTION public.creator_subscriptions_count_sync();

-- Keep updated_at fresh on any change.
CREATE OR REPLACE FUNCTION public.creator_subscriptions_touch_updated_at()
  RETURNS trigger
  LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS creator_subscriptions_touch_updated_at ON public.creator_subscriptions;
CREATE TRIGGER creator_subscriptions_touch_updated_at
  BEFORE UPDATE ON public.creator_subscriptions
  FOR EACH ROW
  EXECUTE FUNCTION public.creator_subscriptions_touch_updated_at();

-- Backfill (table is empty on first deploy → resets everyone to 0; idempotent).
UPDATE public.users u
   SET subscriber_count = (
     SELECT count(*)::int
       FROM public.creator_subscriptions
      WHERE creator_id = u.auth_user_id
        AND status IN ('active', 'trialing')
   );

-- ============================================================================
-- 5. Creator subscriber stats (active + 30-day added/lost) for /my-insyts.
--    Keyed on auth.uid() so a caller can only ever read THEIR OWN stats — no
--    parameter to guess/inject. SECURITY DEFINER so it can aggregate over rows
--    the creator's own RLS would also allow, without exposing per-row data.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.creator_subscription_stats()
  RETURNS TABLE (active_count int, added_30d int, lost_30d int)
  LANGUAGE sql
  SECURITY DEFINER
  SET search_path = public
AS $$
  SELECT
    (SELECT count(*)::int FROM public.creator_subscriptions
       WHERE creator_id = auth.uid() AND status IN ('active', 'trialing')),
    (SELECT count(*)::int FROM public.creator_subscriptions
       WHERE creator_id = auth.uid() AND started_at  >= now() - interval '30 days'),
    (SELECT count(*)::int FROM public.creator_subscriptions
       WHERE creator_id = auth.uid() AND canceled_at >= now() - interval '30 days');
$$;

GRANT EXECUTE ON FUNCTION public.creator_subscription_stats() TO authenticated;

-- ============================================================================
-- 6. Public subscription "offer" for a creator — the display price + currency +
--    trial that the Subscribe button needs. public.users is NOT anon-readable
--    (counts are exposed via creator_search, prices nowhere), so expose just
--    the price-tag fields via a SECURITY DEFINER function. Returns no rows when
--    the creator hasn't set up a subscription (button then hides). The Stripe
--    price id is intentionally NOT exposed — the checkout edge function reads it
--    server-side from the creator's row.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.creator_subscription_offer(p_creator_id uuid)
  RETURNS TABLE (price_cents int, currency text, trial_days int)
  LANGUAGE sql
  SECURITY DEFINER
  SET search_path = public
AS $$
  SELECT u.subscription_price_usd, u.subscription_currency, u.subscription_trial_days
    FROM public.users u
   WHERE u.auth_user_id = p_creator_id
     AND u.is_creator = true
     AND u.stripe_subscription_price_id IS NOT NULL;
$$;

GRANT EXECUTE ON FUNCTION public.creator_subscription_offer(uuid) TO anon, authenticated;
