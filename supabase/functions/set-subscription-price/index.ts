import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

// Creator-facing: set (or change) the monthly subscription price for the
// signed-in creator. Creates/reuses a Stripe Product for the creator and
// creates a NEW recurring monthly Price (Stripe prices are immutable), then
// stores the price id + amount + currency + trial on public.users. New
// subscriptions use the latest price; existing subscribers keep their old one.
//
// Body: { amount_cents: int, currency: string, trial_days?: int }
//   amount_cents — minor units, 50..100000 (0.50..1000.00)
//   currency     — ISO 4217 lower-case, e.g. 'eur' | 'usd'
//   trial_days   — optional 0..90, free-trial length for new subscribers
//
// See webflow-app-documentation/features/creator-subscriptions-features.md §5.

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, apikey, content-type, x-client-info',
}

const json = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  })

const MIN_CENTS = 50       // 0.50
const MAX_CENTS = 100000   // 1000.00
const MAX_TRIAL_DAYS = 90
// Stripe zero-decimal currencies must NOT be multiplied by 100; we store minor
// units everywhere, so reject them here rather than mishandle the amount.
const ZERO_DECIMAL = new Set(['bif','clp','djf','gnf','jpy','kmf','krw','mga','pyg','rwf','ugx','vnd','vuv','xaf','xof','xpf'])

async function stripe(path: string, key: string, form?: URLSearchParams) {
  const resp = await fetch('https://api.stripe.com/v1/' + path, {
    method: form ? 'POST' : 'GET',
    headers: {
      Authorization: 'Bearer ' + key,
      'Content-Type': 'application/x-www-form-urlencoded',
    },
    body: form ? form.toString() : undefined,
  })
  const data = await resp.json()
  return { ok: resp.ok, status: resp.status, data }
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders })
  }

  try {
    const authHeader = req.headers.get('Authorization')
    if (!authHeader) return json(401, { error: 'Missing Authorization header' })

    const payload = await req.json().catch(() => ({}))
    const amountCents = Number(payload.amount_cents)
    const currency = String(payload.currency || '').toLowerCase().trim()
    const trialDays = payload.trial_days == null ? null : Number(payload.trial_days)

    if (!Number.isInteger(amountCents) || amountCents < MIN_CENTS || amountCents > MAX_CENTS) {
      return json(400, { error: 'amount_cents must be an integer between 50 and 100000 (0.50–1000.00)' })
    }
    if (!/^[a-z]{3}$/.test(currency)) {
      return json(400, { error: 'currency must be a 3-letter ISO code, e.g. eur' })
    }
    if (ZERO_DECIMAL.has(currency)) {
      return json(400, { error: 'Zero-decimal currencies are not supported' })
    }
    if (trialDays != null && (!Number.isInteger(trialDays) || trialDays < 0 || trialDays > MAX_TRIAL_DAYS)) {
      return json(400, { error: 'trial_days must be an integer between 0 and 90' })
    }

    const userClient = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_ANON_KEY')!,
      { global: { headers: { Authorization: authHeader } } }
    )
    const { data: { user }, error: userError } = await userClient.auth.getUser()
    if (userError || !user) return json(401, { error: 'Invalid or expired token' })

    const serviceClient = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
    )

    const { data: creator, error: creatorError } = await serviceClient
      .from('users')
      .select('auth_user_id, email, display_name, is_creator, stripe_subscription_product_id')
      .eq('auth_user_id', user.id)
      .maybeSingle()
    if (creatorError) return json(500, { error: 'Failed to load creator', details: creatorError.message })
    if (!creator) return json(404, { error: 'No creator profile for this user' })
    if (!creator.is_creator) return json(403, { error: 'Only creators can set a subscription price' })

    const stripeKey = Deno.env.get('STRIPE_SECRET_KEY')
    if (!stripeKey) return json(500, { error: 'STRIPE_SECRET_KEY not configured' })

    // Ensure a Stripe Product for this creator (reused across price changes).
    let productId = creator.stripe_subscription_product_id
    if (!productId) {
      const pForm = new URLSearchParams()
      pForm.set('name', (creator.display_name || creator.email || 'Creator') + ' — Subscription')
      pForm.set('metadata[creator_id]', user.id)
      const prod = await stripe('products', stripeKey, pForm)
      if (!prod.ok) {
        console.error('[set-subscription-price] product create failed', prod.data)
        return json(prod.status, { error: 'Stripe product error', details: prod.data })
      }
      productId = prod.data.id
    }

    // Create a new recurring monthly Price (prices are immutable in Stripe).
    const priceForm = new URLSearchParams()
    priceForm.set('product', productId)
    priceForm.set('unit_amount', String(amountCents))
    priceForm.set('currency', currency)
    priceForm.set('recurring[interval]', 'month')
    priceForm.set('metadata[creator_id]', user.id)
    const price = await stripe('prices', stripeKey, priceForm)
    if (!price.ok) {
      console.error('[set-subscription-price] price create failed', price.data)
      return json(price.status, { error: 'Stripe price error', details: price.data })
    }

    const { error: updateError } = await serviceClient
      .from('users')
      .update({
        stripe_subscription_product_id: productId,
        stripe_subscription_price_id: price.data.id,
        subscription_price_usd: amountCents,   // legacy column name; holds minor units
        subscription_currency: currency,
        subscription_trial_days: trialDays,
        updated_at: new Date().toISOString(),
      })
      .eq('auth_user_id', user.id)
    if (updateError) {
      console.error('[set-subscription-price] users update failed', updateError)
      return json(500, { error: 'Failed to save price', details: updateError.message })
    }

    return json(200, {
      stripe_price_id: price.data.id,
      amount_cents: amountCents,
      currency,
      trial_days: trialDays,
    })
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err)
    console.error('[set-subscription-price] Unhandled error:', message)
    return json(500, { error: 'Internal server error', details: message })
  }
})
