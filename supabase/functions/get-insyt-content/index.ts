import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, apikey, content-type',
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders })
  }

  try {
    const authHeader = req.headers.get('Authorization')
    if (!authHeader) {
      return new Response(
        JSON.stringify({ error: 'Unauthorized' }),
        { status: 401, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      )
    }

    const { insyt_id } = await req.json()
    if (!insyt_id) {
      return new Response(
        JSON.stringify({ error: 'Missing insyt_id' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      )
    }

    const userClient = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_ANON_KEY')!,
      { global: { headers: { Authorization: authHeader } } }
    )

    const { data: { user }, error: userError } = await userClient.auth.getUser()
    if (userError || !user?.email) {
      return new Response(
        JSON.stringify({ error: 'Unauthorized' }),
        { status: 401, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      )
    }

    const serviceClient = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
    )

    const { data: purchase } = await serviceClient
      .from('purchases')
      .select('id')
      .eq('buyer_email', user.email)
      .eq('insyt_id', insyt_id)
      .maybeSingle()

    if (!purchase) {
      return new Response(
        JSON.stringify({ error: 'Not purchased' }),
        { status: 403, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      )
    }

    const { data: insyt, error: insytError } = await serviceClient
      .from('insyts')
      .select('body_html, video_url')
      .eq('insyt_id', insyt_id)
      .maybeSingle()

    if (insytError || !insyt) {
      return new Response(
        JSON.stringify({ error: 'Insyt not found' }),
        { status: 404, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      )
    }

    let videoSignedUrl: string | null = null
    if (insyt.video_url) {
      const videoPath = insyt.video_url.replace(/^insyt-videos\//, '')
      const { data: signed } = await serviceClient.storage
        .from('insyt-videos')
        .createSignedUrl(videoPath, 3600)
      videoSignedUrl = signed?.signedUrl ?? null
    }

    return new Response(
      JSON.stringify({
        body_html: insyt.body_html ?? null,
        video_url: videoSignedUrl,
      }),
      { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    )

  } catch (err) {
    return new Response(
      JSON.stringify({ error: 'Internal server error' }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    )
  }
})
