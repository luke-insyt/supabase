-- GET-486 A2 / AC1.0 — read-only pre-check for the subscription receipt.
--
-- SELECT ONLY. Run on staging and on prod (Management API `database/query`) before the A2
-- merge, and again on prod right before the A2 prod release. Paste the output into the PR.
--
-- Question it answers: did n8n "Purchase Completed" (which had no `mode` branch before A2)
-- ever turn a subscription Checkout session into a junk `purchases` row (and so send template
-- 146 with an empty title)? A junk row is either
--   (a) a row whose stored Stripe session is a subscription session, or
--   (b) a row with no usable insyt_id (null / '' / 'undefined').
-- If any env returns rows in section 1, A2 adds the guarded cleanup migration
-- `<ts>_get486_purchases_subscription_junk.sql` (implementation.md A2 step 1).

-- 1. Junk candidates, with whether a payout already references them (a referenced row must
--    never be deleted; the cleanup migration raises instead).
select p.id,
       p.created_at,
       p.stripe_session_id,
       p.insyt_id,
       p.amount_paid,
       p.writer,
       (p.stripe_blob -> 'object' ->> 'mode')           as session_mode,
       exists (select 1 from public.creator_payout_items i
               where i.purchase_id = p.id)               as in_payout
from public.purchases p
where (p.stripe_blob -> 'object' ->> 'mode') = 'subscription'
   or p.insyt_id is null
   or btrim(p.insyt_id) = ''
   or p.insyt_id = 'undefined'
order by p.created_at;

-- 2. Counts for the PR (context: how many rows n8n vs the RN webhook wrote).
select count(*)                                                         as purchases_total,
       count(*) filter (where (stripe_blob -> 'object' ->> 'mode') = 'subscription') as subscription_mode,
       count(*) filter (where insyt_id is null or btrim(insyt_id) = '' or insyt_id = 'undefined')
                                                                        as no_insyt_id,
       count(*) filter (where writer = 'n8n')                           as writer_n8n,
       count(*) filter (where writer = 'rn_webhook')                    as writer_rn,
       count(*) filter (where writer is null)                           as writer_null
from public.purchases;
