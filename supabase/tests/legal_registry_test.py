#!/usr/bin/env python3
"""GET-470 P2 — legal registry, live on STAGING through PostgREST (AC1.1–AC1.5, AC1.6 hash).

Read-mostly: it never inserts registry rows (they can't be deleted — the registry is
immutable by design). The destructive registry checks (update/delete raise) live in
sql/legal_destructive.sql (branch/local only) and get470_legal_registry_test.ts (PGlite).

Checks:
  * at most one current row per document_type; insyter_agreement has one (AC1.3);
  * every row has a type and a 64-hex sha256; insyter_agreement v1.0 carries the pinned hash
    and it equals sha256(served bytes of its url) (AC1.1, AC1.2, AC10.4) — likewise for every
    current row (P3 gate);
  * anon and a signed-in user can read but not write agreement_versions (AC1.5);
  * a signed-in user gets 42501 on every GET-470 RPC; the service role can call legal_current.

Usage: SUPABASE_SERVICE_ROLE_KEY=... python3 supabase/tests/legal_registry_test.py
"""
import uuid
from _legal_common import (ANON, admin_user, call, check, current_versions, delete_user, finish, rpc,
                           settle, sha256_of, sign_in)

V10_SHA = "673fb82af840b1e6d2ab16097ad973d35159bb840f1bc44e5bf256a9213c13a0"
EMAIL = f"get470-registry-{uuid.uuid4().hex[:8]}@getinsyts.test"
uid = None
try:
    print("REGISTRY SHAPE")
    c, rows = call("GET", "/rest/v1/agreement_versions?select=document_type,version,is_current,sha256,url")
    rows = rows if isinstance(rows, list) else []
    check("registry readable with the service key", c == 200 and len(rows) >= 1)
    current = [r for r in rows if r["is_current"]]
    types = [r["document_type"] for r in current]
    check("at most one current row per type (AC1.3)", len(types) == len(set(types)))
    check("insyter_agreement has a current row", "insyter_agreement" in types)
    check("every row has a document_type", all(r["document_type"] for r in rows))
    check("every row has a 64-hex sha256 (AC1.2)",
          all(isinstance(r["sha256"], str) and len(r["sha256"]) == 64 for r in rows))
    check("no v1.1 row (S0)", not any(r["version"] == "v1.1" and r["document_type"] == "insyter_agreement" for r in rows))
    v10 = next((r for r in rows if r["document_type"] == "insyter_agreement" and r["version"] == "v1.0"), None)
    check("insyter_agreement v1.0 carries the pinned hash", bool(v10) and v10["sha256"] == V10_SHA)
    if v10:
        check("v1.0 pinned hash = sha256(served file)", sha256_of(v10["url"]) == V10_SHA)
    for r in current:
        try:
            check(f"current {r['document_type']} {r['version']}: sha256 = served bytes", sha256_of(r["url"]) == r["sha256"])
        except Exception as e:
            check(f"current {r['document_type']} {r['version']}: file reachable ({e})", False)

    print("legal_current (service role)")
    cur = current_versions()
    check("legal_current returns exactly the current rows", sorted(cur) == sorted(types))

    print("GRANTS")
    c, r = call("GET", "/rest/v1/agreement_versions?select=version&limit=1", apikey=ANON)
    check("anon can read the registry", c == 200)
    probe = {"document_type": "privacy", "version": "get470-probe", "title": "x", "url": "x",
             "effective_date": "2026-01-01", "sha256": "a" * 64}
    c, r = call("POST", "/rest/v1/agreement_versions", probe, apikey=ANON)
    check("anon cannot insert into the registry (AC1.5)", c in (401, 403))

    uid = admin_user(EMAIL)
    settle()
    tok = sign_in(EMAIL)
    check("throwaway user signed in", bool(tok))
    c, r = call("POST", "/rest/v1/agreement_versions", probe, token=tok, apikey=ANON)
    check("authenticated cannot insert into the registry (AC1.5)", c in (401, 403))
    c, r = call("PATCH", "/rest/v1/agreement_versions?document_type=eq.insyter_agreement", {"is_current": False},
                token=tok, apikey=ANON)
    check("authenticated cannot update the registry (AC1.5)", c in (401, 403))

    for fn, args in [
        ("legal_current", {}),
        ("buyer_terms_status", {"p_user": uid}),
        ("record_terms_acceptance", {"p_user": uid, "p_email": None, "p_type": "insyter_agreement",
                                     "p_version": "v1.0", "p_context": "fixture"}),
        ("record_insyter_acceptance", {"p_user": uid, "p_email": None, "p_signature_name": "X", "p_version": "v1.0"}),
        ("anonymise_terms_acceptances", {"p_user": uid}),
        ("agreement_notices_claim", {"p_version": "v1.0", "p_user_ids": [uid]}),
        ("agreement_notices_record", {"p_user_id": uid, "p_version": "v1.0", "p_status": "sent", "p_error": None}),
    ]:
        c, r = rpc(fn, args, token=tok, apikey=ANON)
        code = r.get("code") if isinstance(r, dict) else None
        check(f"authenticated gets 42501 on {fn}", code == "42501" or c in (401, 403))
finally:
    print("TEARDOWN")
    delete_user(uid)
    finish()
