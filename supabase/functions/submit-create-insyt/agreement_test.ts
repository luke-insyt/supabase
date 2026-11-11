// GET-357 — the publish-side Creator Agreement gate. Run: deno test supabase/functions/submit-create-insyt/
import { assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts'
import { agreementRefusal, needsAgreementCheck, type AgreementRefusal } from './agreement.ts'

// Just enough of supabase-js for `from().select().eq().maybeSingle()`.
function fakeSvc(current: string | null, error: { message: string } | null = null) {
  const seen: unknown[] = []
  const chain = {
    select: (cols: string) => (seen.push(['select', cols]), chain),
    eq: (col: string, val: unknown) => (seen.push(['eq', col, val]), chain),
    maybeSingle: () => Promise.resolve({ data: current === null ? null : { version: current }, error }),
  }
  const svc = { from: (t: string) => (seen.push(['from', t]), chain) }
  // deno-lint-ignore no-explicit-any
  return { svc: svc as any, seen }
}

function fakeLog() {
  const errors: string[] = []
  return { log: { error: (msg: string) => void errors.push(msg) }, errors }
}

Deno.test('needsAgreementCheck: a new publish is gated, a delivery is exempt (R4-AC3)', () => {
  assertEquals(needsAgreementCheck('submit', {}), true)
  assertEquals(needsAgreementCheck('submit', { inquiry_proposal_id: '7b0c2a52-1d0e-4f3a-9c55-0d5b8f1e2a90' }), false)
})

Deno.test('needsAgreementCheck: an absent action is a submit, like index.ts', () => {
  assertEquals(needsAgreementCheck(undefined, {}), true)
  assertEquals(needsAgreementCheck('', {}), true)
})

Deno.test('needsAgreementCheck: drafts and every other action are not gated', () => {
  for (const a of ['save_draft', 'discard', 'load_draft', 'list_drafts', 'purchase_status', 'update_published', 'confirm_update']) {
    assertEquals(needsAgreementCheck(a, {}), false, a)
  }
})

Deno.test('needsAgreementCheck: a blank proposal id is no delivery, so it cannot bypass the gate', () => {
  assertEquals(needsAgreementCheck('submit', { inquiry_proposal_id: '' }), true)
  assertEquals(needsAgreementCheck('submit', { inquiry_proposal_id: '   ' }), true)
  assertEquals(needsAgreementCheck('submit', { inquiry_proposal_id: null }), true)
})

Deno.test('agreementRefusal: the current version passes', async () => {
  const { svc, seen } = fakeSvc('v1.1')
  assertEquals(await agreementRefusal(svc, 'v1.1'), null)
  assertEquals(seen, [['from', 'agreement_versions'], ['select', 'version'], ['eq', 'is_current', true]])
})

Deno.test('agreementRefusal: a stale or missing version is 409 with current_version', async () => {
  const want: AgreementRefusal = { status: 409, body: { error: 'agreement_outdated', current_version: 'v1.1' } }
  assertEquals(await agreementRefusal(fakeSvc('v1.1').svc, 'v1.0'), want)
  assertEquals(await agreementRefusal(fakeSvc('v1.1').svc, null), want)
  assertEquals(await agreementRefusal(fakeSvc('v1.1').svc, undefined), want)
})

Deno.test('agreementRefusal: no current version blocks with 500 and alerts', async () => {
  const want: AgreementRefusal = { status: 500, body: { error: 'no current agreement' } }
  const a = fakeLog()
  assertEquals(await agreementRefusal(fakeSvc(null).svc, 'v1.0', a.log), want)
  assertEquals(a.errors, ['no current agreement'])
  const b = fakeLog()
  assertEquals(await agreementRefusal(fakeSvc(null, { message: 'boom' }).svc, 'v1.0', b.log), want)
  assertEquals(b.errors, ['no current agreement'])
})
