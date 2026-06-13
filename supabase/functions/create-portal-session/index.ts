import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
import { withLogging } from '../_shared/log.ts'

// Create a Stripe Customer Portal session for the signed-in user, so they can
// update their card (resolve a failed/past_due payment) or cancel. Returns the
// portal URL; the frontend redirects there.
//
// Body: { creator_id?: string, return_url?: string }
//   creator_id — target that subscription's Stripe customer (we use customer_email
//                at checkout, so a user can have a customer per creator); omit for
//                the most recent subscription.
//   return_url — where Stripe sends the user back (defaults to the app).
//
// Requires the Customer Portal to be enabled in the Stripe dashboard.

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, apikey, content-type, x-client-info',
}

const json = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  })

Deno.serve(withLogging('create-portal-session', corsHeaders, async (req, log) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })

  try {
    const authHeader = req.headers.get('Authorization')
    if (!authHeader) return json(401, { error: 'Missing Authorization header' })

    const { creator_id, return_url } = await req.json().catch(() => ({}))

    const userClient = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SB_PUBLISHABLE')!,
      { global: { headers: { Authorization: authHeader } } }
    )
    const { data: { user }, error: userError } = await userClient.auth.getUser()
    if (userError || !user) return json(401, { error: 'Invalid or expired token' })

    const serviceClient = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SB_SERVICE_SECRET')!
    )

    let query = serviceClient
      .from('creator_subscriptions')
      .select('stripe_customer_id, created_at')
      .eq('subscriber_id', user.id)
      .not('stripe_customer_id', 'is', null)
      .order('created_at', { ascending: false })
      .limit(1)
    if (creator_id) query = query.eq('creator_id', creator_id)

    const { data: sub, error: subError } = await query.maybeSingle()
    if (subError) return json(500, { error: 'Failed to load subscription', details: subError.message })
    if (!sub?.stripe_customer_id) {
      return json(404, { error: 'No Stripe customer for this user' })
    }

    const stripeKey = Deno.env.get('STRIPE_SECRET_KEY')
    if (!stripeKey) return json(500, { error: 'STRIPE_SECRET_KEY not configured' })

    const form = new URLSearchParams()
    form.set('customer', sub.stripe_customer_id)
    if (return_url) form.set('return_url', return_url)

    const resp = await fetch('https://api.stripe.com/v1/billing_portal/sessions', {
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

    return json(200, { url: session.url })
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err)
    log.error('unhandled', { err: message })
    return json(500, { error: 'Internal server error', details: message, reqId: log.reqId })
  }
}))
