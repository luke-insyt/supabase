// GET-470 — the legal checkout gate for the embedded subscription session
// (feature.md §3.4 (c), implementation.md P4). Pure / injectable, so logic_test.ts covers it;
// index.ts calls Deno.serve on load and can't be imported by a test.
//
// Behind the function secret LEGAL_CHECKOUT_GATE=on only (flipped together with the RN server
// flag, after the app with the waiver pre-step is live). Flag off → the session is exactly as
// before, plus metadata.subscriber_auth_user_id (always added: all three checkout creators
// share that key for the RN webhook).
//
// Flag on, in this order, BEFORE any Stripe call (same rules as the RN server's
// lib/terms-gate.ts requireCheckoutConsent, both reading buyer_terms_status):
//   1. the user hasn't accepted the current buyer_terms → 409 { error: 'terms_outdated', current_version }
//   2. consent.terms_version / consent.waiver_version ≠ current → 409 { error: 'terms_changed' }
// The waiver itself is consented to in Stripe's required Terms checkbox (custom_text
// carries the sentence); the RN webhook records it only when session.consent says
// accepted (2026-11-25: one checkbox in the checkout instead of an in-app pre-step).
// Null-current rule: a type with no current version is "not live yet" and is skipped.
// Then the session gets consent_collection.terms_of_service = required, the Terms link +
// waiver sentence as custom_text.terms_of_service_acceptance, and the consent metadata on
// the session AND subscription_data.
//
// The RN server forwards consent_at / ip / user_agent with x-gi-server-secret; without a valid
// secret they're ignored (consent_at = now, ip/UA from this request) — _shared/request-meta.ts.
import type { SupabaseClient } from 'https://esm.sh/@supabase/supabase-js@2'
import type { RequestMeta } from '../_shared/request-meta.ts'

// deno-lint-ignore no-explicit-any
type Svc = SupabaseClient<any>

export const STRIPE_CUSTOM_TEXT_MAX = 1200
const STRIPE_METADATA_VALUE_MAX = 500

export function legalGateOn(flag: string | null | undefined): boolean {
  return (flag || '').trim().toLowerCase() === 'on'
}

export type TermsStatus = {
  buyer_terms: string | null
  privacy: string | null
  withdrawal_waiver: string | null
  accepted_buyer_terms: boolean
  acknowledged_privacy: boolean
}

export type LegalCurrentRow = {
  document_type: string
  version: string
  url: string
  display_text: string | null
}

export type LegalState = {
  status: TermsStatus
  buyerTermsUrl: string | null
  waiverText: string | null
}

export async function loadLegalState(svc: Svc, userId: string): Promise<{ state: LegalState | null; error: string | null }> {
  const st = await svc.rpc('buyer_terms_status', { p_user: userId })
  if (st.error) return { state: null, error: st.error.message }
  const status = (Array.isArray(st.data) ? st.data[0] : st.data) as TermsStatus | null
  if (!status) return { state: null, error: 'buyer_terms_status returned no row' }
  const cur = await svc.rpc('legal_current')
  if (cur.error) return { state: null, error: cur.error.message }
  const rows = (cur.data ?? []) as LegalCurrentRow[]
  const byType = (t: string) => rows.find((r) => r.document_type === t) ?? null
  return {
    state: {
      status,
      buyerTermsUrl: byType('buyer_terms')?.url ?? null,
      waiverText: byType('withdrawal_waiver')?.display_text ?? null,
    },
    error: null,
  }
}

export type Consent = {
  terms_version?: unknown
  waiver_version?: unknown
  waiver_accepted?: unknown
}

export type Refusal = { status: 400 | 409; body: Record<string, unknown> }

export function consentRefusal(status: TermsStatus, consent: Consent | null | undefined): Refusal | null {
  if (status.buyer_terms !== null && !status.accepted_buyer_terms) {
    return { status: 409, body: { error: 'terms_outdated', current_version: status.buyer_terms } }
  }
  if (status.buyer_terms !== null && consent?.terms_version !== status.buyer_terms) {
    return { status: 409, body: { error: 'terms_changed' } }
  }
  if (status.withdrawal_waiver !== null && consent?.waiver_version !== status.withdrawal_waiver) {
    return { status: 409, body: { error: 'terms_changed' } }
  }
  return null
}

// The Stripe Terms URL is the app's public /terms page (feature §3.4, OQ-4). APP_BASE_URL is a
// function secret; without it the frozen registry file is the fallback (still a valid,
// login-free link to the exact version).
export function termsLinkUrl(appBaseUrl: string | null | undefined, registryUrl: string | null): string | null {
  const base = (appBaseUrl || '').trim().replace(/\/+$/, '')
  if (base) return base + '/terms'
  return registryUrl
}

// Stripe shows custom_text.terms_of_service_acceptance INSTEAD of its default Terms label, so
// the one message carries both the Terms consent and the waiver sentence — both from the
// registry, never a constant, so it can't drift from the in-app pre-step.
export function stripeConsentMessage(opts: {
  termsVersion: string
  termsUrl: string | null
  waiverText: string | null
}): string {
  const label = `Terms of Service (${opts.termsVersion})`
  const terms = opts.termsUrl ? `I agree to the [${label}](${opts.termsUrl}).` : `I agree to the ${label}.`
  const waiver = (opts.waiverText || '').trim()
  return (waiver ? `${terms} ${waiver}` : terms).slice(0, STRIPE_CUSTOM_TEXT_MAX)
}

export type ConsentMeta = {
  terms_version: string | null
  waiver_version: string | null
  consent_at: string
  consent_ip: string | null
  consent_ua: string | null
}

function validIso(v: unknown): string | null {
  if (typeof v !== 'string' || !v.trim()) return null
  const t = Date.parse(v)
  return Number.isNaN(t) ? null : new Date(t).toISOString()
}

export function consentMeta(opts: {
  status: TermsStatus
  meta: RequestMeta
  bodyConsentAt: unknown
  now: Date
}): ConsentMeta {
  const fromServer = opts.meta.trusted ? validIso(opts.bodyConsentAt) : null
  return {
    terms_version: opts.status.buyer_terms,
    waiver_version: opts.status.withdrawal_waiver,
    consent_at: fromServer ?? opts.now.toISOString(),
    consent_ip: opts.meta.ip,
    consent_ua: opts.meta.userAgent ? opts.meta.userAgent.slice(0, STRIPE_METADATA_VALUE_MAX) : null,
  }
}

function setBothMetadata(form: URLSearchParams, key: string, value: string | null) {
  if (value === null || value === '') return
  const v = value.slice(0, STRIPE_METADATA_VALUE_MAX)
  form.set(`metadata[${key}]`, v)
  form.set(`subscription_data[metadata][${key}]`, v)
}

// Always, flag on or off: the RN webhook reads subscriber_auth_user_id ?? subscriber_id.
export function applySubscriberMetadata(form: URLSearchParams, authUserId: string) {
  setBothMetadata(form, 'subscriber_auth_user_id', authUserId)
}

export function applyLegalToForm(form: URLSearchParams, meta: ConsentMeta, message: string | null) {
  if (meta.terms_version !== null) {
    form.set('consent_collection[terms_of_service]', 'required')
    if (message) form.set('custom_text[terms_of_service_acceptance][message]', message)
  }
  setBothMetadata(form, 'terms_version', meta.terms_version)
  setBothMetadata(form, 'waiver_version', meta.waiver_version)
  setBothMetadata(form, 'consent_at', meta.consent_at)
  setBothMetadata(form, 'consent_ip', meta.consent_ip)
  setBothMetadata(form, 'consent_ua', meta.consent_ua)
}
