#!/usr/bin/env python3
"""GET-486 A2 — receipt_sends (dedupe for the n8n subscription receipt), live on STAGING via PostgREST.

Needs the migration 20261126130000_get486_receipt_sends.sql applied on staging (it is, once the PR
merges into the supabase `staging` branch).

Checks (implementation.md A2 test list, feature.md §2.2):
  * the n8n claim (POST, Prefer: resolution=ignore-duplicates,return=representation) returns the
    row the first time and [] the second time for the same session (AC1.1);
  * PATCH to 'sent' works; an unknown status or kind is rejected by the check constraints;
  * anon and a signed-in user can neither read nor write the table (RLS on, grants revoked).

Every row it writes uses a `cs_test_get486_<random>` session id and is deleted in teardown.

Usage: SUPABASE_SERVICE_ROLE_KEY=... python3 supabase/tests/legal_receipts_test.py
"""
import uuid
from datetime import datetime, timezone
from _legal_common import ANON, admin_user, call, check, delete_user, finish, settle, sign_in

tag = uuid.uuid4().hex[:10]
SESSION = f"cs_test_get486_{tag}"
EMAIL = f"get486-buyer-{tag}@getinsyts.test"
CLAIM = "resolution=ignore-duplicates,return=representation"
user = None


def claim(session, apikey=None, token=None):
    kw = {"prefer": CLAIM}
    if apikey:
        kw["apikey"] = apikey
    if token:
        kw["token"] = token
    return call("POST", "/rest/v1/receipt_sends",
                {"stripe_session_id": session, "kind": "subscription_confirmation"}, **kw)


try:
    print("claim (service role)")
    c1, r1 = claim(SESSION)
    check("first claim returns the new row", c1 in (200, 201) and isinstance(r1, list) and len(r1) == 1
          and r1[0].get("status") == "claimed")
    c2, r2 = claim(SESSION)
    check("second claim of the same session returns [] (AC1.1)", c2 in (200, 201) and r2 == [])

    c, r = call("PATCH", f"/rest/v1/receipt_sends?stripe_session_id=eq.{SESSION}",
                {"status": "sent", "sent_at": datetime.now(timezone.utc).isoformat()}, prefer="return=representation")
    check("mark sent", c == 200 and isinstance(r, list) and r and r[0]["status"] == "sent")
    c, r = call("PATCH", f"/rest/v1/receipt_sends?stripe_session_id=eq.{SESSION}", {"status": "bogus"})
    check("unknown status rejected (check constraint)", c == 400 and "23514" in str(r))
    c, r = call("POST", "/rest/v1/receipt_sends",
                {"stripe_session_id": SESSION + "_k", "kind": "one_off"})
    check("unknown kind rejected (check constraint)", c == 400 and "23514" in str(r))

    print("no client access")
    c, r = call("GET", "/rest/v1/receipt_sends?select=stripe_session_id&limit=1", apikey=ANON)
    check("anon cannot read", c in (401, 403) or r == [])
    c, r = claim(SESSION + "_anon", apikey=ANON)
    check("anon cannot claim", c in (401, 403))

    user = admin_user(EMAIL)
    settle()
    tok = sign_in(EMAIL)
    check("throwaway user signed in", bool(tok))
    c, r = call("GET", "/rest/v1/receipt_sends?select=stripe_session_id", apikey=ANON, token=tok)
    check("authenticated cannot read", c in (401, 403) or r == [])
    c, r = claim(SESSION + "_auth", apikey=ANON, token=tok)
    check("authenticated cannot claim", c in (401, 403))
finally:
    call("DELETE", f"/rest/v1/receipt_sends?stripe_session_id=like.cs_test_get486_{tag}*")
    delete_user(user)
    finish()
