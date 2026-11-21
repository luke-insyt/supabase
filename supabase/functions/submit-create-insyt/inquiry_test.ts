// GET-328 / GET-459 — the pure inquiry-delivery rules. Run: deno test supabase/functions/submit-create-insyt/
import { assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts'
import {
  accessMode,
  inquiryPrice,
  isPriceLocked,
  priceRefusal,
  privateEditFields,
  privateUntil,
  publicThumbnailUrl,
  readTimeMin,
  releasePriceCents,
} from './inquiry.ts'

Deno.test('priceRefusal: the fixed price may be echoed, never changed or made free (S5-AC4)', () => {
  assertEquals(priceRefusal(2500, {}), null)
  assertEquals(priceRefusal(2500, { price_cents: 2500 }), null)
  assertEquals(typeof priceRefusal(2500, { price_cents: 2600 }), 'string')
  assertEquals(typeof priceRefusal(2500, { is_free: true }), 'string')
})

Deno.test('privateUntil: exclusive and open forever, timed 30 days (S7-AC2, GET-459 §3)', () => {
  const now = new Date('2026-10-16T09:00:00Z')
  assertEquals(privateUntil('exclusive', now), 'infinity')
  assertEquals(privateUntil('timed', now), '2026-11-15T09:00:00.000Z')
  // Open mode has no time-based release: only the requester's purchase releases it (S3-AC1).
  assertEquals(privateUntil('open', now), 'infinity')
})

Deno.test('releasePriceCents: €0 for open mode, the Insyter\'s price (null) otherwise (GET-459 §3)', () => {
  assertEquals(releasePriceCents('open'), 0)
  assertEquals(releasePriceCents('timed'), null)
  assertEquals(releasePriceCents('exclusive'), null)
})

Deno.test('accessMode: reads inquiries.access_mode; is_exclusive is only the backstop', () => {
  assertEquals(accessMode({ access_mode: 'open', is_exclusive: false }), 'open')
  assertEquals(accessMode({ access_mode: 'timed', is_exclusive: true }), 'timed')
  assertEquals(accessMode({ access_mode: 'exclusive', is_exclusive: false }), 'exclusive')
  assertEquals(accessMode({ access_mode: null, is_exclusive: true }), 'exclusive')
  assertEquals(accessMode({ access_mode: null, is_exclusive: false }), 'timed')
  assertEquals(accessMode(null), 'timed')
  // An unknown value never makes anything public.
  assertEquals(accessMode({ access_mode: 'everyone', is_exclusive: false }), 'exclusive')
})

Deno.test('isPriceLocked: only a released insyt whose release price was €0 (S5-AC5)', () => {
  assertEquals(isPriceLocked({ released_at: '2026-11-21T10:00:00Z', release_price_cents: 0 }), true)
  // A timed flip is released at the Insyter's price: still editable.
  assertEquals(isPriceLocked({ released_at: '2026-11-21T10:00:00Z', release_price_cents: null }), false)
  // A delivered open insyt the requester hasn't bought yet.
  assertEquals(isPriceLocked({ released_at: null, release_price_cents: 0 }), false)
  assertEquals(isPriceLocked(null), false)
})

Deno.test('inquiryPrice: a released open insyt stays €0 — echo 0 or omit passes, any other price is price_locked', () => {
  const locked = { price_cents: 2500, price_locked: true }
  const free = { ok: true as const, price_cents: 0, is_free: true }
  // Echo 0 (the form shows €0 read-only).
  assertEquals(inquiryPrice(locked, { price_cents: 0 }), free)
  assertEquals(inquiryPrice(locked, { price_cents: 0, is_free: true }), free)
  // Omit the price.
  assertEquals(inquiryPrice(locked, {}), free)
  assertEquals(inquiryPrice(locked, { is_free: false }), free)
  // A non-zero price — the proposal price included — is refused, not reset.
  assertEquals(inquiryPrice(locked, { price_cents: 2500 }), { ok: false, status: 400, body: { error: 'price_locked' } })
  assertEquals(inquiryPrice(locked, { price_cents: 100, is_free: false }), { ok: false, status: 400, body: { error: 'price_locked' } })
})

Deno.test('inquiryPrice: otherwise the proposal price, never free (S5-AC4)', () => {
  const open = { price_cents: 2500, price_locked: false }
  assertEquals(inquiryPrice(open, {}), { ok: true, price_cents: 2500, is_free: false })
  assertEquals(inquiryPrice(open, { price_cents: 2500 }), { ok: true, price_cents: 2500, is_free: false })
  assertEquals(inquiryPrice({ price_cents: 2500 }, { price_cents: 2500 }), { ok: true, price_cents: 2500, is_free: false })
  assertEquals(inquiryPrice(open, { price_cents: 0 }).ok, false)
  assertEquals(inquiryPrice(open, { is_free: true }).ok, false)
  assertEquals(inquiryPrice(open, { price_cents: 2600 }).ok, false)
})

Deno.test('readTimeMin: mirrors the n8n pipeline (200 wpm, at least 1)', () => {
  assertEquals(readTimeMin('', ''), 1)
  assertEquals(readTimeMin('<p>' + 'word '.repeat(401) + '</p>', 'two words'), 3)
})

Deno.test('private edits rebuild the public cover URL and read time (no n8n re-sync)', () => {
  assertEquals(publicThumbnailUrl(null), null)
  assertEquals(String(publicThumbnailUrl({ bucket: 'insyt-thumbnails', path: 'u/c/cover.jpg' })).endsWith('/storage/v1/object/public/insyt-thumbnails/u/c/cover.jpg'), true)
  const f = privateEditFields({ cover: null, full_text: '<p>' + 'w '.repeat(250) + '</p>', description: '' })
  assertEquals(f, { thumbnail_url: null, read_time_min: 2 })
})
