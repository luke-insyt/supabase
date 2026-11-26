#!/usr/bin/env python3
"""GET-486 B3 — insyter_deductions (deductions & holds ledger), live on STAGING via PostgREST.

Needs 20261126160000_get486_insyter_deductions.sql applied on staging (the supabase `staging` merge
applies it). The same rules run offline (incl. payout netting, which this script does NOT touch:
a payout row references users without ON DELETE and would make the throwaway undeletable) in
supabase/tests/get486_insyter_deductions_test.ts.

Checks (implementation.md B3 test list, feature.md §2.5):
  * record_insyter_deduction (service role): hold, release with the same amount, release twice →
    already_released, wrong amount → release_amount_mismatch, claim without rule_ref →
    rule_ref_required, reason > 500 → reason_invalid, correction > remaining → correction_exceeds;
  * insyter_deductions_for derives held / released / open and returns only the creator's rows;
  * immutability: PATCH / DELETE through PostgREST refused even with the service key;
  * anon and a signed-in user: 42501 on every RPC, and no row through RLS with a real token;
  * AC5.8: deleting the throwaway Insyter succeeds and the rows stay unchanged.

Rows are immutable by design, so the throwaway's rows stay on staging (tagged by the
get486-insyter-* user id); deleting the account is the intended end state, like the ledger tests.

Usage: SUPABASE_SERVICE_ROLE_KEY=... python3 supabase/tests/legal_deductions_test.py
"""
import uuid
from _legal_common import ANON, admin_user, call, check, delete_user, err_text, finish, rpc, settle, sign_in

tag = uuid.uuid4().hex[:10]
EMAIL = f"get486-insyter-{tag}@getinsyts.test"
OTHER = f"get486-member-{tag}@getinsyts.test"
ADMIN = "00000000-0000-4000-8000-000000000486"  # created_by only; the RPC doesn't look it up
user = other = None


def record(creator, kind, amount, reason="GET-486 B3 live test", rule_ref=None, related=None):
    return rpc("record_insyter_deduction", {
        "p_admin": ADMIN, "p_creator": creator, "p_kind": kind, "p_amount": amount,
        "p_insyt": None, "p_purchase": None, "p_invoice": None, "p_reason": reason,
        "p_rule_ref": rule_ref, "p_related": related,
    })


def rows_for(creator):
    c, r = rpc("insyter_deductions_for", {"p_creator": creator})
    return r if c == 200 and isinstance(r, list) else []


try:
    user = admin_user(EMAIL)
    other = admin_user(OTHER)
    settle()
    check("throwaways created", bool(user and other))

    print("record + derived status")
    c, hold = record(user, "hold", 900, "Claim open on this Insyt")
    check("hold recorded", c == 200 and isinstance(hold, str))
    c, r = record(user, "hold_released", 800, related=hold)
    check("release with a different amount → release_amount_mismatch", c == 400 and "release_amount_mismatch" in err_text(r))
    c, rel = record(user, "hold_released", 900, "Claim dropped", related=hold)
    check("release with the same amount", c == 200 and isinstance(rel, str))
    c, r = record(user, "hold_released", 900, related=hold)
    check("second release → already_released", c == 400 and "already_released" in err_text(r))
    c, r = record(user, "claim", 100)
    check("claim without rule_ref → rule_ref_required", c == 400 and "rule_ref_required" in err_text(r))
    c, r = record(user, "hold", 100, reason="x" * 501)
    check("reason > 500 chars → reason_invalid", c == 400 and "reason_invalid" in err_text(r))
    c, claim = record(user, "claim", 300, "Image rights claim", rule_ref="Content & Image Rules §2")
    check("claim with rule_ref", c == 200 and isinstance(claim, str))
    c, r = record(user, "correction", 301, related=claim)
    check("correction > remaining → correction_exceeds", c == 400 and "correction_exceeds" in err_text(r))
    c, corr = record(user, "correction", 100, "Partly wrong", related=claim)
    check("correction ≤ remaining", c == 200 and isinstance(corr, str))
    c, r = record(other, "hold_released", 900, related=hold)
    check("another creator can't release the hold → related_invalid", c == 400 and "related_invalid" in err_text(r))

    rows = {x["id"]: x for x in rows_for(user)}
    check("4 rows for the Insyter", len(rows) == 4)
    check("hold → released", rows.get(hold, {}).get("status") == "released")
    check("release row → released", rows.get(rel, {}).get("status") == "released")
    check("claim → open", rows.get(claim, {}).get("status") == "open")
    check("rule_ref kept", rows.get(claim, {}).get("rule_ref") == "Content & Image Rules §2")
    check("another creator sees none of them", rows_for(other) == [])

    print("immutable, even for the service key")
    c, r = call("PATCH", f"/rest/v1/insyter_deductions?id=eq.{claim}", {"reason": "changed"})
    check("PATCH refused", c in (401, 403) or "42501" in err_text(r))
    c, r = call("DELETE", f"/rest/v1/insyter_deductions?id=eq.{claim}")
    check("DELETE refused", c in (401, 403) or "42501" in err_text(r))
    c, r = call("GET", f"/rest/v1/insyter_deductions?id=eq.{claim}&select=reason")
    check("row unchanged", c == 200 and r and r[0]["reason"] == "Image rights claim")

    print("no client access")
    tok = sign_in(EMAIL)
    check("Insyter signed in", bool(tok))
    for fn, args in [
        ("record_insyter_deduction", {"p_admin": user, "p_creator": user, "p_kind": "hold", "p_amount": 1,
                                       "p_insyt": None, "p_purchase": None, "p_invoice": None,
                                       "p_reason": "x", "p_rule_ref": None, "p_related": None}),
        ("insyter_deductions_for", {"p_creator": user}),
        ("create_payout_with_settlement", {"p_creator": user, "p_amount": 0, "p_receipt": None,
                                            "p_paid_by": "x", "p_items": [], "p_deduction_ids": []}),
    ]:
        c, r = rpc(fn, args, token=tok, apikey=ANON)
        check(f"authenticated → 42501 on {fn}", c in (401, 403) and "42501" in err_text(r))
        c, r = rpc(fn, args, apikey=ANON)
        check(f"anon refused on {fn}", c in (401, 403))
    c, r = call("GET", f"/rest/v1/insyter_deductions?creator_auth_user_id=eq.{user}&select=id", apikey=ANON, token=tok)
    check("own rows not readable through RLS with a real token", c in (401, 403) or r == [])

    print("AC5.8: account delete keeps the rows")
    before = sorted((x["id"], x["status"], x["amount_cents"]) for x in rows_for(user))
    c, _ = call("DELETE", "/auth/v1/admin/users/" + user)
    check("auth delete of the Insyter succeeds", c == 200)
    deleted = user
    user = None
    after = sorted((x["id"], x["status"], x["amount_cents"]) for x in rows_for(deleted))
    check("rows unchanged after the delete", before == after and len(after) == 4)
finally:
    delete_user(user)
    delete_user(other)
    finish()
