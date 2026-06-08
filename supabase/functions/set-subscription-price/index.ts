import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

// Creator-facing: set (or change) the monthly subscription price for the
// signed-in creator. Creates/reuses a Stripe Product for the creator and
// creates a NEW recurring monthly Price (Stripe prices are immutable), then
// stores the price id + amount + currency + trial on public.users. New
// subscriptions always use the latest price.
//
// EXISTING subscribers (§13): when the price changes in the SAME currency, the
// active/trialing subs are stamped with a pending change (they are NOT migrated
// in Stripe here — the confirm fn / deadline sweep do that):
//   * DECREASE — auto-applies at next renewal (pending_status='pending',
//     kind='decrease', deadline=now → next daily sweep swaps the Stripe item).
//   * INCREASE — needs the subscriber's opt-in (kind='increase', the creator's
//     chosen `fallback`, deadline=now+notice_days). They Accept in /my-insyts;
//     if not, the deadline sweep applies the fallback.
// A currency change or first-time setup affects NEW subscribers only (existing
// keep their old-currency price — cross-currency Stripe migration is unsupported).
//
// Body: { amount_cents: int, currency: string, trial_days?: int,
//         fallback?: 'keep_old'|'cancel', notice_days?: int }
//   amount_cents — minor units, 50..100000 (0.50..1000.00)
//   currency     — ISO 4217 lower-case, e.g. 'eur' | 'usd'
//   trial_days   — optional 0..90, free-trial length for new subscribers
//   fallback     — on an INCREASE, what happens to subscribers who don't accept
//                  by the deadline (default 'keep_old')
//   notice_days  — on an INCREASE, days to accept before the fallback (14..90, default 30)
//
// See webflow-app-documentation/features/creator-subscriptions-features.md §5, §13.

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
// Increase notice window (§13 PC5). The 14-day floor keeps a price increase
// legally safe; default 30. Decreases ignore this (they auto-apply).
const MIN_NOTICE_DAYS = 14
const MAX_NOTICE_DAYS = 90
const DEFAULT_NOTICE_DAYS = 30
const DAY_MS = 86400000
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

    // Price-change knobs — only consulted when this turns out to be an INCREASE
    // with existing subscribers, but validate eagerly so the modal gets feedback.
    const fallback = payload.fallback == null ? 'keep_old' : String(payload.fallback)
    if (fallback !== 'keep_old' && fallback !== 'cancel') {
      return json(400, { error: "fallback must be 'keep_old' or 'cancel'" })
    }
    const noticeDays = payload.notice_days == null ? DEFAULT_NOTICE_DAYS : Number(payload.notice_days)
    if (!Number.isInteger(noticeDays) || noticeDays < MIN_NOTICE_DAYS || noticeDays > MAX_NOTICE_DAYS) {
      return json(400, { error: `notice_days must be an integer between ${MIN_NOTICE_DAYS} and ${MAX_NOTICE_DAYS}` })
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
      .select('auth_user_id, email, display_name, is_creator, stripe_subscription_product_id, stripe_subscription_price_id, subscription_price_usd, subscription_currency')
      .eq('auth_user_id', user.id)
      .maybeSingle()
    if (creatorError) return json(500, { error: 'Failed to load creator', details: creatorError.message })
    if (!creator) return json(404, { error: 'No creator profile for this user' })
    if (!creator.is_creator) return json(403, { error: 'Only creators can set a subscription price' })

    const stripeKey = Deno.env.get('STRIPE_SECRET_KEY')
    if (!stripeKey) return json(500, { error: 'STRIPE_SECRET_KEY not configured' })

    // Snapshot the price BEFORE we overwrite it on the users row, so we can tell
    // increase from decrease for the existing-subscriber migration below.
    const prevAmount = creator.subscription_price_usd as number | null
    const prevCurrency = (creator.subscription_currency as string | null)?.toLowerCase() ?? null
    const hadPrice = creator.stripe_subscription_price_id != null && prevAmount != null

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

    // ── Existing-subscriber migration (§13) ────────────────────────────────
    // Only when there was a prior price in the SAME currency and the amount
    // actually changed. First-time setup or a currency change → new subscribers
    // only (existing keep their old-currency price); nothing to stamp.
    let changeKind: 'increase' | 'decrease' | null = null
    if (hadPrice && prevCurrency === currency && amountCents !== prevAmount) {
      changeKind = amountCents > (prevAmount as number) ? 'increase' : 'decrease'
    }

    let affectedCount = 0
    if (changeKind) {
      // A decrease applies on the next daily sweep (deadline=now); an increase
      // waits for the subscriber to accept, up to the notice deadline.
      const deadlineMs = changeKind === 'increase' ? Date.now() + noticeDays * DAY_MS : Date.now()
      const pending = {
        pending_price_id: price.data.id,
        pending_amount_cents: amountCents,
        pending_currency: currency,
        pending_kind: changeKind,
        pending_fallback: changeKind === 'increase' ? fallback : null,
        pending_deadline: new Date(deadlineMs).toISOString(),
        pending_status: 'pending',
      }
      // Stamp every live (active/trialing) sub for this creator in one update.
      // past_due subs in dunning are intentionally excluded — they migrate, if
      // ever, only after they recover to active. Returns the affected rows so we
      // can notify their subscribers.
      const { data: stamped, error: stampError } = await serviceClient
        .from('creator_subscriptions')
        .update(pending)
        .eq('creator_id', user.id)
        .in('status', ['active', 'trialing'])
        .select('id, subscriber_id')
      if (stampError) {
        // Price is already saved for new subs; don't fail the whole call on a
        // migration-stamp error — surface it so the creator can retry.
        console.error('[set-subscription-price] pending stamp failed', stampError)
        return json(500, { error: 'Price saved, but failed to migrate existing subscribers', details: stampError.message })
      }
      affectedCount = stamped?.length ?? 0

      // Fire-and-forget notice to n8n (which owns email). No-op until the
      // N8N_PRICE_CHANGE_WEBHOOK_URL secret is set (phase 5). Never fatal.
      if (affectedCount > 0) {
        const notifyUrl = Deno.env.get('N8N_PRICE_CHANGE_WEBHOOK_URL')
        if (notifyUrl) {
          try {
            const ids = (stamped ?? []).map((s) => s.subscriber_id)
            const { data: subUsers } = await serviceClient
              .from('users')
              .select('auth_user_id, email, display_name')
              .in('auth_user_id', ids)
            await fetch(notifyUrl, {
              method: 'POST',
              headers: { 'Content-Type': 'application/json' },
              body: JSON.stringify({
                event: 'subscription_price_change',
                kind: changeKind,
                creator_id: user.id,
                creator_name: creator.display_name,
                old_amount_cents: prevAmount,
                new_amount_cents: amountCents,
                currency,
                fallback: pending.pending_fallback,
                deadline: pending.pending_deadline,
                subscribers: (subUsers ?? []).map((u) => ({
                  id: u.auth_user_id,
                  email: u.email,
                  name: u.display_name,
                })),
              }),
            })
          } catch (notifyErr) {
            console.error('[set-subscription-price] notify webhook failed', notifyErr)
          }
        }
      }
    }

    return json(200, {
      stripe_price_id: price.data.id,
      amount_cents: amountCents,
      currency,
      trial_days: trialDays,
      change_kind: changeKind,          // null | 'increase' | 'decrease'
      affected_subscribers: affectedCount,
      fallback: changeKind === 'increase' ? fallback : null,
      notice_days: changeKind === 'increase' ? noticeDays : null,
    })
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err)
    console.error('[set-subscription-price] Unhandled error:', message)
    return json(500, { error: 'Internal server error', details: message })
  }
})
