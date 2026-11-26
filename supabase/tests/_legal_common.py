"""GET-470 — shared helpers for legal_registry_test.py / legal_ledger_test.py (PostgREST, staging).

Same shape as agreement_no_auto_creator_test.py: urllib only, service-role key from the env,
throwaway *@getinsyts.test users created through the admin API and deleted in teardown.
Refuses the prod project ref.
"""
import hashlib, json, os, sys, time, urllib.error, urllib.request, uuid

BASE = os.environ.get("SUPABASE_URL", "https://xeqjairmlwnjtmselyvo.supabase.co")
SK = os.environ.get("SUPABASE_SERVICE_ROLE_KEY")
ANON = os.environ.get("SUPABASE_ANON_KEY", "sb_publishable_VXNXh_Wml9_6bamvFDs-3Q_KjQtwXsj")
PW = "Get470Test!" + uuid.uuid4().hex[:8]

if "krapqgxrqprtajatxjzd" in BASE:
    sys.exit("Refusing to run against the PROD project.")
if not SK:
    sys.exit("Set SUPABASE_SERVICE_ROLE_KEY (staging service-role key) in the env (load it from .env.local, never inline).")

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


def rpc(fn, args=None, token=None, apikey=SK):
    return call("POST", "/rest/v1/rpc/" + fn, args or {}, token=token, apikey=apikey)


def err_text(r):
    return json.dumps(r) if not isinstance(r, str) else r


def admin_user(email):
    c, r = call("POST", "/auth/v1/admin/users", {"email": email, "password": PW, "email_confirm": True})
    return r["id"] if isinstance(r, dict) and "id" in r else None


def sign_in(email):
    c, r = call("POST", "/auth/v1/token?grant_type=password", {"email": email, "password": PW}, apikey=ANON)
    return r.get("access_token") if isinstance(r, dict) else None


def delete_user(uid):
    if uid:
        call("DELETE", "/auth/v1/admin/users/" + uid)


def current_versions():
    c, rows = rpc("legal_current")
    return {r["document_type"]: r for r in rows} if isinstance(rows, list) else {}


def sha256_of(url):
    with urllib.request.urlopen(url) as x:
        return hashlib.sha256(x.read()).hexdigest()


def finish():
    print(f"\nRESULT: {len(ok)} passed, {len(fail)} failed")
    if fail:
        print("  FAILED:", fail)
    sys.exit(1 if fail else 0)


def settle():
    time.sleep(1)  # let the auth -> public.users trigger create the row
