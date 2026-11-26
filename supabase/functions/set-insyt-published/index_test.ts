// GET-486 B2 — the unhide rule of the Content & Image Rules gate (logic.ts).
// Run: deno test supabase/functions/set-insyt-published/
import { assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts'
import { mayNeedRules, unhideDecision } from './logic.ts'

const TICKS = ['own_work', 'opinions', 'no_confidential', 'minors_initials', 'images_licensed']
const base = { hidden: false, wasHidden: true, current: 'v1.0', needed: true, raw: undefined as unknown }

Deno.test('hiding never needs ticks', () => {
  assertEquals(unhideDecision({ ...base, hidden: true }), { kind: 'skip' })
  assertEquals(mayNeedRules(true, true, 'v1.0'), false)
})

Deno.test('publishing an Insyt that is already visible needs no ticks', () => {
  assertEquals(unhideDecision({ ...base, wasHidden: false }), { kind: 'skip' })
  assertEquals(mayNeedRules(false, false, 'v1.0'), false)
})

Deno.test('null-current: no gate', () => {
  assertEquals(unhideDecision({ ...base, current: null }), { kind: 'skip' })
  assertEquals(mayNeedRules(false, true, null), false)
})

Deno.test('unchanged since the last confirmation under the current rules → no ticks (AC3.5)', () => {
  assertEquals(unhideDecision({ ...base, needed: false }), { kind: 'skip' })
  assertEquals(mayNeedRules(false, true, 'v1.0'), true)
})

Deno.test('changed (or never confirmed) and no ticks → 409 rules_confirmation_required', () => {
  assertEquals(unhideDecision(base), {
    kind: 'refuse',
    status: 409,
    body: { error: 'rules_confirmation_required', current_version: 'v1.0' },
  })
})

Deno.test('stale version → 409 rules_changed; wrong ticks → 400', () => {
  assertEquals(unhideDecision({ ...base, raw: { version: 'v0.9', ticks: TICKS } }), {
    kind: 'refuse',
    status: 409,
    body: { error: 'rules_changed', current_version: 'v1.0' },
  })
  assertEquals(unhideDecision({ ...base, raw: { version: 'v1.0', ticks: TICKS.slice(1) } }), {
    kind: 'refuse',
    status: 400,
    body: { error: 'rules_ticks_invalid' },
  })
  assertEquals(unhideDecision({ ...base, raw: 'x' }).kind, 'refuse')
})

Deno.test('valid ticks → record an unhide confirmation', () => {
  assertEquals(unhideDecision({ ...base, raw: { version: 'v1.0', ticks: TICKS } }), {
    kind: 'record',
    confirmation: { version: 'v1.0', ticks: TICKS },
  })
})
