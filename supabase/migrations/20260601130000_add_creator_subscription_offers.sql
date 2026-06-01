-- Bulk variant of creator_subscription_offer (20260601120000) for list pages
-- (/insyters): given many creator ids, return the public price/currency/trial
-- for those that actually offer a subscription, in one round-trip. Same
-- exposure rules as the singular function — only the display price tag, never
-- the Stripe price id; rows omitted for creators without an offer (so the
-- caller hides those buttons). anon-readable (the /insyters page reads as anon).

CREATE OR REPLACE FUNCTION public.creator_subscription_offers(p_creator_ids uuid[])
  RETURNS TABLE (creator_id uuid, price_cents int, currency text, trial_days int)
  LANGUAGE sql
  SECURITY DEFINER
  SET search_path = public
AS $$
  SELECT u.auth_user_id, u.subscription_price_usd, u.subscription_currency, u.subscription_trial_days
    FROM public.users u
   WHERE u.auth_user_id = ANY(p_creator_ids)
     AND u.is_creator = true
     AND u.stripe_subscription_price_id IS NOT NULL;
$$;

GRANT EXECUTE ON FUNCTION public.creator_subscription_offers(uuid[]) TO anon, authenticated;
