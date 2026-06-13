import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
import { withLogging } from '../_shared/log.ts'

// Cancel the signed-in user's subscription to a creator AT PERIOD END (they keep
// access until the paid period ends, then it doesn't renew). Replaces the Stripe
// Customer Portal for cancellation so it can happen in an in-app modal.
//
// Body: { creator_id: string }  — the creator whose subscription to cancel.
// Returns: { ok: true, current_period_end: <unix|null>, cancel_at_period_end: true }

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, apikey, content-type, x-client-info',
}

const json = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  })

Deno.serve(withLogging('cancel-subscription', corsHeaders, async (req, log) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })

  try {
    const authHeader = req.headers.get('Authorization')
    if (!authHeader) return json(401, { error: 'Missing Authorization header' })

    const { creator_id, resume } = await req.json().catch(() => ({}))
    if (!creator_id) return json(400, { error: 'Missing creator_id' })
    const cancel = !resume // resume:true un-cancels (keeps the subscription renewing)

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

    // Find the caller's own subscription to this creator (RLS bypassed via the
    // service client, but scoped to subscriber_id = the verified user).
    const { data: sub, error: subError } = await serviceClient
      .from('creator_subscriptions')
      .select('id, stripe_subscription_id, current_period_end, status, cancel_at_period_end')
      .eq('subscriber_id', user.id)
      .eq('creator_id', creator_id)
      .order('created_at', { ascending: false })
      .limit(1)
      .maybeSingle()
    if (subError) return json(500, { error: 'Failed to load subscription', details: subError.message })
    if (!sub?.stripe_subscription_id) return json(404, { error: 'No subscription found for this creator' })

    const stripeKey = Deno.env.get('STRIPE_SECRET_KEY')
    if (!stripeKey) return json(500, { error: 'STRIPE_SECRET_KEY not configured' })

    // Stripe: toggle cancellation at the end of the current paid period.
    const form = new URLSearchParams()
    form.set('cancel_at_period_end', cancel ? 'true' : 'false')
    const resp = await fetch(
      'https://api.stripe.com/v1/subscriptions/' + encodeURIComponent(sub.stripe_subscription_id),
      {
        method: 'POST',
        headers: {
          Authorization: 'Bearer ' + stripeKey,
          'Content-Type': 'application/x-www-form-urlencoded',
        },
        body: form.toString(),
      }
    )
    const stripeSub = await resp.json()
    if (!resp.ok) {
      log.error('Stripe error', { status: resp.status, details: stripeSub })
      return json(resp.status, { error: 'Stripe error', details: stripeSub, reqId: log.reqId })
    }

    // Optimistically reflect the change locally; the Stripe webhook (n8n) is the
    // source of truth and will reconcile status/period on its own.
    await serviceClient
      .from('creator_subscriptions')
      .update({ cancel_at_period_end: cancel })
      .eq('id', sub.id)

    const periodEnd = stripeSub.current_period_end ?? sub.current_period_end ?? null
    return json(200, { ok: true, cancel_at_period_end: cancel, current_period_end: periodEnd })
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err)
    log.error('unhandled', { err: message })
    return json(500, { error: 'Internal server error', details: message, reqId: log.reqId })
  }
}))
