// GET-470 — create-subscription-checkout-session legal gate.
// Run: DENO_NO_PACKAGE_JSON=1 deno test supabase/functions/create-subscription-checkout-session/
import { assert, assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts'
import { requestMeta } from '../_shared/request-meta.ts'
import {
  applyLegalToForm,
  applySubscriberMetadata,
  consentMeta,
  consentRefusal,
  legalGateOn,
  loadLegalState,
  stripeConsentMessage,
  termsLinkUrl,
  type TermsStatus,
} from './logic.ts'

const WAIVER = 'I want immediate access and understand I lose my 14-day right of withdrawal.'

const live: TermsStatus = {
  buyer_terms: 'v2.0',
  privacy: 'v1.0',
  withdrawal_waiver: 'v1.0',
  accepted_buyer_terms: true,
  acknowledged_privacy: true,
}
const good = { terms_version: 'v2.0', waiver_version: 'v1.0', waiver_accepted: true }

Deno.test('legalGateOn: only "on" enables the gate (flag off → no re-check)', () => {
  assertEquals(legalGateOn('on'), true)
  assertEquals(legalGateOn(' ON '), true)
  for (const v of [undefined, null, '', 'off', 'true', '1']) assertEquals(legalGateOn(v), false, String(v))
})

Deno.test('consentRefusal: stale user → 409 terms_outdated with current_version', () => {
  assertEquals(consentRefusal({ ...live, accepted_buyer_terms: false }, good), {
    status: 409,
    body: { error: 'terms_outdated', current_version: 'v2.0' },
  })
})

Deno.test('consentRefusal: consent for another version → 409 terms_changed', () => {
  assertEquals(consentRefusal(live, { ...good, terms_version: 'v1.0' }), { status: 409, body: { error: 'terms_changed' } })
  assertEquals(consentRefusal(live, { ...good, waiver_version: 'v0.9' }), { status: 409, body: { error: 'terms_changed' } })
  assertEquals(consentRefusal(live, undefined), { status: 409, body: { error: 'terms_changed' } })
})

Deno.test('consentRefusal: waiver not ticked → 400 waiver_required', () => {
  assertEquals(consentRefusal(live, { ...good, waiver_accepted: false }), { status: 400, body: { error: 'waiver_required' } })
  assertEquals(consentRefusal(live, { ...good, waiver_accepted: 'true' }), { status: 400, body: { error: 'waiver_required' } })
})

Deno.test('consentRefusal: current consent passes; null-current types are skipped', () => {
  assertEquals(consentRefusal(live, good), null)
  const none: TermsStatus = { buyer_terms: null, privacy: null, withdrawal_waiver: null, accepted_buyer_terms: true, acknowledged_privacy: true }
  assertEquals(consentRefusal(none, undefined), null)
  assertEquals(consentRefusal({ ...live, withdrawal_waiver: null }, { terms_version: 'v2.0' }), null)
})

Deno.test('stripeConsentMessage: Terms link with version + the registry waiver text, ≤ 1200 chars', () => {
  const m = stripeConsentMessage({ termsVersion: 'v2.0', termsUrl: 'https://app.example/terms', waiverText: WAIVER })
  assertEquals(m, `I agree to the [Terms of Service (v2.0)](https://app.example/terms). ${WAIVER}`)
  assertEquals(stripeConsentMessage({ termsVersion: 'v2.0', termsUrl: null, waiverText: null }), 'I agree to the Terms of Service (v2.0).')
  assert(stripeConsentMessage({ termsVersion: 'v2.0', termsUrl: 'u', waiverText: 'x'.repeat(5000) }).length <= 1200)
})

Deno.test('termsLinkUrl: the app /terms page, else the frozen registry file', () => {
  assertEquals(termsLinkUrl('https://app.example/', 'https://x/legal.html'), 'https://app.example/terms')
  assertEquals(termsLinkUrl(undefined, 'https://x/legal.html'), 'https://x/legal.html')
})

Deno.test('consentMeta: body consent_at/ip/UA only with a valid server secret', () => {
  const now = new Date('2026-12-01T10:00:00.000Z')
  const body = { ip: '203.0.113.9', user_agent: 'RealBrowser/2', consent_at: '2026-12-01T09:59:30Z' }
  const server = requestMeta(new Headers({ 'x-gi-server-secret': 'sec', 'user-agent': 'node' }), body, 'sec')
  assertEquals(consentMeta({ status: live, meta: server, bodyConsentAt: body.consent_at, now }), {
    terms_version: 'v2.0',
    waiver_version: 'v1.0',
    consent_at: '2026-12-01T09:59:30.000Z',
    consent_ip: '203.0.113.9',
    consent_ua: 'RealBrowser/2',
  })
  const forged = requestMeta(new Headers({ 'x-gi-server-secret': 'nope', 'user-agent': 'curl/8', 'cf-connecting-ip': '198.51.100.1' }), body, 'sec')
  assertEquals(consentMeta({ status: live, meta: forged, bodyConsentAt: body.consent_at, now }), {
    terms_version: 'v2.0',
    waiver_version: 'v1.0',
    consent_at: '2026-12-01T10:00:00.000Z',
    consent_ip: '198.51.100.1',
    consent_ua: 'curl/8',
  })
})

Deno.test('applySubscriberMetadata: always on the session and the subscription', () => {
  const f = new URLSearchParams()
  applySubscriberMetadata(f, 'user-1')
  assertEquals(f.get('metadata[subscriber_auth_user_id]'), 'user-1')
  assertEquals(f.get('subscription_data[metadata][subscriber_auth_user_id]'), 'user-1')
  assertEquals(f.get('consent_collection[terms_of_service]'), null)
})

Deno.test('applyLegalToForm: consent_collection, custom_text and consent metadata on both objects', () => {
  const f = new URLSearchParams()
  applyLegalToForm(
    f,
    { terms_version: 'v2.0', waiver_version: 'v1.0', consent_at: '2026-12-01T10:00:00.000Z', consent_ip: null, consent_ua: 'UA' },
    'MSG',
  )
  assertEquals(f.get('consent_collection[terms_of_service]'), 'required')
  assertEquals(f.get('custom_text[terms_of_service_acceptance][message]'), 'MSG')
  for (const p of ['metadata', 'subscription_data[metadata]']) {
    assertEquals(f.get(`${p}[terms_version]`), 'v2.0')
    assertEquals(f.get(`${p}[waiver_version]`), 'v1.0')
    assertEquals(f.get(`${p}[consent_at]`), '2026-12-01T10:00:00.000Z')
    assertEquals(f.get(`${p}[consent_ua]`), 'UA')
    assertEquals(f.has(`${p}[consent_ip]`), false) // null → key omitted, never "null"
  }
})

Deno.test('loadLegalState: reads buyer_terms_status(p_user) + legal_current()', async () => {
  const calls: unknown[] = []
  const svc = {
    rpc: (fn: string, args?: unknown) => {
      calls.push([fn, args])
      if (fn === 'buyer_terms_status') return Promise.resolve({ data: [live], error: null })
      return Promise.resolve({
        data: [
          { document_type: 'buyer_terms', version: 'v2.0', url: 'https://x/bt.html', display_text: null },
          { document_type: 'withdrawal_waiver', version: 'v1.0', url: 'https://x/ww.html', display_text: WAIVER },
        ],
        error: null,
      })
    },
  }
  // deno-lint-ignore no-explicit-any
  const { state, error } = await loadLegalState(svc as any, 'user-1')
  assertEquals(error, null)
  assertEquals(state, { status: live, buyerTermsUrl: 'https://x/bt.html', waiverText: WAIVER })
  assertEquals(calls, [['buyer_terms_status', { p_user: 'user-1' }], ['legal_current', undefined]])
})
