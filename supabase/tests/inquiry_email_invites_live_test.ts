// GET-373 — the concurrency guarantees PGlite can't exercise (one connection), checked LIVE
// on the deployed STAGING project through PostgREST with the service-role key.
//
// Skipped unless SUPABASE_URL + SUPABASE_SERVICE_ROLE_KEY are set; refuses the prod ref.
// Load them from an env file, never inline the key in a command:
//
//   deno test -A --env-file=<path to getinsyts-native/server/.env> supabase/tests/inquiry_email_invites_live_test.ts
//
// Run after 20261120090000_get373_inquiry_email_invites.sql is applied to staging
// (implementation.md Rollout step 1). Self-cleaning: throwaway get373-*@getinsyts.test users
// and a draft inquiry, deleted in teardown (FK cascades remove the invites and targets).
import { assert, assertEquals } from 'jsr:@std/assert@1'

const URL_ = Deno.env.get('SUPABASE_URL') ?? ''
const KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
const PROD_REF = 'krapqgxrqprtajatxjzd'
const ignore = !URL_ || !KEY
if (URL_.includes(PROD_REF)) throw new Error('refusing to run against production')

const headers = { apikey: KEY, Authorization: `Bearer ${KEY}`, 'Content-Type': 'application/json' }

async function rest(path: string, init: RequestInit = {}) {
  const res = await fetch(`${URL_}${path}`, { ...init, headers: { ...headers, Prefer: 'return=representation', ...(init.headers ?? {}) } })
  const body = res.status === 204 ? null : await res.json()
  if (!res.ok) throw new Error(`${init.method ?? 'GET'} ${path} → ${res.status} ${JSON.stringify(body)}`)
  return body
}

async function makeUser(tag: string): Promise<string> {
  const email = `get373-${tag}-${crypto.randomUUID().slice(0, 8)}@getinsyts.test`
  const u = await rest('/auth/v1/admin/users', { method: 'POST', body: JSON.stringify({ email, email_confirm: true }) })
  return u.id
}

async function makeInquiry(requester: string): Promise<string> {
  const [row] = await rest('/rest/v1/inquiries', {
    method: 'POST',
    body: JSON.stringify({ requester_auth_user_id: requester, audience: 'specific' }), // draft by default
  })
  return row.id
}

const add = (inquiry: string, requester: string, emails: string[]) =>
  rest('/rest/v1/rpc/add_inquiry_email_invites', {
    method: 'POST',
    body: JSON.stringify({ p_inquiry: inquiry, p_requester: requester, p_emails: emails }),
  })

const addresses = (prefix: string, n: number) =>
  Array.from({ length: n }, (_, k) => `${prefix}-${k}-${crypto.randomUUID().slice(0, 6)}@getinsyts.test`)

Deno.test({
  name: 'live: parallel adds on one inquiry never push the total past 10',
  ignore,
  async fn() {
    const requester = await makeUser('req')
    const inquiry = await makeInquiry(requester)
    try {
      assertEquals((await add(inquiry, requester, addresses('seed', 8))).ok, true)
      // Two concurrent adds of 2 each at a total of 8: exactly one may succeed.
      const results = await Promise.all([add(inquiry, requester, addresses('a', 2)), add(inquiry, requester, addresses('b', 2))])
      assertEquals(results.filter((r) => r.ok).length, 1)
      assertEquals(results.filter((r) => r.refused === 'total').length, 1)
      const rows = await rest(`/rest/v1/inquiry_email_invites?inquiry_id=eq.${inquiry}&status=eq.invited&select=id`)
      assertEquals(rows.length, 10)
    } finally {
      await rest(`/rest/v1/inquiries?id=eq.${inquiry}`, { method: 'DELETE' })
      await rest(`/auth/v1/admin/users/${requester}`, { method: 'DELETE' })
    }
  },
})

Deno.test({
  name: 'live: parallel adds across inquiries never push one requester past 20 per 24 h',
  ignore,
  async fn() {
    const requester = await makeUser('cap')
    const inquiries = await Promise.all([1, 2, 3].map(() => makeInquiry(requester)))
    try {
      // 3 × 10 in parallel on different inquiries: the advisory lock lets exactly two through.
      const results = await Promise.all(inquiries.map((q, i) => add(q, requester, addresses(`c${i}`, 10))))
      assertEquals(results.filter((r) => r.ok).length, 2)
      assertEquals(results.filter((r) => r.refused === 'cap').length, 1)
      assert(results.find((r) => r.refused === 'cap')?.cap_oldest_at)
      const rows = await rest(`/rest/v1/inquiry_email_invites?requester_auth_user_id=eq.${requester}&select=id`)
      assertEquals(rows.length, 20)
    } finally {
      for (const q of inquiries) await rest(`/rest/v1/inquiries?id=eq.${q}`, { method: 'DELETE' })
      await rest(`/auth/v1/admin/users/${requester}`, { method: 'DELETE' })
    }
  },
})
