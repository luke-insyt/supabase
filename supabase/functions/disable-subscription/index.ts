import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

// Creator-facing: stop offering a monthly subscription. Archives the creator's
// Stripe Price and clears users.stripe_subscription_price_id so the offer
// disappears everywhere (hasSubOffer → false) and nobody new can subscribe.
// The creator chooses how EXISTING active/trialing subscribers are handled:
//   * 'keep'   — stop new sign-ups only; current subs keep billing on the now
//                archived Price until they cancel themselves. (outcome 'kept_old')
//   * 'cancel' — end at period end: set cancel_at_period_end on each sub now, so
//                Stripe ends it natively at its own current_period_end. No mid-
//                period cut, no proration. (outcome 'canceled')
//
// Reuses the price-change campaign tables (kind='disable'); does NOT touch the
// pending_* columns or the deadline sweep (those stay price-change-only).
// Re-enabling later is just set-subscription-price (mints a fresh Price).
//
// Idempotent / resumable: all work keys off one kind='disable' campaign row + the
// per-sub subscription_price_change_results UNIQUE(change_id, subscription_id).
// A crash mid-loop is recovered on re-run — it does NOT rely on the offer still
// being set; it finds the recent campaign and processes only unstamped subs.
//
// Body: { choice: 'keep' | 'cancel' }
// See webflow-app-documentation/features/disable-subscription/feature.md §6.1.

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, apikey, content-type, x-client-info',
}

const json = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  })

// Reuse window: a kind='disable' campaign created within this window is treated
// as the same in-progress disable (resume), not a fresh one.
const RESUME_WINDOW_MS = 60 * 60 * 1000 // 1 hour

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
    const choice = String(payload.choice || '')
    if (choice !== 'keep' && choice !== 'cancel') {
      return json(400, { error: "choice must be 'keep' or 'cancel'" })
    }

    const userClient = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_ANON_KEY')!,
      { global: { headers: { Authorization: authHeader } } }
    )
    const {
      data: { user },
      error: userError,
    } = await userClient.auth.getUser()
    if (userError || !user) return json(401, { error: 'Invalid or expired token' })

    const serviceClient = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
    )

    const { data: creator, error: creatorError } = await serviceClient
      .from('users')
      .select(
        'auth_user_id, display_name, is_creator, stripe_subscription_price_id, subscription_price_usd, subscription_currency'
      )
      .eq('auth_user_id', user.id)
      .maybeSingle()
    if (creatorError) return json(500, { error: 'Failed to load creator', details: creatorError.message })
    if (!creator) return json(404, { error: 'No creator profile for this user' })
    if (!creator.is_creator) return json(403, { error: 'Only creators can disable a subscription' })

    const stripeKey = Deno.env.get('STRIPE_SECRET_KEY')
    if (!stripeKey) return json(500, { error: 'STRIPE_SECRET_KEY not configured' })

    const priceId = creator.stripe_subscription_price_id as string | null
    const prevAmount = (creator.subscription_price_usd as number | null) ?? 0
    const prevCurrency = ((creator.subscription_currency as string | null) ?? 'eur').toLowerCase()

    // ── Find-or-create the disable campaign (resume key) ──────────────────────
    const { data: recent } = await serviceClient
      .from('subscription_price_changes')
      .select('id, fallback, created_at')
      .eq('creator_id', user.id)
      .eq('kind', 'disable')
      .order('created_at', { ascending: false })
      .limit(1)
      .maybeSingle()

    const recentOpen =
      recent && Date.now() - new Date(recent.created_at as string).getTime() < RESUME_WINDOW_MS
        ? recent
        : null

    // Nothing to do: no live offer AND no in-progress disable to resume.
    if (!priceId && !recentOpen) {
      return json(409, { error: 'No active subscription offer to disable' })
    }

    // The campaign's stored fallback is the source of truth on resume so a retry
    // with a different choice can't flip already-stamped subs.
    const fallback = recentOpen ? (recentOpen.fallback as string) : choice === 'cancel' ? 'cancel' : 'keep_old'
    const outcome = fallback === 'cancel' ? 'canceled' : 'kept_old'

    let campaignId = recentOpen?.id as string | undefined
    if (!campaignId) {
      // to_* / currency are NOT NULL — a disable has no real target Price, so
      // mirror the archived one.
      const { data: change, error: changeErr } = await serviceClient
        .from('subscription_price_changes')
        .insert({
          creator_id: user.id,
          from_price_id: priceId,
          to_price_id: priceId, // mirror — no real target
          from_amount_cents: prevAmount,
          to_amount_cents: prevAmount, // mirror
          currency: prevCurrency,
          kind: 'disable',
          fallback,
          affected_count: 0,
        })
        .select('id')
        .single()
      if (changeErr || !change) {
        return json(500, { error: 'Failed to record disable', details: changeErr?.message })
      }
      campaignId = change.id
    }

    // ── Clear the public offer (idempotent) ───────────────────────────────────
    if (priceId) {
      // Archive the Stripe Price (active=false) — existing subs keep billing on it;
      // it just can't start NEW subscriptions.
      const archiveForm = new URLSearchParams()
      archiveForm.set('active', 'false')
      const archived = await stripe('prices/' + priceId, stripeKey, archiveForm)
      if (!archived.ok) {
        console.error('[disable-subscription] price archive failed', archived.data)
        return json(archived.status, { error: 'Stripe price archive error', details: archived.data })
      }
      const { error: updErr } = await serviceClient
        .from('users')
        .update({ stripe_subscription_price_id: null, updated_at: new Date().toISOString() })
        .eq('auth_user_id', user.id)
      if (updErr) return json(500, { error: 'Failed to clear offer', details: updErr.message })
      await serviceClient
        .from('subscription_prices')
        .update({ is_active: false })
        .eq('creator_id', user.id)
        .eq('is_active', true)
    }

    // ── Process existing subscribers (only those not yet stamped this campaign) ─
    const { data: liveSubs, error: subsErr } = await serviceClient
      .from('creator_subscriptions')
      .select('id, subscriber_id, stripe_subscription_id, status, current_period_end')
      .eq('creator_id', user.id)
      .in('status', ['active', 'trialing'])
    if (subsErr) return json(500, { error: 'Failed to load subscribers', details: subsErr.message })

    const { data: done } = await serviceClient
      .from('subscription_price_change_results')
      .select('subscription_id')
      .eq('change_id', campaignId)
    const doneIds = new Set((done ?? []).map((r) => r.subscription_id as string))
    const todo = (liveSubs ?? []).filter((s) => !doneIds.has(s.id as string))

    const notifiedSubs: { subscriber_id: string; end_date: string | null }[] = []
    for (const sub of todo) {
      if (fallback === 'cancel') {
        const subId = sub.stripe_subscription_id as string | null
        if (subId) {
          const cancelForm = new URLSearchParams()
          cancelForm.set('cancel_at_period_end', 'true')
          const res = await stripe('subscriptions/' + subId, stripeKey, cancelForm)
          if (!res.ok) {
            // Leave this sub unstamped so a re-run retries it; surface and stop.
            console.error('[disable-subscription] stripe cancel_at_period_end failed', res.data)
            return json(res.status, { error: 'Stripe subscription update error', details: res.data })
          }
        }
        await serviceClient
          .from('creator_subscriptions')
          .update({ cancel_at_period_end: true, cancel_reason: 'creator_disabled', updated_at: new Date().toISOString() })
          .eq('id', sub.id)
        notifiedSubs.push({
          subscriber_id: sub.subscriber_id as string,
          end_date: (sub.current_period_end as string | null) ?? null,
        })
      }
      // Record the outcome AFTER the Stripe call so a failure leaves it for retry.
      await serviceClient
        .from('subscription_price_change_results')
        .upsert(
          {
            change_id: campaignId,
            subscription_id: sub.id,
            subscriber_id: sub.subscriber_id,
            outcome,
            resolved_at: new Date().toISOString(),
          },
          { onConflict: 'change_id,subscription_id', ignoreDuplicates: true }
        )
    }

    // Finalize the campaign's affected_count (total stamped across runs).
    const totalAffected = doneIds.size + todo.length
    await serviceClient
      .from('subscription_price_changes')
      .update({ affected_count: totalAffected })
      .eq('id', campaignId)

    // ── Notify subscribers (cancel path only) — fire-and-forget to n8n ────────
    if (fallback === 'cancel' && notifiedSubs.length > 0) {
      const notifyUrl = Deno.env.get('N8N_PRICE_CHANGE_WEBHOOK_URL')
      if (notifyUrl) {
        try {
          const endBySub: Record<string, string | null> = {}
          notifiedSubs.forEach((s) => {
            endBySub[s.subscriber_id] = s.end_date
          })
          const { data: subUsers } = await serviceClient
            .from('users')
            .select('auth_user_id, email, display_name')
            .in(
              'auth_user_id',
              notifiedSubs.map((s) => s.subscriber_id)
            )
          await fetch(notifyUrl, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
              event: 'subscription_disabled',
              creator_id: user.id,
              creator_name: creator.display_name,
              currency: prevCurrency,
              amount_cents: prevAmount,
              subscribers: (subUsers ?? []).map((u) => ({
                id: u.auth_user_id,
                email: u.email,
                name: u.display_name,
                end_date: endBySub[u.auth_user_id as string] ?? null,
              })),
            }),
          })
        } catch (notifyErr) {
          console.error('[disable-subscription] notify webhook failed', notifyErr)
        }
      }
    }

    return json(200, {
      disabled: true,
      choice: fallback === 'cancel' ? 'cancel' : 'keep',
      affected_subscribers: totalAffected,
    })
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err)
    console.error('[disable-subscription] Unhandled error:', message)
    return json(500, { error: 'Internal server error', details: message })
  }
})
