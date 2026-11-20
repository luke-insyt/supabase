import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
import { withLogging } from '../_shared/log.ts'
import { applyBuyerToSession, attachVatIdToCustomer, checkVatId } from '../_shared/vat.ts'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, apikey, content-type, x-client-info',
}

const json = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  })

// GET-186: Stripe's REST API returns the embedded-checkout `client_secret`
// percent-encoded (the `fid` segment contains %2F / %2B), but Stripe.js
// `initEmbeddedCheckout` requires it DECODED — a raw value throws "Unable to
// parse client secret" and the whole modal fails to load. The Stripe SDKs decode
// it for you; we call the raw REST API, so decode it ourselves before returning.
const decodeClientSecret = (cs: string | null | undefined): string | null => {
  if (!cs) return cs ?? null
  try {
    return decodeURIComponent(cs)
  } catch {
    return cs
  }
}

Deno.serve(withLogging('create-checkout-session', corsHeaders, async (req, log) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders })
  }

  try {
    const authHeader = req.headers.get('Authorization')
    if (!authHeader) {
      return json(401, { error: 'Missing Authorization header' })
    }

    const { insyt_id, vat_id } = await req.json()
    if (!insyt_id) {
      return json(400, { error: 'Missing insyt_id' })
    }

    const userClient = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SB_PUBLISHABLE')!,
      { global: { headers: { Authorization: authHeader } } }
    )

    const { data: { user }, error: userError } = await userClient.auth.getUser()
    if (userError || !user?.email) {
      return json(401, { error: 'Invalid or expired token' })
    }

    const serviceClient = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SB_SERVICE_SECRET')!
    )

    const { data: insyt, error: insytError } = await serviceClient
      .from('insyts')
      .select('insyt_id, stripe_price_id, creator_email, price_eur, title, visibility')
      .eq('insyt_id', insyt_id)
      .maybeSingle()

    if (insytError) {
      return json(500, { error: 'Failed to query insyts', details: insytError.message })
    }
    // GET-328: a private inquiry insyt is bought only in the RN app, by its
    // requester (S6-AC3, S7-AC1) — never through the web checkout.
    if (!insyt || insyt.visibility === 'private') {
      return json(404, { error: 'Insyt not found' })
    }
    // `stripe_price_id` presence still gates "published & paid" (free / pending-publish
    // insyts have none), but it is NOT used for the charge amount — see below.
    if (!insyt.stripe_price_id) {
      return json(409, { error: 'Insyt has no Stripe price (free or pending publish)' })
    }
    // GET-98: charge the CURRENT price, not the stale Stripe Price object.
    // `stripe_price_id` points to an immutable Stripe Price created at publish time;
    // when a creator lowers the price, `price_eur` is updated (the feed + detail page
    // read it) but the old Stripe Price is NOT rolled, so charging via `stripe_price_id`
    // billed the outdated amount. `price_eur` is the single source of truth for the
    // displayed price, so build the line item from it via ad-hoc `price_data`
    // (which carries its own tax_code + tax_behavior, set below).
    // `price_eur` is stored in CENTS (an integer) — the frontend's formatPrice()
    // divides it by 100 for display, and Stripe's unit_amount is also in cents, so
    // it maps across 1:1 with NO further scaling. (399 → €3.99.)
    const amountCents = Math.round(Number(insyt.price_eur))
    if (!Number.isFinite(amountCents) || amountCents <= 0) {
      return json(409, { error: 'Insyt has no valid price' })
    }
    if (insyt.creator_email && insyt.creator_email.toLowerCase() === user.email.toLowerCase()) {
      return json(409, { error: 'Creators cannot buy their own insyt' })
    }

    const stripeKey = Deno.env.get('STRIPE_SECRET_KEY')
    if (!stripeKey) {
      return json(500, { error: 'STRIPE_SECRET_KEY not configured' })
    }

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

    // Mirror the metadata shape the existing Payment Link uses, so the
    // `Purchase Completed` n8n workflow (which reads metadata.insyt_id and
    // customer_details.email) grants access without any change.
    const form = new URLSearchParams()
    form.set('ui_mode', 'embedded')
    form.set('mode', 'payment')
    form.set('line_items[0][price_data][currency]', 'eur')
    form.set('line_items[0][price_data][unit_amount]', String(amountCents))
    form.set('line_items[0][price_data][product_data][name]', insyt.title || 'Insyt')
    // GET-458: price_eur is the gross price the buyer sees — VAT is carved out of it.
    form.set('line_items[0][price_data][tax_behavior]', 'inclusive')
    form.set('line_items[0][price_data][product_data][tax_code]', 'txcd_10000000')
    form.set('line_items[0][quantity]', '1')
    applyBuyerToSession(form, user.email, vatCustomerId)
    form.set('metadata[insyt_id]', insyt.insyt_id)
    if (insyt.creator_email) {
      form.set('metadata[creator_email]', insyt.creator_email)
    }
    // Stripe Tax: calculate/collect VAT per the buyer's location, same as the
    // subscription checkout and the RN server's one-time checkout.
    form.set('automatic_tax[enabled]', 'true')
    // GET-458: every buyer gets an invoice with the full billing address OSS needs.
    // Stripe's own VAT ID field stays OFF — the VAT ID comes pre-checked from our UI
    // (vat_id above), so nobody gets reverse charge on an unverified number.
    form.set('invoice_creation[enabled]', 'true')
    form.set('billing_address_collection', 'required')
    // Show Stripe's native "Add promotion code" field in the embedded checkout.
    // Codes resolve against coupons created in the Stripe dashboard (e.g. a
    // 100%-off coupon for prod smoke-testing — Tax is computed on the
    // post-discount total, so $0 subtotal → $0 tax).
    form.set('allow_promotion_codes', 'true')
    // Keep the buyer in our modal: Stripe will not redirect; we close the
    // modal client-side on `onComplete` and poll get-insyt-content. Stripe
    // rejects `return_url` when `redirect_on_completion` is `never`, so we
    // intentionally omit it.
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
