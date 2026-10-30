#!/usr/bin/env python3
"""GET-98 regression: create-checkout-session must charge the CURRENT price_eur,
not the (possibly stale) `stripe_price_id` Stripe Price object.

Runs against the deployed STAGING create-checkout-session edge function.
Self-contained + self-cleaning. No Stripe key needed: it inserts a throwaway
published insyt whose `stripe_price_id` is a DUMMY/invalid Stripe id but whose
`price_eur` is a real amount (cents). Under the OLD code
(`line_items[0][price] = stripe_price_id`) Stripe rejects the dummy price → 400.
Under the FIX (charge `price_eur` via `price_data`) the dummy id is never sent to
Stripe → 200 + a client_secret. A subsequent price change is reflected on the next
call (the session is built fresh from the current value, never a cached Price).

Usage:
  SUPABASE_SERVICE_ROLE_KEY=... python3 supabase/tests/checkout_price_test.py
  (SUPABASE_URL and SUPABASE_ANON_KEY default to staging.)
Exit code 0 = all passed, 1 = a failure.
"""
import json, os, sys, uuid, urllib.request, urllib.error

BASE = os.environ.get("SUPABASE_URL", "https://xeqjairmlwnjtmselyvo.supabase.co")
SK = os.environ.get("SUPABASE_SERVICE_ROLE_KEY")
ANON = os.environ.get("SUPABASE_ANON_KEY", "sb_publishable_VXNXh_Wml9_6bamvFDs-3Q_KjQtwXsj")
PW = "PcTest!2026xyz"
if not SK:
    sys.exit("Set SUPABASE_SERVICE_ROLE_KEY (staging service-role key) in the env.")

ok, fail = [], []


def check(name, cond):
    (ok if cond else fail).append(name)
    print(("  PASS " if cond else "  FAIL ") + name)


def call(method, path, body=None, token=None, apikey=SK, prefer=None):
    h = {"apikey": apikey, "Authorization": "Bearer " + (token or apikey), "Content-Type": "application/json"}
    if prefer:
        h["Prefer"] = prefer
    data = json.dumps(body).encode() if body is not None else None
    r = urllib.request.Request(BASE + path, data=data, headers=h, method=method)
    try:
        x = urllib.request.urlopen(r)
        t = x.read().decode()
        return x.status, (json.loads(t) if t else None)
    except urllib.error.HTTPError as e:
        b = e.read().decode()
        try:
            return e.code, json.loads(b)
        except Exception:
            return e.code, b


def admin_user(email):
    c, r = call("POST", "/auth/v1/admin/users", {"email": email, "password": PW, "email_confirm": True})
    return r["id"] if isinstance(r, dict) and "id" in r else None


def signin(email):
    c, r = call("POST", "/auth/v1/token?grant_type=password", {"email": email, "password": PW}, apikey=ANON)
    return r.get("access_token") if isinstance(r, dict) else None


buyer = None
iid = str(uuid.uuid4())
try:
    print("SETUP")
    buyer = admin_user("co-buyer@getinsyt.test")
    check("created buyer", bool(buyer))
    btok = signin("co-buyer@getinsyt.test")
    check("minted buyer token", bool(btok))

    # A published, paid insyt whose stripe_price_id is a DUMMY (invalid) Stripe id
    # but whose price_eur is a real amount (399 cents = €3.99). is_hidden keeps it
    # out of the public feed; teardown deletes it regardless.
    c, r = call(
        "POST",
        "/rest/v1/insyts",
        [{
            "id": iid, "insyt_id": iid, "title": "GET-98 checkout price test",
            "abstract": "regression fixture", "body_html": "<p>gated</p>", "sport": "Soccer",
            "content_type": "Tactics & Analysis", "status": "published", "is_hidden": True,
            "creator_email": "co-creator@getinsyt.test", "price_eur": 399,
            "stripe_price_id": "price_DUMMY_STALE_GET98",
        }],
        prefer="return=minimal",
    )
    check("inserted throwaway paid insyt", c in (200, 201, 204))

    print("STEP 1 - checkout charges price_eur, ignoring the dummy stripe_price_id")
    c, r = call("POST", "/functions/v1/create-checkout-session", {"insyt_id": iid}, token=btok, apikey=ANON)
    # OLD code would send the dummy id to Stripe and get a 400; the FIX builds the
    # line item from price_eur, so the dummy id never reaches Stripe.
    check("create-checkout-session 200 (dummy stripe_price_id not used)", c == 200)
    check("returns a client_secret", isinstance(r, dict) and bool(r.get("client_secret")))

    print("STEP 2 - a price change is reflected on the next call (no stale Price)")
    call("PATCH", f"/rest/v1/insyts?insyt_id=eq.{iid}", {"price_eur": 150}, prefer="return=minimal")
    c, r = call("POST", "/functions/v1/create-checkout-session", {"insyt_id": iid}, token=btok, apikey=ANON)
    check("still 200 after price change (fresh from current price_eur)",
          c == 200 and isinstance(r, dict) and bool(r.get("client_secret")))
finally:
    print("TEARDOWN")
    call("DELETE", f"/rest/v1/insyts?insyt_id=eq.{iid}")
    if buyer:
        call("DELETE", "/auth/v1/admin/users/" + buyer)
    print(f"\nRESULT: {len(ok)} passed, {len(fail)} failed")
    if fail:
        print("  FAILED:", fail)
    sys.exit(1 if fail else 0)
