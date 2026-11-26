#!/usr/bin/env python3
"""GET-486 B2 — Content & Image Rules confirmations, live on STAGING via PostgREST.

Needs 20261126180000_get486_content_rules.sql applied on staging (the supabase `staging` merge
does that). Works both before and after content_rules is made current:
  * always: content_rules_tick_ids() literal (D-3); `authenticated` and anon get 42501 on every
    new RPC; authenticated can't insert a confirmation; insyts.content_rev isn't readable by
    the API roles; rules_confirmation_needed of an unknown row is false;
  * no current content_rules (null-current): record → rules_not_live, needed → false;
  * current content_rules: record (publish by correlation_id) → one row with server time, sorted
    ticks, IP/UA; rules_changed (stale version) and rules_ticks_invalid; not_owner for a
    stranger's draft; needed → true for a never-confirmed row, false after an unhide
    confirmation at its content_rev, true again after content_rev moves (owner filter: the
    stranger's rows never count); service-role DELETE/PATCH of a confirmation is refused
    (append-only); the user can read their own rows only (RLS); deleting the user keeps the
    rows and nulls IP/UA (AC3.9).

Writes: throwaway get486-insyter-* users and one draft insyts row (deleted in teardown).
Confirmation rows are PERMANENT (append-only by design) and are anonymised by the user delete.

Usage: SUPABASE_SERVICE_ROLE_KEY=... python3 supabase/tests/legal_rules_test.py
"""
import uuid
from _legal_common import ANON, admin_user, call, check, current_versions, delete_user, err_text, finish, rpc, settle, sign_in

tag = uuid.uuid4().hex[:10]
OWNER_EMAIL = f"get486-insyter-{tag}-1@getinsyts.test"
OTHER_EMAIL = f"get486-insyter-{tag}-2@getinsyts.test"
TICKS = ["own_work", "opinions", "no_confidential", "minors_initials", "images_licensed"]
SORTED = sorted(TICKS)
owner = other = None
row_id = None


def record(user, corr=None, row=None, version="v1.0", ticks=TICKS, ctx="publish", rev=0, token=None, apikey=None):
    kw = {}
    if token:
        kw["token"] = token
    if apikey:
        kw["apikey"] = apikey
    return rpc("record_rules_confirmation", {
        "p_user": user, "p_correlation": corr, "p_row_id": row, "p_version": version, "p_ticks": ticks,
        "p_context": ctx, "p_rev": rev, "p_ip": "203.0.113.42", "p_ua": "get486-legal-rules-test",
    }, **kw)


def needed(row):
    c, r = rpc("rules_confirmation_needed", {"p_row_id": row})
    return r if c == 200 else ("error", c, r)


try:
    print("shape")
    c, r = rpc("content_rules_tick_ids")
    check("content_rules_tick_ids() = the sorted literal (D-3)", c == 200 and r == SORTED)
    check("needed(unknown row) = false", needed(str(uuid.uuid4())) is False)

    owner = admin_user(OWNER_EMAIL)
    other = admin_user(OTHER_EMAIL)
    settle()
    tok = sign_in(OWNER_EMAIL)
    check("throwaway users signed in", bool(owner and other and tok))

    print("grants")
    for fn, args in [
        ("content_rules_tick_ids", {}),
        ("rules_confirmation_needed", {"p_row_id": str(uuid.uuid4())}),
        ("get486_insyt_owner", {"p_row_id": str(uuid.uuid4())}),
        ("record_rules_confirmation", {"p_user": owner, "p_correlation": str(uuid.uuid4()), "p_row_id": None,
                                       "p_version": "v1.0", "p_ticks": TICKS, "p_context": "publish", "p_rev": 0,
                                       "p_ip": None, "p_ua": None}),
    ]:
        c, r = rpc(fn, args, token=tok, apikey=ANON)
        check(f"authenticated → 42501 on {fn}", c in (401, 403) and "42501" in err_text(r))
        c, r = rpc(fn, args, apikey=ANON)
        check(f"anon refused on {fn}", c in (401, 403))
    c, r = call("POST", "/rest/v1/insyt_rules_confirmations",
                {"correlation_id": str(uuid.uuid4()), "auth_user_id": owner, "rules_version": "v1.0",
                 "ticks": SORTED, "context": "publish", "content_rev": 0}, token=tok, apikey=ANON)
    check("authenticated can't insert a confirmation", c in (401, 403))
    c, r = call("GET", "/rest/v1/insyts?select=content_rev&limit=1", token=tok, apikey=ANON)
    check("insyts.content_rev not readable by the API roles", c in (400, 401, 403) and "42501" in err_text(r))

    # A draft row of the owner (the shape save_draft writes), to test owner checks and `needed`.
    corr = str(uuid.uuid4())
    c, r = call("POST", "/rest/v1/insyts", {
        "title": f"GET-486 rules test {tag}", "abstract": " ", "creator_email": OWNER_EMAIL,
        "creator_auth_user_id": owner, "status": "draft", "is_hidden": True, "correlation_id": corr,
        "sport": "soccer", "price_eur": 0,
    }, prefer="return=representation")
    row_id = r[0]["id"] if c in (200, 201) and isinstance(r, list) and r else None
    check("draft row created (service role)", bool(row_id))

    live = current_versions().get("content_rules")
    if not live:
        print("null-current (no content_rules version is current)")
        c, r = record(owner, corr=corr)
        check("record → rules_not_live", c == 400 and "rules_not_live" in err_text(r))
        check("needed → false (null-current safe)", needed(row_id) is False)
    else:
        v = live["version"]
        print(f"content_rules {v} is current")
        check("needed → true for a never-confirmed row", needed(row_id) is True)
        c, r = record(owner, corr=corr, version=v)
        check("publish confirmation recorded", c == 200 and isinstance(r, str))
        cid = r if c == 200 else None
        c, rows = call("GET", f"/rest/v1/insyt_rules_confirmations?id=eq.{cid}&select=*")
        row = rows[0] if c == 200 and rows else {}
        check("row: owner, version, sorted ticks, context, rev 0, IP, UA, server time (AC3.4)",
              row.get("auth_user_id") == owner and row.get("rules_version") == v and row.get("ticks") == SORTED
              and row.get("context") == "publish" and row.get("content_rev") == 0
              and row.get("ip") == "203.0.113.42" and row.get("user_agent") == "get486-legal-rules-test"
              and bool(row.get("confirmed_at")) and row.get("correlation_id") == corr)
        check("needed → false after the publish confirmation (rev 0)", needed(row_id) is False)

        c, r = record(owner, corr=corr, version="v0-stale")
        check("stale version → rules_changed", c == 400 and "rules_changed" in err_text(r))
        c, r = record(owner, corr=corr, version=v, ticks=TICKS[:4])
        check("4 ticks → rules_ticks_invalid", c == 400 and "rules_ticks_invalid" in err_text(r))
        c, r = record(other, corr=corr, version=v)
        check("stranger's correlation_id → not_owner", c == 400 and "not_owner" in err_text(r))
        c, r = record(other, row=row_id, version=v, ctx="unhide")
        check("stranger's row → not_owner", c == 400 and "not_owner" in err_text(r))

        call("PATCH", f"/rest/v1/insyts?id=eq.{row_id}", {"content_rev": 1})
        check("needed → true after content_rev moved", needed(row_id) is True)
        c, r = record(owner, row=row_id, version=v, ctx="unhide", rev=1)
        check("unhide confirmation at rev 1 recorded", c == 200)
        check("needed → false again", needed(row_id) is False)

        print("append-only + RLS")
        c, r = call("DELETE", f"/rest/v1/insyt_rules_confirmations?id=eq.{cid}")
        check("service-role DELETE refused (append-only)", c >= 400 and "append-only" in err_text(r))
        c, r = call("PATCH", f"/rest/v1/insyt_rules_confirmations?id=eq.{cid}", {"content_rev": 7})
        check("service-role PATCH refused (append-only)", c >= 400 and "append-only" in err_text(r))
        c, r = call("GET", "/rest/v1/insyt_rules_confirmations?select=auth_user_id", token=tok, apikey=ANON)
        check("the owner reads only their own rows", c == 200 and len(r) >= 2 and all(x["auth_user_id"] == owner for x in r))
        tok2 = sign_in(OTHER_EMAIL)
        c, r = call("GET", f"/rest/v1/insyt_rules_confirmations?select=id&correlation_id=eq.{corr}", token=tok2, apikey=ANON)
        check("another user sees none of them", c == 200 and r == [])

        print("account deletion (AC3.9)")
        delete_user(owner)
        owner_deleted = owner
        owner = None
        c, rows = call("GET", f"/rest/v1/insyt_rules_confirmations?auth_user_id=eq.{owner_deleted}&select=ip,user_agent,anonymised_at")
        check("rows kept, IP/UA nulled, anonymised_at set",
              c == 200 and len(rows) >= 2 and all(x["ip"] is None and x["user_agent"] is None and x["anonymised_at"] for x in rows))
finally:
    if row_id:
        call("DELETE", f"/rest/v1/insyts?id=eq.{row_id}")
    delete_user(owner)
    delete_user(other)
    finish()
