import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
import { withLogging } from '../_shared/log.ts'

// Start an embedded Stripe Checkout session in subscription mode, so the
// signed-in user can subscribe to a creator. Mirrors create-checkout-session
// (one-off buys) but mode=subscription + Stripe Tax + optional trial. The n8n
// Stripe-webhook workflow reads metadata.creator_id / metadata.subscriber_id
// to upsert public.creator_subscriptions on checkout.session.completed.
//
// Body: { creator_id }  — the creator's auth uid (users.auth_user_id).
//
// v1: NO Stripe Connect transfer/application fee — revenue is collected on the
// platform account; payout routing lands with the separate payouts feature.
// See webflow-app-documentation/features/creator-subscriptions-features.md §7.

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, apikey, content-type, x-client-info',
}

const json = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  })

Deno.serve(withLogging('create-subscription-checkout-session', corsHeaders, async (req, log) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders })
  }

  try {
    const authHeader = req.headers.get('Authorization')
    if (!authHeader) return json(401, { error: 'Missing Authorization header' })

    const { creator_id } = await req.json().catch(() => ({}))
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
      .select('auth_user_id, stripe_subscription_price_id, subscription_trial_days')
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

    const stripeKey = Deno.env.get('STRIPE_SECRET_KEY')
    if (!stripeKey) return json(500, { error: 'STRIPE_SECRET_KEY not configured' })

    const form = new URLSearchParams()
    form.set('ui_mode', 'embedded')
    form.set('mode', 'subscription')
    form.set('line_items[0][price]', creator.stripe_subscription_price_id)
    form.set('line_items[0][quantity]', '1')
    form.set('customer_email', user.email)
    // Metadata on BOTH the session (webhook checkout.session.completed) and the
    // subscription object (customer.subscription.* events) so n8n always has the
    // pair without a lookup.
    form.set('metadata[creator_id]', creator_id)
    form.set('metadata[subscriber_id]', user.id)
    form.set('subscription_data[metadata][creator_id]', creator_id)
    form.set('subscription_data[metadata][subscriber_id]', user.id)
    // Stripe Tax (decision #8): calculate/collect VAT per the subscriber.
    form.set('automatic_tax[enabled]', 'true')
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
      client_secret: session.client_secret,
      session_id: session.id,
    })
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err)
    log.error('unhandled', { err: message })
    return json(500, { error: 'Internal server error', details: message, reqId: log.reqId })
  }
}))
