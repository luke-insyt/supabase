import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
import { withLogging } from '../_shared/log.ts'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, apikey, content-type, x-client-info',
}

const json = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  })

Deno.serve(withLogging('create-checkout-session', corsHeaders, async (req, log) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders })
  }

  try {
    const authHeader = req.headers.get('Authorization')
    if (!authHeader) {
      return json(401, { error: 'Missing Authorization header' })
    }

    const { insyt_id } = await req.json()
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
      .select('insyt_id, stripe_price_id, creator_email, price_eur')
      .eq('insyt_id', insyt_id)
      .maybeSingle()

    if (insytError) {
      return json(500, { error: 'Failed to query insyts', details: insytError.message })
    }
    if (!insyt) {
      return json(404, { error: 'Insyt not found' })
    }
    if (!insyt.stripe_price_id) {
      return json(409, { error: 'Insyt has no Stripe price (free or pending publish)' })
    }
    if (insyt.creator_email && insyt.creator_email.toLowerCase() === user.email.toLowerCase()) {
      return json(409, { error: 'Creators cannot buy their own insyt' })
    }

    const stripeKey = Deno.env.get('STRIPE_SECRET_KEY')
    if (!stripeKey) {
      return json(500, { error: 'STRIPE_SECRET_KEY not configured' })
    }

    // Mirror the metadata shape the existing Payment Link uses, so the
    // `Purchase Completed` n8n workflow (which reads metadata.insyt_id and
    // customer_details.email) grants access without any change.
    const form = new URLSearchParams()
    form.set('ui_mode', 'embedded')
    form.set('mode', 'payment')
    form.set('line_items[0][price]', insyt.stripe_price_id)
    form.set('line_items[0][quantity]', '1')
    form.set('customer_email', user.email)
    form.set('metadata[insyt_id]', insyt.insyt_id)
    if (insyt.creator_email) {
      form.set('metadata[creator_email]', insyt.creator_email)
    }
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
      client_secret: session.client_secret,
      session_id: session.id,
    })
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err)
    log.error('unhandled', { err: message })
    return json(500, { error: 'Internal server error', details: message, reqId: log.reqId })
  }
}))
