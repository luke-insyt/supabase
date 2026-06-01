import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, apikey, content-type, x-client-info',
}

const SIGNED_URL_TTL_SECONDS = 3600
const PUBLIC_BUCKETS = new Set(['insyt-thumbnails'])

type Attachment = {
  id: string | null
  kind: 'video' | 'pdf' | 'image' | 'thumbnail'
  bucket: string
  storage_path: string
  filename: string | null
  mime: string | null
  position: number | null
  width: number | null
  height: number | null
  signed_url: string | null
}

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
      return json(401, { error: 'Missing Authorization header' })
    }

    const { insyt_id } = await req.json()
    if (!insyt_id) {
      return json(400, { error: 'Missing insyt_id' })
    }

    const userClient = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_ANON_KEY')!,
      { global: { headers: { Authorization: authHeader } } }
    )

    const { data: { user }, error: userError } = await userClient.auth.getUser()
    if (userError) {
      return json(401, { error: 'Invalid or expired token', details: userError.message })
    }
    if (!user?.email) {
      return json(401, { error: 'No email on user record' })
    }

    const serviceClient = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
    )

    // Fetch the insyt first so we can grant access to its creator without
    // requiring them to "buy" their own content. Body/video are needed for
    // both the creator and a paying buyer, so this query is not wasted in
    // either branch.
    const { data: insyt, error: insytError } = await serviceClient
      .from('insyts')
      .select('id, body_html, video_url, creator_email, price_eur, creator_auth_user_id')
      .eq('insyt_id', insyt_id)
      .maybeSingle()

    if (insytError) {
      return json(500, { error: 'Failed to query insyts', details: insytError.message })
    }
    if (!insyt) {
      return json(404, { error: 'Insyt not found', insyt_id })
    }

    const isCreator =
      typeof insyt.creator_email === 'string' &&
      insyt.creator_email.toLowerCase() === user.email.toLowerCase()

    // Free insyts (price_eur = 0) are readable by any authenticated user
    // without a purchase row — the content should be visible immediately.
    const isFree = Number(insyt.price_eur) === 0

    // How access was granted (for the client CTA): one-off purchase vs an
    // active subscription to the creator. Free + creator paths leave both false.
    let viaSubscription = false
    if (!isCreator && !isFree) {
      const { data: purchase, error: purchaseError } = await serviceClient
        .from('purchases')
        .select('id')
        .eq('buyer_email', user.email)
        .eq('insyt_id', insyt_id)
        .maybeSingle()

      if (purchaseError) {
        return json(500, { error: 'Failed to query purchases', details: purchaseError.message })
      }

      if (!purchase) {
        // No one-off purchase — an active subscription to this creator unlocks
        // ALL their insyts. past_due is honoured so access is kept during the
        // retry/grace window; only a canceled sub loses access. Subscriptions
        // are keyed on the creator's auth uid (insyts.creator_auth_user_id,
        // denormalised in the follows migration 20260529130000).
        if (insyt.creator_auth_user_id) {
          const { data: sub, error: subError } = await serviceClient
            .from('creator_subscriptions')
            .select('id')
            .eq('subscriber_id', user.id)
            .eq('creator_id', insyt.creator_auth_user_id)
            .in('status', ['active', 'trialing', 'past_due'])
            .maybeSingle()
          if (subError) {
            return json(500, { error: 'Failed to query subscriptions', details: subError.message })
          }
          viaSubscription = !!sub
        }
        if (!viaSubscription) {
          return json(403, { error: 'No purchase or active subscription for this user and insyt' })
        }
      }
    }

    // Record a unique view — only now that access is granted, and never for the
    // creator viewing their own insyt. Idempotent: the upsert on the
    // (insyt_id, user_id) PK just bumps last_viewed_at for a returning viewer,
    // so the distinct count (insyts.view_count, via the AFTER INSERT trigger)
    // only grows on a genuinely new viewer. Best-effort: a failure here must
    // never block content delivery.
    if (!isCreator) {
      try {
        const { error: viewError } = await serviceClient
          .from('insyt_views')
          .upsert(
            { insyt_id: insyt.id, user_id: user.id, last_viewed_at: new Date().toISOString() },
            { onConflict: 'insyt_id,user_id' }
          )
        if (viewError) console.error('[get-insyt-content] view record failed', viewError.message)
      } catch (viewErr) {
        console.error('[get-insyt-content] view record threw', viewErr)
      }
    }

    const { data: rawAttachments, error: attachmentsError } = await serviceClient
      .from('insyt_attachments')
      .select('id, kind, bucket, storage_path, filename, mime, position, width, height')
      .eq('insyt_id', insyt.id)
      .order('kind', { ascending: true })
      .order('position', { ascending: true, nullsFirst: false })

    if (attachmentsError) {
      return json(500, { error: 'Failed to query attachments', details: attachmentsError.message })
    }

    const attachments: Omit<Attachment, 'signed_url'>[] = (rawAttachments ?? []).map((a) => ({
      id: a.id,
      kind: a.kind,
      bucket: a.bucket,
      storage_path: a.storage_path,
      filename: a.filename,
      mime: a.mime,
      position: a.position,
      width: a.width,
      height: a.height,
    }))

    // Back-compat: legacy insyts written before insyt_attachments existed have only
    // insyts.video_url (storage Key like "insyt-videos/<file>") and no attachment rows.
    // Synthesize a video attachment so older purchases still render.
    const hasVideo = attachments.some((a) => a.kind === 'video')
    if (!hasVideo && insyt.video_url) {
      const [legacyBucket, ...rest] = String(insyt.video_url).split('/')
      const legacyPath = rest.join('/')
      if (legacyBucket && legacyPath) {
        attachments.push({
          id: null,
          kind: 'video',
          bucket: legacyBucket,
          storage_path: legacyPath,
          filename: null,
          mime: null,
          position: 0,
          width: null,
          height: null,
        })
      }
    }

    const enriched: Attachment[] = await Promise.all(
      attachments.map(async (a) => {
        let signed_url: string | null = null
        if (PUBLIC_BUCKETS.has(a.bucket)) {
          const { data } = serviceClient.storage.from(a.bucket).getPublicUrl(a.storage_path)
          signed_url = data?.publicUrl ?? null
        } else {
          const { data, error } = await serviceClient.storage
            .from(a.bucket)
            .createSignedUrl(a.storage_path, SIGNED_URL_TTL_SECONDS)
          if (error) {
            console.warn('[get-insyt-content] sign failed', a.bucket, a.storage_path, error.message)
          }
          signed_url = data?.signedUrl ?? null
        }
        return { ...a, signed_url }
      })
    )

    const videoAttachment = enriched.find((a) => a.kind === 'video')

    return json(200, {
      body_html: insyt.body_html ?? null,
      video_url: videoAttachment?.signed_url ?? null,
      attachments: enriched,
      // How access was granted, so the client can render the right CTA state
      // without a flash (free → no "purchased" badge, creator → own content,
      // subscription → "Subscribed" rather than "Purchased").
      is_free: isFree,
      is_creator: isCreator,
      via_subscription: viaSubscription,
    })
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err)
    console.error('[get-insyt-content] Unhandled error:', message)
    return json(500, { error: 'Internal server error', details: message })
  }
})
