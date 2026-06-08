-- /my-insyts dashboard stats RPCs. Powers the role-aware "My Insyts" dashboard:
-- a "My activity" total row (everyone) and a "My content" total row (creators),
-- each card carrying a last-30-days delta, plus the consumer "Viewed insyts"
-- grid. See doc/my-insyts-dashboard.md.
--
-- All functions are SECURITY DEFINER + keyed on the caller's identity
-- (auth.uid() for uuid keys, auth.jwt()->>'email' for the email-keyed
-- purchases/insyts tables — matching their RLS policies). They aggregate over
-- private rows (notably public.insyt_views, which has RLS enabled with NO
-- policies) but only ever return the caller's own aggregates, never another
-- user's per-row data. Same shape as creator_subscription_stats
-- (20260601120000) and get_trending_insyts (20260531201355).
--
-- Identity notes:
--   * purchases.buyer_email / .creator_email and insyts.creator_email are the
--     email-keyed join keys → use auth.jwt()->>'email'.
--   * insyt_views.user_id, follows.creator_id, creator_subscriptions /
--     subscription_invoices are auth-uuid keyed → use auth.uid().
--   * "viewed in last 30 days" deltas use first_viewed_at (a NEW distinct view),
--     so the delta matches the increment to the all-time distinct-viewer total.
--   * Text columns are cast to text so RETURNS TABLE stays stable regardless of
--     the underlying varchar choices on public.insyts.

-- ============================================================================
-- 1. My-activity card numbers (consumer; everyone). purchases + subscriptions
--    are RLS-readable on their own, but insyt_views is service-role only, so we
--    bundle all three here for a single round-trip behind one definer boundary.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.my_consumer_stats()
  RETURNS TABLE (
    purchased_total int, purchased_30d int,
    viewed_total    int, viewed_30d    int,
    active_subs     int, subs_added_30d int
  )
  LANGUAGE sql
  STABLE
  SECURITY DEFINER
  SET search_path = public
AS $$
  SELECT
    (SELECT count(*)::int FROM public.purchases
       WHERE buyer_email = auth.jwt() ->> 'email'),
    (SELECT count(*)::int FROM public.purchases
       WHERE buyer_email = auth.jwt() ->> 'email'
         AND purchased_at >= now() - interval '30 days'),
    (SELECT count(*)::int FROM public.insyt_views
       WHERE user_id = auth.uid()),
    (SELECT count(*)::int FROM public.insyt_views
       WHERE user_id = auth.uid()
         AND first_viewed_at >= now() - interval '30 days'),
    (SELECT count(*)::int FROM public.creator_subscriptions
       WHERE subscriber_id = auth.uid()
         AND status IN ('active', 'trialing', 'past_due')),
    (SELECT count(*)::int FROM public.creator_subscriptions
       WHERE subscriber_id = auth.uid()
         AND started_at >= now() - interval '30 days');
$$;

GRANT EXECUTE ON FUNCTION public.my_consumer_stats() TO authenticated;

-- ============================================================================
-- 2. Consumer "Viewed insyts" grid (paginated, most-recently-viewed first).
--    Joins the private insyt_views to the public insyt fields. insyt_id is the
--    varchar slug (for the /insyts/<slug> link), not the uuid PK.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.my_viewed_insyts(
    p_limit int DEFAULT 24, p_offset int DEFAULT 0)
  RETURNS TABLE (
    insyt_id             text,
    title                text,
    creator_display_name text,
    thumbnail_url        text,
    price_eur            int,
    last_viewed_at       timestamptz
  )
  LANGUAGE sql
  STABLE
  SECURITY DEFINER
  SET search_path = public
AS $$
  SELECT i.insyt_id::text,
         i.title::text,
         i.creator_display_name::text,
         i.thumbnail_url::text,
         COALESCE(i.price_eur, 0),
         v.last_viewed_at
  FROM public.insyt_views v
  JOIN public.insyts i ON i.id = v.insyt_id
  WHERE v.user_id = auth.uid()
  ORDER BY v.last_viewed_at DESC
  LIMIT GREATEST(COALESCE(p_limit, 24), 0)
  OFFSET GREATEST(COALESCE(p_offset, 0), 0);
$$;

GRANT EXECUTE ON FUNCTION public.my_viewed_insyts(int, int) TO authenticated;

-- ============================================================================
-- 3. My-content card numbers (creator). paid/free/views_total are RLS-readable
--    off the caller's own insyts, but views_30d needs insyt_views (service-role)
--    and followers_30d scans follows — bundled here. followers_total reads the
--    denormalised users.follower_count.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.creator_content_stats()
  RETURNS TABLE (
    paid_count int, free_count int,
    paid_30d   int, free_30d   int,
    views_total int, views_30d int,
    followers_total int, followers_30d int
  )
  LANGUAGE sql
  STABLE
  SECURITY DEFINER
  SET search_path = public
AS $$
  SELECT
    (SELECT count(*)::int FROM public.insyts
       WHERE creator_email = auth.jwt() ->> 'email' AND COALESCE(price_eur, 0) > 0),
    (SELECT count(*)::int FROM public.insyts
       WHERE creator_email = auth.jwt() ->> 'email' AND COALESCE(price_eur, 0) = 0),
    (SELECT count(*)::int FROM public.insyts
       WHERE creator_email = auth.jwt() ->> 'email' AND COALESCE(price_eur, 0) > 0
         AND created_at >= now() - interval '30 days'),
    (SELECT count(*)::int FROM public.insyts
       WHERE creator_email = auth.jwt() ->> 'email' AND COALESCE(price_eur, 0) = 0
         AND created_at >= now() - interval '30 days'),
    (SELECT COALESCE(sum(view_count), 0)::int FROM public.insyts
       WHERE creator_email = auth.jwt() ->> 'email'),
    (SELECT count(*)::int
       FROM public.insyt_views v
       JOIN public.insyts i ON i.id = v.insyt_id
      WHERE i.creator_email = auth.jwt() ->> 'email'
        AND v.first_viewed_at >= now() - interval '30 days'),
    (SELECT COALESCE(follower_count, 0)::int FROM public.users
       WHERE auth_user_id = auth.uid()),
    (SELECT count(*)::int FROM public.follows
       WHERE creator_id = auth.uid()
         AND created_at >= now() - interval '30 days');
$$;

GRANT EXECUTE ON FUNCTION public.creator_content_stats() TO authenticated;

-- ============================================================================
-- 4. Revenue card numbers (creator): one-time sales (purchases, email-keyed) +
--    paid subscription invoices (creator_id, uuid-keyed), each with a 30-day
--    window. amount_paid / amount_cents are minor units (cents). Subscriber
--    counts come from the existing creator_subscription_stats().
-- ============================================================================
CREATE OR REPLACE FUNCTION public.creator_revenue_stats()
  RETURNS TABLE (
    onetime_cents bigint, onetime_30d_cents bigint, onetime_count int,
    sub_cents bigint, sub_30d_cents bigint
  )
  LANGUAGE sql
  STABLE
  SECURITY DEFINER
  SET search_path = public
AS $$
  SELECT
    (SELECT COALESCE(sum(amount_paid), 0)::bigint FROM public.purchases
       WHERE creator_email = auth.jwt() ->> 'email'),
    (SELECT COALESCE(sum(amount_paid), 0)::bigint FROM public.purchases
       WHERE creator_email = auth.jwt() ->> 'email'
         AND purchased_at >= now() - interval '30 days'),
    (SELECT count(*)::int FROM public.purchases
       WHERE creator_email = auth.jwt() ->> 'email'),
    (SELECT COALESCE(sum(amount_cents), 0)::bigint FROM public.subscription_invoices
       WHERE creator_id = auth.uid() AND status = 'paid'),
    (SELECT COALESCE(sum(amount_cents), 0)::bigint FROM public.subscription_invoices
       WHERE creator_id = auth.uid() AND status = 'paid'
         AND paid_at >= now() - interval '30 days');
$$;

GRANT EXECUTE ON FUNCTION public.creator_revenue_stats() TO authenticated;
