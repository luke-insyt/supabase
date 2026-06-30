#!/usr/bin/env python3
"""GET-99 regression: accepting the Creator Agreement must NOT make the user a creator.

Decision A (Lukas, 2026-06-30): "when no display name is set we should not mark the
user as creator." Creator status (`is_creator`) now flips at PROFILE completion
(sync-creator-to-webflow, gated on a display name), not at terms acceptance. So
accept-agreement records the signed agreement but leaves `is_creator = false`.

Run against the deployed STAGING accept-agreement edge function. Self-contained +
self-cleaning. Under the OLD code accept-agreement set `is_creator = true`, so STEP 2
fails; under the FIX it stays false. (The profile-completion promotion + the
/creators/<id> page are exercised by the manual-test checklist on staging — that path
hits the live Webflow API, so it is not automated here.)

Usage: SUPABASE_SERVICE_ROLE_KEY=... python3 supabase/tests/agreement_no_auto_creator_test.py
"""
import json, os, sys, urllib.request, urllib.error

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


EMAIL = "ag99-user@getinsyt.test"
uid = None
try:
    print("SETUP")
    uid = admin_user(EMAIL)
    check("created test user", bool(uid))
    import time
    time.sleep(1)  # let the auth->public.users trigger create the row

    # Current agreement version.
    c, rows = call("GET", "/rest/v1/agreement_versions?select=version&is_current=eq.true")
    version = rows[0]["version"] if isinstance(rows, list) and rows else None
    check("found current agreement version", bool(version))

    # Baseline: a fresh user is not a creator.
    c, rows = call("GET", f"/rest/v1/users?select=is_creator&auth_user_id=eq.{uid}")
    check("baseline is_creator = false", isinstance(rows, list) and rows and rows[0]["is_creator"] in (False, None))

    print("STEP 1 - accept the agreement")
    c, r = call("POST", "/functions/v1/accept-agreement",
                {"auth_user_id": uid, "email": EMAIL, "signature_name": "AG Tester", "version": version},
                apikey=ANON)
    check("accept-agreement 200", c == 200)

    print("STEP 2 - agreement recorded, but is_creator STILL false (GET-99)")
    c, rows = call("GET", f"/rest/v1/users?select=is_creator,creator_terms_accepted_at,agreement_version&auth_user_id=eq.{uid}")
    row = rows[0] if isinstance(rows, list) and rows else {}
    check("is_creator stays false after accepting terms", row.get("is_creator") in (False, None))
    check("agreement was recorded (creator_terms_accepted_at set)", bool(row.get("creator_terms_accepted_at")))
    check("agreement_version stamped", row.get("agreement_version") == version)
finally:
    print("TEARDOWN")
    if uid:
        call("DELETE", f"/rest/v1/agreement_acceptances?auth_user_id=eq.{uid}")
        call("DELETE", "/auth/v1/admin/users/" + uid)
    print(f"\nRESULT: {len(ok)} passed, {len(fail)} failed")
    if fail:
        print("  FAILED:", fail)
    sys.exit(1 if fail else 0)
