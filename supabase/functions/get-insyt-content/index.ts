import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, apikey, content-type',
}

// deploy: redeploy trigger 2026-05-11
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
      return json(403, { error: 'No purchase found for this user and insyt' })
    }

    const { data: insyt, error: insytError } = await serviceClient
      .from('insyts')
      .select('id, body_html, video_url')
      .eq('insyt_id', insyt_id)
      .maybeSingle()

    if (insytError) {
      return json(500, { error: 'Failed to query insyts', details: insytError.message })
    }
    if (!insyt) {
      return json(404, { error: 'Insyt not found', insyt_id })
    }

    const { data: rawAttachments, error: attachmentsError } = await serviceClient
      .from('insyt_attachments')
      .select('id, kind, bucket, storage_path, filename, mime, position')
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
    })
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err)
    console.error('[get-insyt-content] Unhandled error:', message)
    return json(500, { error: 'Internal server error', details: message })
  }
})
