import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

// Cron-facing: apply subscription price changes whose deadline has passed (§13).
// Invoked daily by the n8n Schedule trigger with the service-role key as the
// Bearer token (so the JWT gateway + the explicit check below both gate it — NOT
// browser-callable, deploy WITHOUT --no-verify-jwt). For every row still
// pending_status='pending' with pending_deadline <= now():
//
//   decrease            — swap the Stripe item to the lower price (auto-apply).
//   increase + keep_old — drop the pending change; subscriber stays on old price.
//   increase + cancel   — set cancel_at_period_end on Stripe (ends at period end).
//
// All swaps use proration_behavior=none → the new price bills at the next
// renewal. The subscription is mutated in place. Idempotent: once a row's
// pending state is cleared it no longer matches the query.

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
    console.error('[deadlines] notify webhook failed', err)
  }
}

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

// Record a swept sub's outcome against its change "campaign" (for the creator's
// "N of M accepted" tally). Idempotent; no-op if untracked. Never fatal.
async function recordOutcome(client: any, row: any, outcome: 'accepted' | 'kept_old' | 'canceled') {
  if (!row.pending_change_id) return
  const { error } = await client.from('subscription_price_change_results').upsert(
    { change_id: row.pending_change_id, subscription_id: row.id, subscriber_id: row.subscriber_id, outcome },
    { onConflict: 'change_id,subscription_id', ignoreDuplicates: true }
  )
  if (error) console.error('[deadlines] outcome record failed', error)
}

const BATCH_LIMIT = 500

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })

  try {
    const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
    // Only the service role (n8n cron) may run the sweep — it makes Stripe calls.
    // The gateway (verify-jwt ON) already validated the token's signature, so we
    // only need to confirm the service_role claim. A plain equality check against
    // SUPABASE_SERVICE_ROLE_KEY is brittle: Supabase's new API-key formats mean
    // the injected env value and the legacy service-role JWT n8n holds can both
    // be valid yet differ byte-for-byte (that mismatch 401'd the daily sweep).
    // Decoding (not verifying) the payload is safe because the gateway already
    // proved authenticity; the exact-match below stays as a fallback for a
    // non-JWT secret key.
    const authHeader = req.headers.get('Authorization') || ''
    const token = authHeader.startsWith('Bearer ') ? authHeader.slice(7) : ''
    let isServiceRole = false
    try {
      const payload = JSON.parse(atob(token.split('.')[1] || ''))
      isServiceRole = payload?.role === 'service_role'
    } catch (_) {
      isServiceRole = false
    }
    if (!isServiceRole && authHeader !== 'Bearer ' + serviceKey) {
      return json(401, { error: 'Unauthorized' })
    }

    const stripeKey = Deno.env.get('STRIPE_SECRET_KEY')
    if (!stripeKey) return json(500, { error: 'STRIPE_SECRET_KEY not configured' })

    const serviceClient = createClient(Deno.env.get('SUPABASE_URL')!, serviceKey)

    const { data: due, error: dueError } = await serviceClient
      .from('creator_subscriptions')
      .select('id, subscriber_id, creator_id, status, stripe_subscription_id, pending_kind, pending_fallback, pending_price_id, pending_amount_cents, pending_currency, pending_change_id')
      .eq('pending_status', 'pending')
      .lte('pending_deadline', new Date().toISOString())
      .limit(BATCH_LIMIT)
    if (dueError) return json(500, { error: 'Failed to load due changes', details: dueError.message })

    const summary = { processed: 0, applied_decrease: 0, kept_old: 0, canceled: 0, skipped: 0, errors: 0 }

    for (const row of due ?? []) {
      try {
        // A sub that lapsed/canceled since stamping has nothing to migrate —
        // just drop the pending change.
        if (row.status !== 'active' && row.status !== 'trialing') {
          await serviceClient.from('creator_subscriptions').update({ ...CLEAR_PENDING }).eq('id', row.id)
          summary.skipped++
          continue
        }

        if (row.pending_kind === 'increase' && row.pending_fallback === 'cancel') {
          const form = new URLSearchParams()
          form.set('cancel_at_period_end', 'true')
          const cancel = await stripe('subscriptions/' + row.stripe_subscription_id, stripeKey, form)
          if (!cancel.ok) { console.error('[deadlines] cancel failed', row.id, cancel.data); summary.errors++; continue }
          await serviceClient.from('creator_subscriptions')
            .update({ cancel_at_period_end: true, ...CLEAR_PENDING }).eq('id', row.id)
          // Notify the subscriber their sub is ending (price increase not accepted).
          const { data: people } = await serviceClient
            .from('users')
            .select('auth_user_id, email, display_name')
            .in('auth_user_id', [row.creator_id, row.subscriber_id])
          const subUser = people?.find((p) => p.auth_user_id === row.subscriber_id)
          await notify({
            event: 'price_change_ending',
            creator_id: row.creator_id,
            creator_name: people?.find((p) => p.auth_user_id === row.creator_id)?.display_name || 'A creator',
            new_amount_cents: row.pending_amount_cents,
            currency: row.pending_currency,
            end_date: toIso(cancel.data?.current_period_end),
            subscribers: subUser ? [{ id: subUser.auth_user_id, email: subUser.email, name: subUser.display_name }] : [],
          })
          await recordOutcome(serviceClient, row, 'canceled')
          summary.canceled++
        } else if (row.pending_kind === 'decrease') {
          // Auto-apply the lower price at next renewal.
          const sub = await stripe('subscriptions/' + row.stripe_subscription_id, stripeKey)
          const itemId = sub.data?.items?.data?.[0]?.id
          if (!sub.ok || !itemId) { console.error('[deadlines] sub fetch failed', row.id, sub.data); summary.errors++; continue }
          const form = new URLSearchParams()
          form.set('items[0][id]', itemId)
          form.set('items[0][price]', row.pending_price_id)
          form.set('proration_behavior', 'none')
          const upd = await stripe('subscriptions/' + row.stripe_subscription_id, stripeKey, form)
          if (!upd.ok) { console.error('[deadlines] decrease swap failed', row.id, upd.data); summary.errors++; continue }
          await serviceClient.from('creator_subscriptions')
            .update({ amount_cents: row.pending_amount_cents, currency: row.pending_currency, ...CLEAR_PENDING })
            .eq('id', row.id)
          await recordOutcome(serviceClient, row, 'accepted')
          summary.applied_decrease++
        } else {
          // increase + keep_old (or any other case): keep the current price.
          await serviceClient.from('creator_subscriptions').update({ ...CLEAR_PENDING }).eq('id', row.id)
          await recordOutcome(serviceClient, row, 'kept_old')
          summary.kept_old++
        }
        summary.processed++
      } catch (rowErr) {
        console.error('[deadlines] row error', row.id, rowErr)
        summary.errors++
      }
    }

    return json(200, summary)
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err)
    console.error('[deadlines] Unhandled error:', message)
    return json(500, { error: 'Internal server error', details: message })
  }
})
