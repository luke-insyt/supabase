import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

// Subscriber-facing: respond to a pending subscription price change (§13). The
// /my-insyts "Price change" banner calls this when the subscriber clicks Accept
// or Decline on a sub with pending_status='pending'.
//
//   accept  — swap the existing Stripe subscription item to the pending price
//             with proration_behavior=none (so it bills at the NEXT renewal, not
//             mid-period), then write the new amount/currency onto the row and
//             clear the pending state.
//   decline — apply the creator's chosen fallback now instead of waiting for the
//             deadline: 'keep_old' just clears the pending change (stays on the
//             current price); 'cancel' sets cancel_at_period_end on Stripe.
//
// The subscription is mutated IN PLACE — never a second subscription — so the
// "one subscription at a time" invariant holds.
//
// Body: { subscription_id: uuid, action: 'accept'|'decline' }
//   subscription_id — public.creator_subscriptions.id owned by the caller.
//
// See webflow-app-documentation/features/creator-subscriptions-features.md §13.

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, apikey, content-type, x-client-info',
}

const json = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  })

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

const toIso = (s?: number | null) => (s ? new Date(s * 1000).toISOString() : null)

// Fire-and-forget notice to n8n (which owns email). No-op until the
// N8N_PRICE_CHANGE_WEBHOOK_URL secret is set. Never fatal.
async function notify(payload: Record<string, unknown>) {
  const url = Deno.env.get('N8N_PRICE_CHANGE_WEBHOOK_URL')
  if (!url) return
  try {
    await fetch(url, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload),
    })
  } catch (err) {
    console.error('[confirm-price-change] notify webhook failed', err)
  }
}

// Record this subscriber's outcome against the change "campaign" so the creator
// can see "N of M accepted". Idempotent (unique change_id+subscription_id).
// No-op if the sub wasn't part of a tracked change. Never fatal.
async function recordOutcome(client: any, row: any, outcome: 'accepted' | 'kept_old' | 'canceled') {
  if (!row.pending_change_id) return
  const { error } = await client.from('subscription_price_change_results').upsert(
    { change_id: row.pending_change_id, subscription_id: row.id, subscriber_id: row.subscriber_id, outcome },
    { onConflict: 'change_id,subscription_id', ignoreDuplicates: true }
  )
  if (error) console.error('[confirm-price-change] outcome record failed', error)
}

// Cleared pending columns (steady state).
const CLEAR_PENDING = {
  pending_price_id: null,
  pending_amount_cents: null,
  pending_currency: null,
  pending_kind: null,
  pending_fallback: null,
  pending_deadline: null,
  pending_status: null,
  pending_change_id: null,
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })

  try {
    const authHeader = req.headers.get('Authorization')
    if (!authHeader) return json(401, { error: 'Missing Authorization header' })

    const { subscription_id, action } = await req.json().catch(() => ({}))
    if (!subscription_id || typeof subscription_id !== 'string') {
      return json(400, { error: 'subscription_id is required' })
    }
    if (action !== 'accept' && action !== 'decline') {
      return json(400, { error: "action must be 'accept' or 'decline'" })
    }

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

    const { data: row, error: rowError } = await serviceClient
      .from('creator_subscriptions')
      .select('id, subscriber_id, creator_id, status, stripe_subscription_id, pending_status, pending_kind, pending_fallback, pending_price_id, pending_amount_cents, pending_currency, pending_change_id')
      .eq('id', subscription_id)
      .maybeSingle()
    if (rowError) return json(500, { error: 'Failed to load subscription', details: rowError.message })
    if (!row) return json(404, { error: 'Subscription not found' })
    if (row.subscriber_id !== user.id) return json(403, { error: 'Not your subscription' })
    if (row.pending_status !== 'pending') return json(409, { error: 'No pending price change on this subscription' })
    if (!row.stripe_subscription_id) return json(409, { error: 'Subscription is not active in Stripe' })

    const stripeKey = Deno.env.get('STRIPE_SECRET_KEY')
    if (!stripeKey) return json(500, { error: 'STRIPE_SECRET_KEY not configured' })

    // Creator + subscriber display info for the notice email (one query, both ids).
    const { data: people } = await serviceClient
      .from('users')
      .select('auth_user_id, email, display_name')
      .in('auth_user_id', [row.creator_id, row.subscriber_id])
    const creatorName = people?.find((p) => p.auth_user_id === row.creator_id)?.display_name || 'A creator'
    const subUser = people?.find((p) => p.auth_user_id === row.subscriber_id)
    const subscribers = subUser ? [{ id: subUser.auth_user_id, email: subUser.email, name: subUser.display_name }] : []

    if (action === 'accept') {
      // Swap the subscription item's price. Stripe needs the existing item id, so
      // fetch the subscription first. proration_behavior=none → the new price
      // takes effect at the next renewal; the subscriber keeps the period they
      // already paid for.
      const sub = await stripe('subscriptions/' + row.stripe_subscription_id, stripeKey)
      if (!sub.ok) {
        console.error('[confirm-price-change] subscription fetch failed', sub.data)
        return json(sub.status, { error: 'Stripe subscription error', details: sub.data })
      }
      const itemId = sub.data?.items?.data?.[0]?.id
      if (!itemId) return json(500, { error: 'No subscription item to update' })

      const form = new URLSearchParams()
      form.set('items[0][id]', itemId)
      form.set('items[0][price]', row.pending_price_id)
      form.set('proration_behavior', 'none')
      const upd = await stripe('subscriptions/' + row.stripe_subscription_id, stripeKey, form)
      if (!upd.ok) {
        console.error('[confirm-price-change] price swap failed', upd.data)
        return json(upd.status, { error: 'Stripe price swap error', details: upd.data })
      }

      // Record the agreed price now (the subscription.updated webhook will also
      // sync it from the item — idempotent), and clear the pending state.
      const { error: saveError } = await serviceClient
        .from('creator_subscriptions')
        .update({ amount_cents: row.pending_amount_cents, currency: row.pending_currency, ...CLEAR_PENDING })
        .eq('id', row.id)
      if (saveError) {
        console.error('[confirm-price-change] row update (accept) failed', saveError)
        return json(500, { error: 'Stripe updated but failed to save', details: saveError.message })
      }
      await recordOutcome(serviceClient, row, 'accepted')
      await notify({
        event: 'price_change_accepted',
        env: (Deno.env.get('SUPABASE_URL') ?? '').includes('krapqgxrqprtajatxjzd') ? 'production' : 'staging',
        creator_id: row.creator_id,
        creator_name: creatorName,
        new_amount_cents: row.pending_amount_cents,
        currency: row.pending_currency,
        renews_on: toIso(upd.data?.current_period_end),
        subscribers,
      })
      return json(200, { accepted: true, amount_cents: row.pending_amount_cents, currency: row.pending_currency })
    }

    // action === 'decline' — apply the creator's fallback immediately.
    if (row.pending_fallback === 'cancel') {
      const form = new URLSearchParams()
      form.set('cancel_at_period_end', 'true')
      const cancel = await stripe('subscriptions/' + row.stripe_subscription_id, stripeKey, form)
      if (!cancel.ok) {
        console.error('[confirm-price-change] cancel_at_period_end failed', cancel.data)
        return json(cancel.status, { error: 'Stripe cancel error', details: cancel.data })
      }
      const { error: saveError } = await serviceClient
        .from('creator_subscriptions')
        .update({ cancel_at_period_end: true, ...CLEAR_PENDING })
        .eq('id', row.id)
      if (saveError) {
        console.error('[confirm-price-change] row update (decline/cancel) failed', saveError)
        return json(500, { error: 'Stripe canceled but failed to save', details: saveError.message })
      }
      await recordOutcome(serviceClient, row, 'canceled')
      await notify({
        event: 'price_change_ending',
        env: (Deno.env.get('SUPABASE_URL') ?? '').includes('krapqgxrqprtajatxjzd') ? 'production' : 'staging',
        creator_id: row.creator_id,
        creator_name: creatorName,
        new_amount_cents: row.pending_amount_cents,
        currency: row.pending_currency,
        end_date: toIso(cancel.data?.current_period_end),
        subscribers,
      })
      return json(200, { declined: true, fallback: 'cancel', cancel_at_period_end: true })
    }

    // fallback 'keep_old' (or none) — just drop the pending change; the
    // subscriber stays on their current price.
    const { error: saveError } = await serviceClient
      .from('creator_subscriptions')
      .update({ ...CLEAR_PENDING })
      .eq('id', row.id)
    if (saveError) {
      console.error('[confirm-price-change] row update (decline/keep) failed', saveError)
      return json(500, { error: 'Failed to clear pending change', details: saveError.message })
    }
    await recordOutcome(serviceClient, row, 'kept_old')
    return json(200, { declined: true, fallback: 'keep_old' })
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err)
    console.error('[confirm-price-change] Unhandled error:', message)
    return json(500, { error: 'Internal server error', details: message })
  }
})
