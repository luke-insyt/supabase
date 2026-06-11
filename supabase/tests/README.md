# Edge-function integration tests

## price_change_test.py — creator price changes (§13)

Drives the deployed **staging** edge functions and asserts the DB side effects.
Self-cleaning (creates throwaway `*@getinsyt.test` users + rows, deletes them in
teardown). 20 assertions; verified green 2026-06-09.

```bash
SUPABASE_SERVICE_ROLE_KEY=<staging service-role key> \
  python3 supabase/tests/price_change_test.py
```
`SUPABASE_URL` and `SUPABASE_ANON_KEY` default to staging. Exit 0 = all passed.

**Covers** (no Stripe test key needed — the functions hold their own key):
set-subscription-price (initial + raise → Stripe Price create, `subscription_prices`
mirror, `subscription_price_changes` log, pending stamp), confirm decline+keep_old
→ `subscription_price_change_results` outcome, the `creator_subscription_revenue`
RPC, and RLS isolation.

**Not yet covered — needs a real Stripe TEST subscription** (these paths call the
Stripe API on the subscriber's live subscription, so a fake `stripe_subscription_id`
won't do): accept (item swap), decline+cancel, and the deadline sweep's
decrease/cancel branches. To add:
1. With a Stripe **test** secret key, create a test customer + subscription on the
   creator's product/price (attach `pm_card_visa`), and use a **Stripe test clock**
   to advance past the deadline for the sweep.
2. Insert the matching `creator_subscriptions` row with that real
   `stripe_subscription_id` (instead of the fake one in step 2 of the script).
3. Call `confirm` with `accept` and assert the Stripe item swapped + outcome
   `accepted`; advance the test clock and POST `process-price-change-deadlines`,
   asserting the decrease/cancel outcomes.
4. Teardown: cancel/delete the Stripe sub + customer + test clock.

Note: each run creates harmless Stripe **test-mode** Price objects (not cleaned up).

## rating_subscriber_test.py — subscribers can rate paid insyts (§ ratings)

Verifies the `submit-insyt-rating` eligibility change (2026-06-10): a paid insyt
is rateable by a purchaser **or** an active subscriber to the creator. Creates a
throwaway user, asserts **403 before** subscribing → **200 after**, and that the
rating row lands; self-cleaning (deleting the user cascades the sub + rating, and
the aggregate trigger recomputes). 4 assertions; verified green.

```bash
SUPABASE_SERVICE_ROLE_KEY=<staging service-role key> \
  python3 supabase/tests/rating_subscriber_test.py
```
Override `RATING_CREATOR_ID` / `RATING_INSYT_ID` to target a different paid insyt.
