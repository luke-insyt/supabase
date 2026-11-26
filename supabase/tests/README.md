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

## insyt_search_reader_test.ts — GET-340: Player search never sees paid insyt content

Runs the two GET-340 migrations (`20261017220908_get340_insyt_search_reader`,
`20261018114553_get340_insyt_reviews`) on a **real Postgres in-process** (PGlite, no Docker,
no network, no secrets) over a minimal stand-in of the tables they touch, and asserts the wall:
the reader role can read no table or view; anon/authenticated can't call `match` / `by_ids`;
only the free-field allow-list leaves (never a `GET340_PAID_*` marker); eligibility + dedupe;
exact-phrase player matching first (never the Insyter's name, never a prefix); tsquery operators
can't break or widen a query; the definer functions the reader can run are exactly the two;
both migrations idempotent; the area-save function keeps its old call shape; reviews take
`insyt` (±1). 10 tests, ~3 s. Verified 2026-10-18 that adding a table grant to the reader
fails it.

```bash
deno test -A supabase/tests/insyt_search_reader_test.ts
# no local Deno:
npx -y deno@2.1.4 test -A supabase/tests/insyt_search_reader_test.ts
```
In the side-by-side checkout (this repo nested inside `webflow-code`), prefix
`DENO_NO_PACKAGE_JSON=1` so Deno ignores webflow-code's `package.json` / `node_modules`.

## insyt_search_reader_live_test.ts — the same wall, live on staging

Connects as the real `insyt_search_reader` through the Supavisor pooler and checks: refused on
`insyts` (incl. `title`), `insyt_attachments`, `users`, the view, `storage.objects`; `match` /
`by_ids` return exactly the allow-list with no `GET340_PAID_*` marker (uses the `get340-test`
fixtures); and the SECURITY DEFINER functions the reader can execute are exactly the **reviewed
list pinned in the file** — a new one fails until it's reviewed and added. Skipped (ignored)
without `INSYT_SEARCH_DB_URL`; refuses to run against the prod ref. Load the URL from an env
file, never inline (it holds the reader's password):

```bash
DENO_NO_PACKAGE_JSON=1 npx -y deno@2.1.4 test -A \
  --env-file=../getinsyts-native/server/.env supabase/tests/insyt_search_reader_live_test.ts
```
Re-run after any migration touching `insyts`, `users`, storage or `insyt_search`, and before
a release. 3 tests; green on staging 2026-10-18.

## inquiry_email_invites_test.ts + inquiry_email_invites_live_test.ts — GET-373 email invites

**Offline (PGlite, no network/secrets):** runs `20261120090000_get373_inquiry_email_invites.sql`
on a stand-in (with Supabase's default privileges, so the server-only revokes are really tested)
and asserts the add/claim RPC refusals, the redefined `inquiry_targets_cap` trigger, the rolling
24 h cap, the account-deletion cascade and the grants. 18 tests.

```bash
DENO_NO_PACKAGE_JSON=1 deno test -A supabase/tests/inquiry_email_invites_test.ts
```

**Live (staging only, after the migration is applied):** PGlite is a single connection, so the
row-lock / advisory-lock serialisation is proven here with real parallel RPC calls — two adds
racing at a total of 8 (exactly one wins) and three adds racing the 20/24 h cap (exactly two win).
Skipped unless `SUPABASE_URL` + `SUPABASE_SERVICE_ROLE_KEY` are set; refuses the prod ref;
self-cleaning (`get373-*@getinsyts.test` throwaways).

```bash
deno test -A --env-file=<path to getinsyts-native/server/.env> supabase/tests/inquiry_email_invites_live_test.ts
```

## get459_open_mode_test.ts — GET-459 "Open for everyone" migration

**Offline (PGlite, no network/secrets):** runs `20261121120000_get459_open_mode.sql` on a stand-in
with pre-existing rows and asserts the `access_mode` backfill (drafts too, `updated_at` untouched),
the `released_at` backfill (public inquiry insyts only, GET-73's `updated_at` untouched), every
branch of the `inquiries_access_mode_sync` trigger, the two checks, `release_inquiry_insyt`
(€0 for open, Insyter's price for timed, second call → no row, unpublished / public / non-inquiry
rows skipped), the service_role-only EXECUTE grant, the partial index, and that the file is
idempotent. 12 tests.

```bash
DENO_NO_PACKAGE_JSON=1 deno test -A supabase/tests/get459_open_mode_test.ts
```

The edge-fn side (mode-aware `privateUntil`, `release_price_cents`, the released-open price lock)
is unit-tested in `supabase/functions/submit-create-insyt/inquiry_test.ts`:

```bash
DENO_NO_PACKAGE_JSON=1 deno test --allow-env supabase/functions/submit-create-insyt/
```

## GET-470 — legal registry + acceptance ledger

**Offline (PGlite, no network/secrets):** `get470_legal_registry_test.ts` runs the three GET-470
migrations (`20261125120000` P0, `20261125121000` migration A, `20261125122000` migration B) on a
stand-in built from the real GET-330 / GET-357 / GET-332 §1 migrations and asserts the v1.1 guard,
per-type uniqueness + one current per type, registry immutability (incl. delete/truncate), API
grants, every RPC (sha copy, `terms_changed`, `ref_once`, null-current), append-only ledger +
anonymise path, user deletion anonymising legacy + ledger rows, purchase stamps in both insert
orders (GET-332 anonymity still green), `purchases_rn_session_once`, notices per type,
`submit_inquiry_proposal` (D-8) and the legacy backfill. Since GET-486 A1 it also applies
`20261126120000_get470_drop_legacy_acceptances.sql` (every current-state test runs on the
ledger-only schema) and checks the drop's guard (unmatched legacy row → raises, nothing dropped),
the anonymising of pre-GET-470 orphan twins, the tokenised ↔ anonymised pair passing, and that
`prod-ops/get486-legacy-precheck.sql` agrees with the guard. 27 tests, ~9 s.

```bash
DENO_NO_PACKAGE_JSON=1 npx -y deno@2.1.4 test -A supabase/tests/get470_legal_registry_test.ts
```

**Live on staging (PostgREST, after migration B is applied):** `legal_registry_test.py`
(read-mostly: shape, pinned v1.0 hash = served bytes, grants, 42501 on every RPC) and
`legal_ledger_test.py` (writes PERMANENT ledger rows for throwaway users, deleted — i.e.
anonymised — in teardown). Both refuse the prod ref.

```bash
SUPABASE_SERVICE_ROLE_KEY=<staging service-role key> python3 supabase/tests/legal_registry_test.py
SUPABASE_SERVICE_ROLE_KEY=<staging service-role key> python3 supabase/tests/legal_ledger_test.py
```

**psql:** `sql/legal_v11_guard.sql` (read-only; safe on prod for the P0 dry-run) and
`sql/legal_destructive.sql` (Supabase branch / local DB only — refuses the staging and prod hosts;
rolled back at the end).
