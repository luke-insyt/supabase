-- Subscription price changes (adjustments). Lets a creator migrate EXISTING
-- subscribers when they change their price, instead of grandfathering them on
-- their sign-up price forever (the as-built v1 behaviour). Policy, locked
-- 2026-06-08, in webflow-app-documentation/features/creator-subscriptions-features.md §13:
--   * a DECREASE auto-applies at next renewal (heads-up email only);
--   * an INCREASE requires the subscriber's explicit opt-in (Accept in /my-insyts);
--   * if they don't accept by a creator-set deadline, the creator's chosen
--     fallback applies — keep them on the old price, or cancel at period end;
--   * the new price always takes effect at the NEXT renewal, never mid-period.
--
-- This migration only adds the per-subscription pending-change STATE. It's kept
-- on the single live creator_subscriptions row (no new table) so "one
-- subscription at a time" (the partial unique index creator_subscriptions_one_active)
-- is preserved — a migration mutates the existing sub in place. Writes are
-- service-role only (the subscription edge functions), same as the rest of the
-- table; the existing cs_select_own_* RLS already lets the subscriber read these
-- columns on their own row for the /my-insyts Accept/Decline banner.

-- ============================================================================
-- 1. Pending-change columns. All NULL means "no pending change" (the steady
--    state). Stamped on every active/trialing sub for the creator when the
--    price changes; cleared when the change takes effect or the fallback runs.
-- ============================================================================
ALTER TABLE public.creator_subscriptions
  ADD COLUMN pending_price_id     text,        -- target Stripe Price (price_...) for the next renewal
  ADD COLUMN pending_amount_cents integer,     -- target amount, minor units (snapshot of the new price)
  ADD COLUMN pending_currency     text,        -- target currency (usually unchanged from `currency`)
  ADD COLUMN pending_kind         text,        -- 'increase' | 'decrease'
  ADD COLUMN pending_fallback     text,        -- 'keep_old' | 'cancel'  (increase only; creator's choice §13 PC3)
  ADD COLUMN pending_deadline     timestamptz, -- accept-by date; new price applies at the first renewal on/after this
  ADD COLUMN pending_status       text,        -- 'pending' | 'accepted' | 'declined'  (NULL = no pending change)
  ADD CONSTRAINT creator_subscriptions_pending_kind_chk
    CHECK (pending_kind IS NULL OR pending_kind IN ('increase', 'decrease')),
  ADD CONSTRAINT creator_subscriptions_pending_fallback_chk
    CHECK (pending_fallback IS NULL OR pending_fallback IN ('keep_old', 'cancel')),
  ADD CONSTRAINT creator_subscriptions_pending_status_chk
    CHECK (pending_status IS NULL OR pending_status IN ('pending', 'accepted', 'declined'));

-- ============================================================================
-- 2. The deadline sweep (process-price-change-deadlines, run daily) reads only
--    the still-open changes that are due:
--      WHERE pending_status = 'pending' AND pending_deadline <= now()
--    A partial index keeps that scan tiny regardless of how many historical
--    (accepted/declined/NULL) rows accumulate.
-- ============================================================================
CREATE INDEX creator_subscriptions_pending_due_idx
  ON public.creator_subscriptions (pending_deadline)
  WHERE pending_status = 'pending';
