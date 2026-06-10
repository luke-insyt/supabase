-- creator_subscription_revenue() — server-side aggregates for the /my-insyts
-- subscription insights, so the client never fetches the whole invoice ledger
-- just to sum it (and the totals stay correct once the payments table is paged).
-- Returns one JSON object for the calling creator (auth.uid()):
--   currency, active_count, mrr_cents (sum of active subs), added_30d, lost_30d,
--   total_cents (all paid invoices), and months[] = last 12 calendar months of
--   paid subscription revenue (zero-filled). SECURITY DEFINER like the other
--   creator_*_stats RPCs; RLS-equivalent because every clause is scoped to
--   auth.uid() as the creator.

CREATE OR REPLACE FUNCTION public.creator_subscription_revenue()
  RETURNS json
  LANGUAGE sql
  SECURITY DEFINER
  SET search_path = public
AS $$
  WITH me AS (SELECT auth.uid() AS uid),
  active AS (
    SELECT COUNT(*) AS active_count, COALESCE(SUM(cs.amount_cents), 0) AS mrr_cents
    FROM public.creator_subscriptions cs, me
    WHERE cs.creator_id = me.uid AND cs.status IN ('active', 'trialing')
  ),
  churn AS (
    SELECT
      COUNT(*) FILTER (WHERE cs.started_at  >= now() - interval '30 days') AS added_30d,
      COUNT(*) FILTER (WHERE cs.canceled_at >= now() - interval '30 days') AS lost_30d
    FROM public.creator_subscriptions cs, me
    WHERE cs.creator_id = me.uid
  ),
  total AS (
    SELECT COALESCE(SUM(si.amount_cents), 0) AS total_cents
    FROM public.subscription_invoices si, me
    WHERE si.creator_id = me.uid AND si.status = 'paid'
  ),
  months AS (
    SELECT to_char(m, 'YYYY-MM') AS ym,
           to_char(m, 'Mon')     AS label,
           COALESCE(SUM(si.amount_cents), 0) AS total_cents
    FROM generate_series(date_trunc('month', now()) - interval '11 months',
                         date_trunc('month', now()),
                         interval '1 month') AS m
    LEFT JOIN public.subscription_invoices si
      ON si.creator_id = (SELECT uid FROM me)
     AND si.status = 'paid'
     AND date_trunc('month', si.paid_at) = m
    GROUP BY m
    ORDER BY m
  )
  SELECT json_build_object(
    'currency',     COALESCE((SELECT u.subscription_currency FROM public.users u, me WHERE u.auth_user_id = me.uid), 'eur'),
    'active_count', (SELECT active_count FROM active),
    'mrr_cents',    (SELECT mrr_cents    FROM active),
    'added_30d',    (SELECT added_30d    FROM churn),
    'lost_30d',     (SELECT lost_30d     FROM churn),
    'total_cents',  (SELECT total_cents  FROM total),
    'months',       (SELECT COALESCE(json_agg(json_build_object('ym', ym, 'label', label, 'total_cents', total_cents) ORDER BY ym), '[]'::json) FROM months)
  );
$$;

GRANT EXECUTE ON FUNCTION public.creator_subscription_revenue() TO authenticated;
