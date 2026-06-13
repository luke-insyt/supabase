#!/usr/bin/env python3
"""Integration test: an active subscriber can rate a creator's paid insyt.

Verifies the submit-insyt-rating eligibility change (2026-06-10): paid insyts are
rateable by a purchaser OR an active subscriber to the creator. Drives the
deployed staging function; self-cleaning.

Usage:
  SUPABASE_SERVICE_ROLE_KEY=<staging service-role key> \
    python3 supabase/tests/rating_subscriber_test.py
  Optional: RATING_CREATOR_ID + RATING_INSYT_ID to target a specific paid insyt
  (defaults below point at the "Fit is the Hit" insyt by "2W Test" on staging).
Exit 0 = all passed.
"""
import json, os, sys, time, urllib.request, urllib.error

BASE = os.environ.get("SUPABASE_URL", "https://xeqjairmlwnjtmselyvo.supabase.co")
SK   = os.environ.get("SUPABASE_SERVICE_ROLE_KEY")
ANON = os.environ.get("SUPABASE_ANON_KEY", "sb_publishable_VXNXh_Wml9_6bamvFDs-3Q_KjQtwXsj")
CREATOR = os.environ.get("RATING_CREATOR_ID", "15e1b028-08dc-48a0-aa1a-006d521ab57e")  # "2W Test"
INSYT   = os.environ.get("RATING_INSYT_ID", "2613295a-fcf7-4733-9f27-1bb0ba9ee441")    # paid insyt by that creator
PW = "RateTest!2026"
if not SK:
    sys.exit("Set SUPABASE_SERVICE_ROLE_KEY (staging service-role key) in the env.")

ok, fail = [], []
def check(name, cond):
    (ok if cond else fail).append(name)
    print(("  PASS " if cond else "  FAIL ") + name)

def call(m, p, b=None, tok=None, ak=SK, pref=None):
    h = {"apikey": ak, "Authorization": "Bearer " + (tok or ak), "Content-Type": "application/json"}
    if pref: h["Prefer"] = pref
    d = json.dumps(b).encode() if b is not None else None
    r = urllib.request.Request(BASE + p, data=d, headers=h, method=m)
    try:
        x = urllib.request.urlopen(r); t = x.read().decode()
        return x.status, (json.loads(t) if t else None)
    except urllib.error.HTTPError as e:
        bb = e.read().decode()
        try: return e.code, json.loads(bb)
        except Exception: return e.code, bb

uid = None
try:
    uid = call("POST", "/auth/v1/admin/users", {"email": "rate-sub-test@getinsyt.test", "password": PW, "email_confirm": True})[1]["id"]
    check("test user created", bool(uid))
    time.sleep(1)
    tok = call("POST", "/auth/v1/token?grant_type=password", {"email": "rate-sub-test@getinsyt.test", "password": PW}, ak=ANON)[1]["access_token"]

    print("BEFORE subscribing — rate the paid insyt (expect 403)")
    cb, rb = call("POST", "/functions/v1/submit-insyt-rating", {"insyt_id": INSYT, "rating": 5}, tok=tok, ak=ANON)
    check("403 not_eligible before sub", cb == 403 and isinstance(rb, dict) and rb.get("reason") == "purchase_or_subscription_required")

    print("seed an active subscription to the creator")
    call("POST", "/rest/v1/creator_subscriptions", [{"subscriber_id": uid, "creator_id": CREATOR,
        "stripe_subscription_id": "sub_rate_test", "stripe_customer_id": "cus_rate_test", "status": "active",
        "amount_cents": 1500, "currency": "eur", "current_period_end": "2026-07-10T00:00:00Z"}], pref="return=minimal")

    print("AFTER subscribing — rate the paid insyt (expect 200)")
    ca, ra = call("POST", "/functions/v1/submit-insyt-rating", {"insyt_id": INSYT, "rating": 5}, tok=tok, ak=ANON)
    check("200 after sub", ca == 200 and isinstance(ra, dict) and ra.get("your_rating") == 5)
    c, row = call("GET", f"/rest/v1/insyt_ratings?user_id=eq.{uid}&select=rating", tok=tok, ak=ANON)
    check("rating row recorded", isinstance(row, list) and len(row) == 1 and float(row[0]["rating"]) == 5.0)
finally:
    if uid:
        call("DELETE", "/auth/v1/admin/users/" + uid)  # cascades the sub + rating; aggregate trigger recomputes
    print(f"\nRESULT: {len(ok)} passed, {len(fail)} failed", ("- " + str(fail)) if fail else "")
    sys.exit(1 if fail else 0)
