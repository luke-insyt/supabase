import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, apikey, content-type',
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
      .select('body_html, video_url')
      .eq('insyt_id', insyt_id)
      .maybeSingle()

    if (insytError) {
      return json(500, { error: 'Failed to query insyts', details: insytError.message })
    }
    if (!insyt) {
      return json(404, { error: 'Insyt not found', insyt_id })
    }

    let videoSignedUrl: string | null = null
    if (insyt.video_url) {
      const videoPath = insyt.video_url.replace(/^insyt-videos\//, '')
      const { data: signed, error: signError } = await serviceClient.storage
        .from('insyt-videos')
        .createSignedUrl(videoPath, 3600)

      if (signError) {
        return json(500, { error: 'Failed to sign video URL', details: signError.message, videoPath })
      }
      videoSignedUrl = signed?.signedUrl ?? null
    }

    return json(200, {
      body_html: insyt.body_html ?? null,
      video_url: videoSignedUrl,
    })

  } catch (err) {
    const message = err instanceof Error ? err.message : String(err)
    console.error('[get-insyt-content] Unhandled error:', message)
    return json(500, { error: 'Internal server error', details: message })
  }
})
