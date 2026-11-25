import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
import { withLogging } from '../_shared/log.ts'
import { applyBuyerToSession, attachVatIdToCustomer, checkVatId } from '../_shared/vat.ts'
import { requestMeta, SERVER_SECRET_HEADER } from '../_shared/request-meta.ts'
import {
  applyLegalToForm,
  applySubscriberMetadata,
  consentMeta,
  consentRefusal,
  legalGateOn,
  loadLegalState,
  stripeConsentMessage,
  termsLinkUrl,
  type ConsentMeta,
} from './logic.ts'

// Start an embedded Stripe Checkout session in subscription mode, so the
// signed-in user can subscribe to a creator. Mirrors create-checkout-session
// (one-off buys) but mode=subscription + Stripe Tax + optional trial. The n8n
// Stripe-webhook workflow reads metadata.creator_id / metadata.subscriber_id
// to upsert public.creator_subscriptions on checkout.session.completed.
//
// Body: { creator_id, vat_id?, consent?, consent_at?, ip?, user_agent? }  — the creator's auth
// uid (users.auth_user_id); vat_id = optional EU VAT ID, VIES-checked before the session is
// created (GET-458). GET-470: consent = { terms_version, waiver_version, waiver_accepted }
// (checked only while LEGAL_CHECKOUT_GATE=on); consent_at / ip / user_agent are trusted only
// from the RN server with a valid x-gi-server-secret — see logic.ts.
//
// v1: NO Stripe Connect transfer/application fee — revenue is collected on the
// platform account; payout routing lands with the separate payouts feature.
// See webflow-app-documentation/features/creator-subscriptions-features.md §7.

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': `authorization, apikey, content-type, x-client-info, ${SERVER_SECRET_HEADER}`,
}

const json = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  })

// GET-186: Stripe's REST API returns the embedded-checkout `client_secret`
// percent-encoded (the `fid` segment contains %2F / %2B), but Stripe.js
// `initEmbeddedCheckout` requires it DECODED — a raw value throws "Unable to
// parse client secret" and the modal fails to load. The Stripe SDKs decode it
// for you; we call the raw REST API, so decode it ourselves before returning.
// (The RN app's embedded subscribe relays this same fn, so the decode fixes it too.)
const decodeClientSecret = (cs: string | null | undefined): string | null => {
  if (!cs) return cs ?? null
  try {
    return decodeURIComponent(cs)
  } catch {
    return cs
  }
}

Deno.serve(withLogging('create-subscription-checkout-session', corsHeaders, async (req, log) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders })
  }

  try {
    const authHeader = req.headers.get('Authorization')
    if (!authHeader) return json(401, { error: 'Missing Authorization header' })

    const body = await req.json().catch(() => ({}))
    const { creator_id, vat_id } = body ?? {}
    if (!creator_id) return json(400, { error: 'Missing creator_id' })

    const userClient = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SB_PUBLISHABLE')!,
      { global: { headers: { Authorization: authHeader } } }
    )
    const { data: { user }, error: userError } = await userClient.auth.getUser()
    if (userError || !user?.email) return json(401, { error: 'Invalid or expired token' })

    if (user.id === creator_id) {
      return json(409, { error: 'You cannot subscribe to yourself' })
    }

    const serviceClient = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SB_SERVICE_SECRET')!
    )

    const { data: creator, error: creatorError } = await serviceClient
      .from('users')
      .select(
        'auth_user_id, display_name, stripe_subscription_product_id, stripe_subscription_price_id, subscription_trial_days'
      )
      .eq('auth_user_id', creator_id)
      .maybeSingle()
    if (creatorError) return json(500, { error: 'Failed to load creator', details: creatorError.message })
    if (!creator) return json(404, { error: 'Creator not found' })
    if (!creator.stripe_subscription_price_id) {
      return json(409, { error: 'This creator has not set up a subscription' })
    }

    // Don't let someone open a second checkout while they already have a live sub.
    const { data: existing } = await serviceClient
      .from('creator_subscriptions')
      .select('id')
      .eq('subscriber_id', user.id)
      .eq('creator_id', creator_id)
      .in('status', ['active', 'trialing', 'past_due', 'unpaid'])
      .maybeSingle()
    if (existing) {
      return json(409, { error: 'You already have an active subscription to this creator' })
    }

    // GET-470: the legal checkout gate, BEFORE any Stripe call. The edge fn re-checks
    // independently of the RN server because any user JWT can call it directly.
    let legal: { meta: ConsentMeta; message: string | null } | null = null
    if (legalGateOn(Deno.env.get('LEGAL_CHECKOUT_GATE'))) {
      const { state, error: legalError } = await loadLegalState(serviceClient, user.id)
      if (legalError || !state) {
        log.error('legal state read failed', { err: legalError })
        return json(500, { error: 'Failed to read terms status', reqId: log.reqId })
      }
      const refusal = consentRefusal(state.status, body?.consent)
      if (refusal) {
        log.info('checkout consent refused', { error: refusal.body.error })
        return json(refusal.status, refusal.body)
      }
      if (state.status.buyer_terms !== null || state.status.withdrawal_waiver !== null) {
        const meta = consentMeta({
          status: state.status,
          meta: requestMeta(req.headers, body, Deno.env.get('GI_SERVER_SECRET')),
          bodyConsentAt: body?.consent_at,
          now: new Date(),
        })
        const message = state.status.buyer_terms !== null
          ? stripeConsentMessage({
            termsVersion: state.status.buyer_terms,
            termsUrl: termsLinkUrl(Deno.env.get('APP_BASE_URL'), state.buyerTermsUrl),
            waiverText: state.waiverText,
          })
          : null
        legal = { meta, message }
      }
    }

    const stripeKey = Deno.env.get('STRIPE_SECRET_KEY')
    if (!stripeKey) return json(500, { error: 'STRIPE_SECRET_KEY not configured' })

    // GET-458: optional EU VAT ID, checked against VIES BEFORE any payment. Invalid →
    // error (no session); valid or VIES unreachable → attached to the Stripe customer
    // so Stripe Tax reverse-charges it (see _shared/vat.ts).
    let vatCustomerId: string | null = null
    if (typeof vat_id === 'string' && vat_id.trim()) {
      const vat = await checkVatId(vat_id)
      if (!vat.ok) {
        log.info('vat id rejected', { code: vat.code })
        return json(422, { error: vat.message, code: vat.code })
      }
      log.info('vat id accepted', { status: vat.status })
      vatCustomerId = await attachVatIdToCustomer(stripeKey, user.email, vat.vatId)
    }

    // GET-124: the embedded payment window shows the Stripe *product* name. The
    // subscription product is created once (set-subscription-price) with the
    // creator's display name and never re-synced, so a creator who renames after
    // setting their price still shows the OLD name at checkout. Refresh the product
    // name to the creator's CURRENT display name right before opening the session.
    // Best-effort: a name-sync hiccup must never block someone from subscribing.
    if (creator.stripe_subscription_product_id && creator.display_name) {
      const nameForm = new URLSearchParams()
      nameForm.set('name', creator.display_name + ' — Subscription')
      try {
        const nameResp = await fetch(
          'https://api.stripe.com/v1/products/' + creator.stripe_subscription_product_id,
          {
            method: 'POST',
            headers: {
              Authorization: 'Bearer ' + stripeKey,
              'Content-Type': 'application/x-www-form-urlencoded',
            },
            body: nameForm.toString(),
          }
        )
        if (!nameResp.ok) {
          log.error('product name sync non-ok (non-fatal)', { status: nameResp.status })
        }
      } catch (e) {
        log.error('product name sync failed (non-fatal)', { err: String(e) })
      }
    }

    const form = new URLSearchParams()
    form.set('ui_mode', 'embedded')
    form.set('mode', 'subscription')
    form.set('line_items[0][price]', creator.stripe_subscription_price_id)
    form.set('line_items[0][quantity]', '1')
    applyBuyerToSession(form, user.email, vatCustomerId)
    // Metadata on BOTH the session (webhook checkout.session.completed) and the
    // subscription object (customer.subscription.* events) so n8n always has the
    // pair without a lookup.
    form.set('metadata[creator_id]', creator_id)
    form.set('metadata[subscriber_id]', user.id)
    form.set('subscription_data[metadata][creator_id]', creator_id)
    form.set('subscription_data[metadata][subscriber_id]', user.id)
    // GET-470: the key all three checkout creators share for the RN webhook (always set).
    applySubscriberMetadata(form, user.id)
    // GET-470: Stripe's required Terms checkbox + waiver text + consent evidence (flag on only).
    if (legal) applyLegalToForm(form, legal.meta, legal.message)
    // Stripe Tax (decision #8): calculate/collect VAT per the subscriber.
    form.set('automatic_tax[enabled]', 'true')
    // GET-458: full billing address for OSS. (No invoice_creation: subscription mode
    // always invoices.) Stripe's own VAT ID field stays OFF — the VAT ID comes
    // pre-checked from our UI (vat_id above).
    form.set('billing_address_collection', 'required')
    // Show Stripe's native "Add promotion code" field in the embedded checkout.
    // Codes resolve against coupons created in the Stripe dashboard (e.g. a
    // forever 100%-off coupon for prod smoke-testing — Tax is computed on the
    // post-discount total, so $0 subtotal → $0 tax).
    form.set('allow_promotion_codes', 'true')
    // Optional free trial (decision #7), only when the creator enabled one.
    const trial = Number(creator.subscription_trial_days)
    if (Number.isInteger(trial) && trial > 0) {
      form.set('subscription_data[trial_period_days]', String(trial))
    }
    // Stay in our modal — close client-side on onComplete and poll for the row.
    form.set('redirect_on_completion', 'never')

    const resp = await fetch('https://api.stripe.com/v1/checkout/sessions', {
      method: 'POST',
      headers: {
        Authorization: 'Bearer ' + stripeKey,
        'Content-Type': 'application/x-www-form-urlencoded',
      },
      body: form.toString(),
    })
    const session = await resp.json()
    if (!resp.ok) {
      log.error('Stripe error', { status: resp.status, details: session })
      return json(resp.status, { error: 'Stripe error', details: session, reqId: log.reqId })
    }

    return json(200, {
      client_secret: decodeClientSecret(session.client_secret),
      session_id: session.id,
    })
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err)
    log.error('unhandled', { err: message })
    return json(500, { error: 'Internal server error', details: message, reqId: log.reqId })
  }
}))
