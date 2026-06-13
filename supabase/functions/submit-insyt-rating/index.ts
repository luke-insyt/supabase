// submit-insyt-rating — write path for the insyt-rating feature.
//
// Mirrors the gating model of get-insyt-content (the read path): a sibling
// service-role function that owns the eligibility check so the rules live in
// one place. Reasons we don't enforce eligibility purely via RLS:
//
//   * The purchase check joins public.purchases (keyed by buyer_email +
//     insyts.insyt_id varchar) against public.insyts.id (uuid). Expressing
//     that translation in an RLS WITH CHECK is fragile and duplicates the
//     logic already in get-insyt-content.
//   * Symmetric mental model: body reads and rating writes both go through
//     a service-role edge function. One place to change the gating rules.
//
// Eligibility rules (asymmetric with get-insyt-content on purpose):
//   * Creators of an insyt CANNOT rate it (would inflate their own averages).
//     get-insyt-content lets creators read their own body; ratings do not.
//   * Purchasers CAN rate. Anyone else gets a 403.
//
// Request:
//   POST /functions/v1/submit-insyt-rating
//   Authorization: Bearer <user JWT>
//   { "insyt_id": "<insyts.insyt_id varchar>", "rating": 4.5 }
//
//   The `insyt_id` field carries the varchar id (== Webflow item id) that
//   the frontend reads from #insyt-id-raw — same shape get-insyt-content
//   expects. The function looks up the uuid PK internally before writing
//   insyt_ratings (whose FK references public.insyts.id, the uuid).
//
// Response (200): { rating_avg, rating_count, your_rating }
// Errors: 400 invalid_rating | 401 missing_auth | 403 not_eligible
//         | 404 insyt_not_found | 500 internal_error

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, apikey, content-type, x-client-info',
}

const VALID_RATINGS = new Set([0.5, 1.0, 1.5, 2.0, 2.5, 3.0, 3.5, 4.0, 4.5, 5.0])

const json = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  })

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders })
  }

  try {
    const authHeader = req.headers.get('Authorization')
    if (!authHeader) {
      return json(401, { error: 'missing_auth' })
    }

    const { insyt_id, rating } = await req.json()
    if (!insyt_id || typeof insyt_id !== 'string') {
      return json(400, { error: 'invalid_request', details: 'insyt_id required' })
    }
    const ratingNum = typeof rating === 'number' ? rating : Number(rating)
    if (!Number.isFinite(ratingNum) || !VALID_RATINGS.has(ratingNum)) {
      return json(400, { error: 'invalid_rating' })
    }

    const userClient = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SB_PUBLISHABLE')!,
      { global: { headers: { Authorization: authHeader } } }
    )

    const { data: { user }, error: userError } = await userClient.auth.getUser()
    if (userError) {
      return json(401, { error: 'invalid_token', details: userError.message })
    }
    if (!user?.email) {
      return json(401, { error: 'no_user_email' })
    }

    const serviceClient = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SB_SERVICE_SECRET')!
    )

    // Resolve the uuid PK + creator email by the varchar insyt_id (matches
    // the lookup pattern in get-insyt-content).
    const { data: insyt, error: insytError } = await serviceClient
      .from('insyts')
      .select('id, creator_email, price_eur, creator_auth_user_id')
      .eq('insyt_id', insyt_id)
      .maybeSingle()

    if (insytError) {
      return json(500, { error: 'insyts_query_failed', details: insytError.message })
    }
    if (!insyt) {
      return json(404, { error: 'insyt_not_found' })
    }

    // Creator block — asymmetric with get-insyt-content. Documented in
    // webflow-app-documentation/features/insyt-rating-features.md §4.2.
    const isCreator =
      typeof insyt.creator_email === 'string' &&
      insyt.creator_email.toLowerCase() === user.email.toLowerCase()
    if (isCreator) {
      return json(403, { error: 'not_eligible', reason: 'creator_cannot_rate_own_insyt' })
    }

    // Free insyts (price_eur = 0) are readable by any authenticated user, so
    // they're rateable without a purchase row — mirror get-insyt-content's
    // access model. Paid insyts require a purchase OR an active subscription to
    // the creator (subscribers read every insyt by that creator, so they may
    // rate them too — same access model as get-insyt-content).
    const isFree = Number(insyt.price_eur) === 0
    if (!isFree) {
      // Purchase check — same shape as get-insyt-content's purchase branch.
      const { data: purchase, error: purchaseError } = await serviceClient
        .from('purchases')
        .select('id')
        .eq('buyer_email', user.email)
        .eq('insyt_id', insyt_id)
        .maybeSingle()
      if (purchaseError) {
        return json(500, { error: 'purchases_query_failed', details: purchaseError.message })
      }

      let eligible = !!purchase
      // No purchase? An active subscription to this insyt's creator also grants it.
      if (!eligible && insyt.creator_auth_user_id) {
        const { data: sub, error: subError } = await serviceClient
          .from('creator_subscriptions')
          .select('id')
          .eq('subscriber_id', user.id)
          .eq('creator_id', insyt.creator_auth_user_id)
          .in('status', ['active', 'trialing', 'past_due'])
          .maybeSingle()
        if (subError) {
          return json(500, { error: 'subscription_query_failed', details: subError.message })
        }
        eligible = !!sub
      }
      if (!eligible) {
        return json(403, { error: 'not_eligible', reason: 'purchase_or_subscription_required' })
      }
    }

    // Upsert. PK on (insyt_id, user_id) collapses re-rates to one row.
    // updated_at is also bumped by the BEFORE UPDATE trigger
    // touch_insyt_ratings_updated_at — setting it here too so first-time
    // INSERTs have a sensible value without relying on the column default
    // alone (which would equal created_at).
    const { error: upsertError } = await serviceClient
      .from('insyt_ratings')
      .upsert(
        {
          insyt_id: insyt.id,
          user_id: user.id,
          rating: ratingNum,
          updated_at: new Date().toISOString(),
        },
        { onConflict: 'insyt_id,user_id' }
      )

    if (upsertError) {
      return json(500, { error: 'upsert_failed', details: upsertError.message })
    }

    // Re-read the aggregates — the AFTER INSERT/UPDATE trigger
    // insyt_ratings_count_sync has already recomputed insyts.rating_avg +
    // rating_count by this point.
    const { data: refreshed, error: refreshError } = await serviceClient
      .from('insyts')
      .select('rating_avg, rating_count')
      .eq('id', insyt.id)
      .single()

    if (refreshError) {
      return json(500, { error: 'aggregates_read_failed', details: refreshError.message })
    }

    return json(200, {
      rating_avg: refreshed.rating_avg,
      rating_count: refreshed.rating_count,
      your_rating: ratingNum,
    })
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err)
    console.error('[submit-insyt-rating] Unhandled error:', message)
    return json(500, { error: 'internal_error', details: message })
  }
})
