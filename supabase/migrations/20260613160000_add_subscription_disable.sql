-- Disable subscription — let a creator stop offering their subscription.
-- Spec: webflow-app-documentation/features/disable-subscription/.
--
-- Two schema changes (the feature otherwise reuses the price-change machinery):
--   1. creator_subscriptions.cancel_reason — distinguishes a creator-initiated end
--      ('creator_disabled') from a self-serve / price-change-fallback cancel (NULL),
--      so the /my-insyts Subscriptions row hides "Resume" and shows "Ending on <date>"
--      ONLY for creator-disabled subs. No back-fill: existing cancel_at_period_end
--      rows stay NULL and keep today's behaviour.
--   2. Widen subscription_price_changes.kind to allow 'disable'. A disable writes one
--      campaign row (kind='disable', fallback 'keep_old' | 'cancel') + one
--      subscription_price_change_results row per affected sub ('kept_old' | 'canceled')
--      — reusing the existing CHECK-valid fallback/outcome values. to_price_id /
--      to_amount_cents / currency are NOT NULL, so a disable mirrors the archived
--      price's values (no real target price).
--
-- Writes stay service-role only (the new disable-subscription edge fn); no new RLS.

ALTER TABLE public.creator_subscriptions
  ADD COLUMN IF NOT EXISTS cancel_reason text;

ALTER TABLE public.creator_subscriptions
  DROP CONSTRAINT IF EXISTS creator_subscriptions_cancel_reason_chk,
  ADD CONSTRAINT creator_subscriptions_cancel_reason_chk
    CHECK (cancel_reason IS NULL OR cancel_reason IN ('creator_disabled'));

COMMENT ON COLUMN public.creator_subscriptions.cancel_reason IS
  'Why the subscription is ending: NULL = self-serve cancel or price-change fallback '
  '(default, keeps the Resume affordance); ''creator_disabled'' = the creator disabled '
  'their subscription offer (row shows "Ending on <date>", no Resume).';

-- Allow 'disable' campaigns alongside price increases/decreases.
ALTER TABLE public.subscription_price_changes
  DROP CONSTRAINT subscription_price_changes_kind_chk,
  ADD CONSTRAINT subscription_price_changes_kind_chk
    CHECK (kind IN ('increase', 'decrease', 'disable'));
