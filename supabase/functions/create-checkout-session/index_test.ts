// GET-470 — the retired legacy one-off checkout answers 410 Gone (CORS kept).
// Run: DENO_NO_PACKAGE_JSON=1 deno test supabase/functions/create-checkout-session/
import { assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts'
import { handle } from './handler.ts'

const url = 'https://example.test/functions/v1/create-checkout-session'

Deno.test('POST → 410 { error: "use /api/checkout/insyt" } with CORS headers', async () => {
  const res = handle(new Request(url, {
    method: 'POST',
    headers: { Authorization: 'Bearer x', 'Content-Type': 'application/json' },
    body: JSON.stringify({ insyt_id: 'abc' }),
  }))
  assertEquals(res.status, 410)
  assertEquals(await res.json(), { error: 'use /api/checkout/insyt' })
  assertEquals(res.headers.get('Access-Control-Allow-Origin'), '*')
  assertEquals(res.headers.get('Content-Type'), 'application/json')
})

Deno.test('OPTIONS preflight still succeeds and allows x-client-info', async () => {
  const res = handle(new Request(url, { method: 'OPTIONS' }))
  assertEquals(res.status, 200)
  assertEquals(await res.text(), 'ok')
  const allowed = res.headers.get('Access-Control-Allow-Headers') ?? ''
  assertEquals(allowed.includes('x-client-info'), true)
})

Deno.test('no request reaches Stripe: GET and unauthenticated calls are 410 too', async () => {
  assertEquals(handle(new Request(url, { method: 'GET' })).status, 410)
  const r = handle(new Request(url, { method: 'POST', body: '{}' }))
  assertEquals(r.status, 410)
  await r.body?.cancel()
})
