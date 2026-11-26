#!/usr/bin/env python3
"""GET-470 P2 — acceptance ledger + RPCs, live on STAGING through PostgREST.

Ledger rows written here are PERMANENT (append-only by design). Every row belongs to a
throwaway *@getinsyts.test user that is deleted in teardown, which anonymises the rows
(and the teardown asserts that, AC8.1). Purchase rows it creates are deleted.

Checks (implementation.md P2 test list):
  * record_terms_acceptance copies sha256 from the registry; ref_once makes a replay return
    null (AC4.4); a stale version raises terms_changed (AC2.3);
  * a user reads only their own ledger rows; anon reads none; nobody writes directly (AC2.2, AC2.5);
  * buyer_terms_status: one row, null-current types count as accepted;
  * purchase stamp triggers in both insert orders (needs current buyer_terms + withdrawal_waiver,
    i.e. after P3 — skipped before) and purchases_rn_session_once rejects a 2nd RN row;
  * notices claim/record per type (insyter_agreement + privacy for the same user + version);
  * submit_inquiry_proposal raises terms_changed on a stale p_agreement_version (D-8);
  * record_insyter_acceptance writes exactly ONE ledger row with signature_name, ip and UA
    (GET-486 AC2.6: the ledger is the only acceptance record);
  * deleting the user anonymises their rows (AC8.1).

Usage: SUPABASE_SERVICE_ROLE_KEY=... python3 supabase/tests/legal_ledger_test.py
"""
import uuid
from _legal_common import (ANON, admin_user, call, check, current_versions, delete_user, err_text, finish, rpc,
                           settle, sign_in)

tag = uuid.uuid4().hex[:8]
A_EMAIL, B_EMAIL = f"get470-ledger-a-{tag}@getinsyts.test", f"get470-ledger-b-{tag}@getinsyts.test"
a = b = None
sessions = []


def record(user, typ, version, ctx, ref=None, require=True, email=None):
    return rpc("record_terms_acceptance", {
        "p_user": user, "p_email": email, "p_type": typ, "p_version": version, "p_context": ctx,
        "p_reference": ref, "p_accepted_at": None, "p_ip": "203.0.113.70", "p_ua": "get470-ledger-test",
        "p_require_current": require})


try:
    print("SETUP")
    a, b = admin_user(A_EMAIL), admin_user(B_EMAIL)
    settle()
    check("created two throwaway users", bool(a and b))
    cur = current_versions()
    ins = cur.get("insyter_agreement")
    check("insyter_agreement is current", bool(ins))
    iv = ins["version"]

    print("record_terms_acceptance")
    c, rid = record(a, "insyter_agreement", iv, "fixture")
    check("row recorded (uuid returned)", c == 200 and isinstance(rid, str))
    c, rows = call("GET", f"/rest/v1/terms_acceptances?select=sha256,email,host:ip&id=eq.{rid}")
    row = rows[0] if isinstance(rows, list) and rows else {}
    check("sha256 copied from the registry", row.get("sha256") == ins["sha256"])
    check("email defaulted to the auth user's", row.get("email") == A_EMAIL)
    ref = f"get470-test-{tag}"
    c1, r1 = record(a, "insyter_agreement", iv, "proposal", ref=ref)
    c2, r2 = record(a, "insyter_agreement", iv, "proposal", ref=ref)
    check("ref_once: first insert returns an id", c1 == 200 and isinstance(r1, str))
    check("ref_once: replay returns null (AC4.4)", c2 == 200 and r2 is None)
    c, r = rpc("record_terms_acceptance", {"p_user": a, "p_email": None, "p_type": "insyter_agreement",
                                           "p_version": "v0-does-not-exist", "p_context": "fixture"})
    check("unknown version raises unknown_version", "unknown_version" in err_text(r))

    print("RLS")
    record(b, "insyter_agreement", iv, "fixture")
    tok = sign_in(A_EMAIL)
    c, rows = call("GET", "/rest/v1/terms_acceptances?select=auth_user_id", token=tok, apikey=ANON)
    check("user A sees only own rows (AC2.5)", c == 200 and rows and all(x["auth_user_id"] == a for x in rows))
    c, rows = call("GET", "/rest/v1/terms_acceptances?select=id", apikey=ANON)
    check("anon reads no ledger rows", c in (401, 403) or rows == [])
    c, r = call("POST", "/rest/v1/terms_acceptances", {"auth_user_id": a, "document_type": "insyter_agreement",
                "version": iv, "sha256": "a" * 64, "context": "fixture", "accepted_at": "2026-01-01T00:00:00Z"},
                token=tok, apikey=ANON)
    check("authenticated cannot insert ledger rows (AC2.2)", c in (401, 403))
    c, r = call("PATCH", f"/rest/v1/terms_acceptances?id=eq.{rid}", {"version": "v0"})
    check("service role cannot rewrite a ledger row (AC2.2)", c >= 400 and "append-only" in err_text(r))
    c, r = call("DELETE", f"/rest/v1/terms_acceptances?id=eq.{rid}")
    check("service role cannot delete a ledger row (AC2.2)", c >= 400 and "append-only" in err_text(r))

    print("buyer_terms_status")
    c, st = rpc("buyer_terms_status", {"p_user": a})
    st = st[0] if isinstance(st, list) and st else {}
    check("one row with the five fields", set(st) == {"buyer_terms", "privacy", "withdrawal_waiver",
                                                      "accepted_buyer_terms", "acknowledged_privacy"})
    check("null-current buyer_terms counts as accepted",
          st.get("buyer_terms") is not None or st.get("accepted_buyer_terms") is True)
    if st.get("buyer_terms"):
        check("fresh user has not accepted the current buyer_terms", st.get("accepted_buyer_terms") is False)

    print("PURCHASE STAMPS")
    bt, ww = cur.get("buyer_terms"), cur.get("withdrawal_waiver")
    if bt and ww:
        s1, s2 = f"cs_get470_{tag}_1", f"cs_get470_{tag}_2"
        sessions += [s1, s2]
        # order 1: ledger first, then the purchase row
        record(a, "buyer_terms", bt["version"], "checkout", ref=s1, require=False)
        record(a, "withdrawal_waiver", ww["version"], "checkout", ref=s1, require=False)
        call("POST", "/rest/v1/purchases", {"insyt_id": "get470-test", "buyer_email": A_EMAIL, "stripe_session_id": s1,
                                            "writer": "rn_webhook"})
        # order 2: purchase row first, then the ledger
        call("POST", "/rest/v1/purchases", {"insyt_id": "get470-test", "buyer_email": A_EMAIL, "stripe_session_id": s2,
                                            "stripe_blob": {"object": {"metadata": {}}}, "writer": "n8n"})
        record(a, "buyer_terms", bt["version"], "checkout", ref=s2, require=False)
        record(a, "withdrawal_waiver", ww["version"], "checkout", ref=s2, require=False)
        c, rows = call("GET", f"/rest/v1/purchases?select=stripe_session_id,terms_version,withdrawal_waiver_version,"
                              f"withdrawal_waiver_at&stripe_session_id=in.({s1},{s2})")
        check("both orders stamped (AC4.5)", isinstance(rows, list) and len(rows) == 2 and all(
            r["terms_version"] == bt["version"] and r["withdrawal_waiver_version"] == ww["version"]
            and r["withdrawal_waiver_at"] for r in rows))
        c, r = call("POST", "/rest/v1/purchases", {"insyt_id": "get470-test", "stripe_session_id": s1,
                                                   "writer": "rn_webhook"})
        check("purchases_rn_session_once rejects a 2nd RN row", c == 409)
    else:
        print("  SKIP purchase stamps: buyer_terms / withdrawal_waiver not current yet (before P3)")

    print("NOTICES per document type")
    c, r1 = rpc("agreement_notices_claim", {"p_version": "v1.0", "p_user_ids": [a]})
    c, r2 = rpc("agreement_notices_claim", {"p_version": "v1.0", "p_user_ids": [a], "p_document_type": "privacy"})
    c, r3 = rpc("agreement_notices_claim", {"p_version": "v1.0", "p_user_ids": [a], "p_document_type": "privacy"})
    check("insyter_agreement claim succeeds", r1 == [a])
    check("privacy claim for the same user + version succeeds", r2 == [a])
    check("second privacy claim returns nothing", r3 == [])
    c, r = rpc("agreement_notices_record", {"p_user_id": a, "p_version": "v1.0", "p_status": "sent", "p_error": None,
                                           "p_document_type": "privacy"})
    c, rows = call("GET", f"/rest/v1/agreement_notices?select=document_type,status&user_id=eq.{a}&order=document_type")
    check("record touched only the privacy row", rows == [{"document_type": "insyter_agreement", "status": "sending"},
                                                          {"document_type": "privacy", "status": "sent"}])

    print("submit_inquiry_proposal (D-8)")
    call("PATCH", f"/rest/v1/users?auth_user_id=eq.{a}", {"is_creator": True})
    c, r = rpc("submit_inquiry_proposal", {
        "p_inquiry_id": str(uuid.uuid4()), "p_insyter": a, "p_abstract": "x", "p_outline_html": "<p>x</p>",
        "p_read_time_min": 1, "p_price_cents": 100, "p_deliver_by": "2030-01-01", "p_daily_cap": 5,
        "p_ip": "203.0.113.70", "p_user_agent": "t", "p_agreement_version": "v0-stale"})
    check("stale p_agreement_version raises terms_changed", "terms_changed" in err_text(r))

    print("record_insyter_acceptance (GET-486 AC2.6)")
    q = f"/rest/v1/terms_acceptances?select=id&auth_user_id=eq.{a}&document_type=eq.insyter_agreement"
    c, before = call("GET", q)
    c, rid = rpc("record_insyter_acceptance", {"p_user": a, "p_email": None, "p_signature_name": "Ledger Tester",
                                              "p_version": iv, "p_ip": "203.0.113.71", "p_ua": "get486-ledger-test"})
    check("record_insyter_acceptance returns the ledger row id", c == 200 and isinstance(rid, str))
    c, after = call("GET", q)
    check("exactly one new ledger row", isinstance(before, list) and isinstance(after, list)
          and len(after) == len(before) + 1)
    c, rows = call("GET", f"/rest/v1/terms_acceptances?select=signature_name,host:ip,user_agent,context&id=eq.{rid}")
    row = rows[0] if isinstance(rows, list) and rows else {}
    check("row carries signature_name, IP and UA", row.get("signature_name") == "Ledger Tester"
          and str(row.get("host", "")).startswith("203.0.113.71") and row.get("user_agent") == "get486-ledger-test")
    check("context reaccept (the user already had an insyter_agreement row)", row.get("context") == "reaccept")
finally:
    print("TEARDOWN")
    for s in sessions:
        call("DELETE", f"/rest/v1/purchases?stripe_session_id=eq.{s}")
    delete_user(a)
    delete_user(b)
    if a:
        c, rows = call("GET", f"/rest/v1/terms_acceptances?select=email,ip,anonymised_at&auth_user_id=eq.{a}")
        check("deleting the user anonymised every ledger row (AC8.1)", isinstance(rows, list) and rows and all(
            r["email"] is None and r["ip"] is None and r["anonymised_at"] for r in rows))
    finish()
