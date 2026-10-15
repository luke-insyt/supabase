// GET-328 — the pure inquiry-delivery rules. Run: deno test supabase/functions/submit-create-insyt/
import { assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts'
import { priceRefusal, privateEditFields, privateUntil, publicThumbnailUrl, readTimeMin } from './inquiry.ts'

Deno.test('priceRefusal: the fixed price may be echoed, never changed or made free (S5-AC4)', () => {
  assertEquals(priceRefusal(2500, {}), null)
  assertEquals(priceRefusal(2500, { price_cents: 2500 }), null)
  assertEquals(typeof priceRefusal(2500, { price_cents: 2600 }), 'string')
  assertEquals(typeof priceRefusal(2500, { is_free: true }), 'string')
})

Deno.test('privateUntil: exclusive forever, otherwise 30 days (S7-AC2)', () => {
  const now = new Date('2026-10-16T09:00:00Z')
  assertEquals(privateUntil(true, now), 'infinity')
  assertEquals(privateUntil(false, now), '2026-11-15T09:00:00.000Z')
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
