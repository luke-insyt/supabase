#!/usr/bin/env python3
"""Integration test for the creator price-change feature (§13), run against the
deployed staging edge functions. Self-contained and self-cleaning.

Covers the paths that do NOT mutate a real Stripe subscription (so no Stripe test
key is needed — the edge functions hold their own key server-side):
  - set-subscription-price: initial price + a raise (Stripe Price create, the
    subscription_prices mirror, the subscription_price_changes log, pending stamp)
  - confirm-subscription-price-change: a Decline with keep_old fallback + the
    subscription_price_change_results outcome
  - creator_subscription_revenue RPC aggregates
  - RLS isolation (a subscriber cannot read the creator's change rows)

NOT covered here (need a REAL Stripe test subscription — see README):
  accept (Stripe item swap), decline+cancel, the deadline sweep's decrease/cancel.

Usage:
  SUPABASE_SERVICE_ROLE_KEY=... python3 supabase/tests/price_change_test.py
  (SUPABASE_URL and SUPABASE_ANON_KEY default to staging.)
Exit code 0 = all passed, 1 = a failure. Creates throwaway *@getinsyt.test users
and deletes them (+ the creator's seed rows) in teardown. It DOES create real
Stripe TEST-mode Price objects via the function; those are harmless and not cleaned.
"""
import json, os, sys, time, urllib.request, urllib.error

BASE = os.environ.get("SUPABASE_URL", "https://xeqjairmlwnjtmselyvo.supabase.co")
SK   = os.environ.get("SUPABASE_SERVICE_ROLE_KEY")
ANON = os.environ.get("SUPABASE_ANON_KEY", "sb_publishable_VXNXh_Wml9_6bamvFDs-3Q_KjQtwXsj")
PW   = "PcTest!2026xyz"
if not SK:
    sys.exit("Set SUPABASE_SERVICE_ROLE_KEY (staging service-role key) in the env.")

ok, fail = [], []
def check(name, cond):
    (ok if cond else fail).append(name)
    print(("  PASS " if cond else "  FAIL ") + name)

def call(method, path, body=None, token=None, apikey=SK, prefer=None):
    h = {"apikey": apikey, "Authorization": "Bearer " + (token or apikey), "Content-Type": "application/json"}
    if prefer: h["Prefer"] = prefer
    data = json.dumps(body).encode() if body is not None else None
    r = urllib.request.Request(BASE + path, data=data, headers=h, method=method)
    try:
        x = urllib.request.urlopen(r); t = x.read().decode()
        return x.status, (json.loads(t) if t else None)
    except urllib.error.HTTPError as e:
        b = e.read().decode()
        try: return e.code, json.loads(b)
        except Exception: return e.code, b

def admin_user(email):
    c, r = call("POST", "/auth/v1/admin/users", {"email": email, "password": PW, "email_confirm": True})
    return r["id"] if isinstance(r, dict) and "id" in r else None
def signin(email):
    c, r = call("POST", "/auth/v1/token?grant_type=password", {"email": email, "password": PW}, apikey=ANON)
    return r.get("access_token") if isinstance(r, dict) else None

creator = subscriber = None
try:
    print("SETUP")
    creator = admin_user("pc-creator@getinsyt.test")
    subscriber = admin_user("pc-subscriber@getinsyt.test")
    check("created test users", bool(creator and subscriber))
    time.sleep(1)  # let the auth->public.users trigger create the row
    call("PATCH", f"/rest/v1/users?auth_user_id=eq.{creator}", {"is_creator": True, "display_name": "PC Creator"}, prefer="return=minimal")
    ctok = signin("pc-creator@getinsyt.test"); stok = signin("pc-subscriber@getinsyt.test")
    check("minted creator+subscriber tokens", bool(ctok and stok))

    print("STEP 1 - creator sets initial price EUR5")
    c, r = call("POST", "/functions/v1/set-subscription-price", {"amount_cents": 500, "currency": "eur", "trial_days": 0}, token=ctok, apikey=ANON)
    check("set-subscription-price 200", c == 200)
    check("active mirror price = 500", any(p["amount_cents"] == 500 and p["is_active"] for p in
        (call("GET", f"/rest/v1/subscription_prices?creator_id=eq.{creator}&select=amount_cents,is_active")[1] or [])))

    print("STEP 2 - seed an active subscriber row (fake stripe id)")
    call("POST", "/rest/v1/creator_subscriptions", [{"subscriber_id": subscriber, "creator_id": creator,
        "stripe_subscription_id": f"sub_pctest_{creator[:8]}", "stripe_customer_id": "cus_pctest", "status": "active",
        "amount_cents": 500, "currency": "eur"}], prefer="return=minimal")
    subrow = call("GET", f"/rest/v1/creator_subscriptions?creator_id=eq.{creator}&select=id,amount_cents")[1]
    check("subscriber row created", bool(subrow))
    sub_id = subrow[0]["id"]

    print("STEP 3 - creator raises price EUR5->EUR7 (increase, keep_old, 30d)")
    c, r = call("POST", "/functions/v1/set-subscription-price",
        {"amount_cents": 700, "currency": "eur", "trial_days": 0, "fallback": "keep_old", "notice_days": 30}, token=ctok, apikey=ANON)
    check("raise 200", c == 200)
    check("change_kind increase", isinstance(r, dict) and r.get("change_kind") == "increase")
    check("affected_subscribers 1", isinstance(r, dict) and r.get("affected_subscribers") == 1)
    row = call("GET", f"/rest/v1/creator_subscriptions?id=eq.{sub_id}&select=pending_status,pending_kind,pending_amount_cents,pending_change_id")[1][0]
    check("pending stamped on sub", row.get("pending_status") == "pending" and row.get("pending_amount_cents") == 700)
    check("pending_change_id linked", bool(row.get("pending_change_id")))
    ch = call("GET", f"/rest/v1/subscription_price_changes?creator_id=eq.{creator}&select=id,from_amount_cents,to_amount_cents,kind,affected_count")[1]
    check("change row 500->700 affected=1", bool(ch) and ch[0]["from_amount_cents"] == 500 and ch[0]["to_amount_cents"] == 700 and ch[0]["affected_count"] == 1)

    print("STEP 4 - subscriber DECLINES (fallback keep_old, no Stripe call)")
    c, r = call("POST", "/functions/v1/confirm-subscription-price-change", {"subscription_id": sub_id, "action": "decline"}, token=stok, apikey=ANON)
    check("decline 200", c == 200)
    row = call("GET", f"/rest/v1/creator_subscriptions?id=eq.{sub_id}&select=pending_status,amount_cents")[1][0]
    check("pending cleared", row.get("pending_status") is None)
    check("sub stays on EUR5 (kept old)", row.get("amount_cents") == 500)
    res = call("GET", f"/rest/v1/subscription_price_change_results?change_id=eq.{ch[0]['id']}&select=outcome")[1]
    check("outcome recorded = kept_old", bool(res) and res[0]["outcome"] == "kept_old")

    print("STEP 5 - revenue RPC aggregates")
    c, rev = call("POST", "/rest/v1/rpc/creator_subscription_revenue", {}, token=ctok, apikey=ANON)
    check("RPC 200", c == 200)
    check("active_count=1", isinstance(rev, dict) and rev.get("active_count") == 1)
    check("mrr_cents=500", isinstance(rev, dict) and rev.get("mrr_cents") == 500)
    check("12 month buckets", isinstance(rev, dict) and len(rev.get("months", [])) == 12)

    print("STEP 6 - RLS: subscriber cannot read the creator's change rows")
    c, leaked = call("GET", f"/rest/v1/subscription_price_changes?creator_id=eq.{creator}&select=id", token=stok, apikey=ANON)
    check("subscriber sees 0 change rows (RLS)", isinstance(leaked, list) and len(leaked) == 0)
finally:
    print("TEARDOWN")
    if creator:
        call("DELETE", f"/rest/v1/subscription_price_changes?creator_id=eq.{creator}")
        call("DELETE", f"/rest/v1/subscription_prices?creator_id=eq.{creator}")
    for uid in [creator, subscriber]:
        if uid: call("DELETE", "/auth/v1/admin/users/" + uid)
    print(f"\nRESULT: {len(ok)} passed, {len(fail)} failed")
    if fail: print("  FAILED:", fail)
    sys.exit(1 if fail else 0)
