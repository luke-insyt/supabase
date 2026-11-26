#!/usr/bin/env python3
"""GET-486 B4 — insyt_reports, live on STAGING via PostgREST.

Needs the migration 20261126170000_get486_insyt_reports.sql applied on staging (it is, once the PR
merges into the supabase `staging` branch). The destructive half (user delete → reporter marker,
the D-9 trigger with and without B2's table) runs offline in get486_insyt_reports_test.ts and on a
branch in sql/legal_destructive.sql.

Checks (implementation.md B4 test list, feature.md §2.6):
  * open-duplicate indexes: a second open report by the same user / same email (any case) on the
    same Insyt is refused (23505); a resolved one frees the slot;
  * check constraints: unknown reason, a note over 1000, no reporter at all;
  * anon and a signed-in user can neither read nor write the table (RLS on, grants revoked).

Every row uses a `get486-report-<random>` slug and is deleted in teardown; the throwaway user is
deleted too.

Usage: SUPABASE_SERVICE_ROLE_KEY=... python3 supabase/tests/legal_reports_test.py
"""
import uuid
from datetime import datetime, timezone
from _legal_common import ANON, admin_user, call, check, delete_user, finish, settle, sign_in

tag = uuid.uuid4().hex[:10]
SLUG = f"get486-report-{tag}"
EMAIL = f"get486-reporter-{tag}@getinsyts.test"
user = None


def report(body, **kw):
    return call("POST", "/rest/v1/insyt_reports", {"insyt_id": SLUG, **body}, prefer="return=representation", **kw)


try:
    user = admin_user(EMAIL)
    check("throwaway reporter created", bool(user))

    print("open-duplicate indexes")
    c, r = report({"reporter_auth_user_id": user, "reason": "copied"})
    check("first signed-in report stored", c == 201 and isinstance(r, list) and len(r) == 1)
    first_id = r[0]["id"] if c == 201 else None
    c, r = report({"reporter_auth_user_id": user, "reason": "other"})
    check("second open report by the same user refused (23505)", c == 409 and "23505" in str(r))
    c, r = report({"reporter_email": f"Anon-{tag}@getinsyts.test", "reason": "other"})
    check("signed-out report with an email stored", c == 201)
    c, r = report({"reporter_email": f"anon-{tag}@GETINSYTS.test", "reason": "minor"})
    check("same email, other case, refused while open (23505)", c == 409 and "23505" in str(r))

    now = datetime.now(timezone.utc).isoformat()
    c, r = call("PATCH", f"/rest/v1/insyt_reports?id=eq.{first_id}",
                {"resolved_at": now, "resolution": "no_action", "resolution_reason": "not_a_violation"})
    check("resolve the first report", c in (200, 204))
    c, r = report({"reporter_auth_user_id": user, "reason": "other"})
    check("a resolved report frees the slot", c == 201)

    print("check constraints")
    c, r = report({"reporter_email": f"x-{tag}@getinsyts.test", "reason": "spam"})
    check("unknown reason rejected (23514)", c == 400 and "23514" in str(r))
    c, r = report({"reporter_email": f"y-{tag}@getinsyts.test", "reason": "other", "note": "x" * 1001})
    check("note over 1000 rejected (23514)", c == 400 and "23514" in str(r))
    c, r = report({"reason": "other"})
    check("no reporter at all rejected (23514)", c == 400 and "23514" in str(r))
    c, r = call("PATCH", f"/rest/v1/insyt_reports?insyt_id=eq.{SLUG}&resolved_at=is.null",
                {"resolved_at": now})
    check("resolved_at without a resolution rejected (23514)", c == 400 and "23514" in str(r))

    print("no client access")
    c, r = call("GET", f"/rest/v1/insyt_reports?select=id&insyt_id=eq.{SLUG}", apikey=ANON)
    check("anon cannot read", c in (401, 403) or r == [])
    c, r = report({"reporter_email": f"anon2-{tag}@getinsyts.test", "reason": "other"}, apikey=ANON)
    check("anon cannot insert", c in (401, 403))
    settle()
    tok = sign_in(EMAIL)
    check("throwaway user signed in", bool(tok))
    c, r = call("GET", f"/rest/v1/insyt_reports?select=id&insyt_id=eq.{SLUG}", apikey=ANON, token=tok)
    check("authenticated cannot read", c in (401, 403) or r == [])
    c, r = report({"reporter_auth_user_id": user, "reason": "minor"}, apikey=ANON, token=tok)
    check("authenticated cannot insert", c in (401, 403))
finally:
    call("DELETE", f"/rest/v1/insyt_reports?insyt_id=eq.{SLUG}")
    delete_user(user)
    finish()
