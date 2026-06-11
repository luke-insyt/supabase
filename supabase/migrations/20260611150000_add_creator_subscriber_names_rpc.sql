-- Creators see who their subscribers are (TECH-DEBT §4.1).
--
-- The my-insyts revenue tables (subscription payments, ended subscriptions)
-- could only print the literal word "Subscriber": creators cannot read other
-- users' public.users rows under RLS, and subscribers are not in creator_search.
--
-- This RPC exposes ONLY the display identity (display_name/username — no email)
-- of users connected to the CALLING creator via a subscription or a subscription
-- invoice. SECURITY DEFINER + auth.uid() gate: a creator can never look up
-- arbitrary users, and anon callers get nothing.

CREATE OR REPLACE FUNCTION public.creator_subscriber_names()
RETURNS TABLE (subscriber_id uuid, display_name text)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT DISTINCT s.subscriber_id,
         COALESCE(
           NULLIF(trim(u.display_name), ''),
           NULLIF(trim(u.username), '')
         ) AS display_name
  FROM (
    SELECT cs.subscriber_id
      FROM public.creator_subscriptions cs
     WHERE cs.creator_id = auth.uid()
    UNION
    SELECT si.subscriber_id
      FROM public.subscription_invoices si
     WHERE si.creator_id = auth.uid()
  ) s
  JOIN public.users u ON u.auth_user_id = s.subscriber_id
$$;

REVOKE ALL ON FUNCTION public.creator_subscriber_names() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.creator_subscriber_names() FROM anon;
GRANT EXECUTE ON FUNCTION public.creator_subscriber_names() TO authenticated;
