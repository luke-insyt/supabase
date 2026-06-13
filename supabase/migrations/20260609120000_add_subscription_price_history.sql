-- Subscription price history + change analytics (§13 follow-up).
--
-- Two gaps in the as-built price-change feature this closes:
--   1. Stripe Prices are immutable, so every price change mints a NEW Price under
--      the SAME (reused) Product — but we only kept the LATEST on
--      users.stripe_subscription_price_id and overwrote the rest. The old ids
--      still live in Stripe but weren't queryable by us. `subscription_prices`
--      mirrors every Price we mint, 1:1 with Stripe, so we keep full price
--      history + a stable id to match Stripe.
--   2. The accept/decline outcome of a price change was wiped on resolution
--      (CLEAR_PENDING nulls the pending_* state), so "how many accepted the new
--      price?" was unanswerable. `subscription_price_changes` (one row per
--      change) + `subscription_price_change_results` (one row per subscriber
--      outcome) record it going forward.
--
-- Writes are service-role only (the subscription edge functions), same as the
-- rest of the feature; creators read their own rows via RLS for the /my-insyts
-- Subscriptions tab. Stripe stays the source of truth — these are projections.

-- ============================================================================
-- 1. subscription_prices — local mirror of every Stripe Price for a creator's
--    subscription. is_active flags the creator's current price (≤1 per creator).
-- ============================================================================
CREATE TABLE public.subscription_prices (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  creator_id        uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  stripe_price_id   text NOT NULL UNIQUE,          -- price_... (matches Stripe)
  stripe_product_id text,                          -- prod_... (reused per creator)
  amount_cents      integer NOT NULL,
  currency          text NOT NULL,
  interval          text NOT NULL DEFAULT 'month',
  is_active         boolean NOT NULL DEFAULT true, -- the creator's current price
  created_at        timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX subscription_prices_creator_idx
  ON public.subscription_prices (creator_id, created_at DESC);
-- At most one active price per creator (the edge fn deactivates the prior one
-- before inserting the new active row).
CREATE UNIQUE INDEX subscription_prices_one_active
  ON public.subscription_prices (creator_id) WHERE is_active;

-- ============================================================================
-- 2. subscription_price_changes — one row per change APPLIED TO EXISTING
--    subscribers (first-time setup / currency change affects new subs only → no
--    row). The "campaign" the acceptance numbers roll up to.
-- ============================================================================
CREATE TABLE public.subscription_price_changes (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  creator_id        uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  from_price_id     text,                          -- stripe price_... before (NULL if unknown)
  to_price_id       text NOT NULL,                 -- stripe price_... after
  from_amount_cents integer,
  to_amount_cents   integer NOT NULL,
  currency          text NOT NULL,
  kind              text NOT NULL,                 -- 'increase' | 'decrease'
  fallback          text,                          -- 'keep_old' | 'cancel' (increase only)
  notice_days       integer,
  deadline          timestamptz,
  affected_count    integer NOT NULL DEFAULT 0,    -- live subs stamped at change time
  created_at        timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT subscription_price_changes_kind_chk
    CHECK (kind IN ('increase', 'decrease')),
  CONSTRAINT subscription_price_changes_fallback_chk
    CHECK (fallback IS NULL OR fallback IN ('keep_old', 'cancel'))
);
CREATE INDEX subscription_price_changes_creator_idx
  ON public.subscription_price_changes (creator_id, created_at DESC);

-- ============================================================================
-- 3. subscription_price_change_results — per-subscriber outcome of a change, so
--    we can show "N of M accepted the new price". One row per (change, sub),
--    inserted at resolution time (accept / decline / sweep). Idempotent via the
--    unique (change_id, subscription_id).
-- ============================================================================
CREATE TABLE public.subscription_price_change_results (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  change_id       uuid NOT NULL REFERENCES public.subscription_price_changes(id) ON DELETE CASCADE,
  subscription_id uuid NOT NULL REFERENCES public.creator_subscriptions(id) ON DELETE CASCADE,
  subscriber_id   uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  outcome         text NOT NULL,                   -- 'accepted' | 'kept_old' | 'canceled'
  resolved_at     timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT subscription_price_change_results_outcome_chk
    CHECK (outcome IN ('accepted', 'kept_old', 'canceled')),
  UNIQUE (change_id, subscription_id)
);
CREATE INDEX subscription_price_change_results_change_idx
  ON public.subscription_price_change_results (change_id);

-- ============================================================================
-- 4. Link a sub's CURRENT pending change to its campaign row so confirm/sweep
--    know which change to record an outcome against. NULL in steady state;
--    cleared alongside the other pending_* columns on resolution.
-- ============================================================================
ALTER TABLE public.creator_subscriptions
  ADD COLUMN pending_change_id uuid REFERENCES public.subscription_price_changes(id) ON DELETE SET NULL;

-- ============================================================================
-- 5. RLS — creators read their own price history, changes, and results. Writes
--    are service-role only (edge functions), same as the rest of the feature.
-- ============================================================================
ALTER TABLE public.subscription_prices ENABLE ROW LEVEL SECURITY;
CREATE POLICY sp_select_own_creator ON public.subscription_prices
  FOR SELECT TO authenticated USING (creator_id = auth.uid());

ALTER TABLE public.subscription_price_changes ENABLE ROW LEVEL SECURITY;
CREATE POLICY spc_select_own_creator ON public.subscription_price_changes
  FOR SELECT TO authenticated USING (creator_id = auth.uid());

ALTER TABLE public.subscription_price_change_results ENABLE ROW LEVEL SECURITY;
-- A creator reads results for their own changes (the parent row's RLS also
-- restricts to creator_id = auth.uid(), so the subquery is consistent).
CREATE POLICY spcr_select_own_creator ON public.subscription_price_change_results
  FOR SELECT TO authenticated USING (
    EXISTS (
      SELECT 1 FROM public.subscription_price_changes c
      WHERE c.id = change_id AND c.creator_id = auth.uid()
    )
  );
