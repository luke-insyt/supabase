import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, apikey, content-type, x-client-info',
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
    // GET-122/SF6: authenticate the caller from their JWT and derive identity FROM THE
    // TOKEN — never from the request body. This edge fn writes a legally-significant
    // signed-terms record and stamps creator_terms_accepted_at; without this an
    // unauthenticated POST (the fn is browser-callable, --no-verify-jwt) could forge an
    // acceptance for any auth_user_id.
    const authHeader = req.headers.get('Authorization')
    if (!authHeader) return json(401, { error: 'Missing Authorization header' })

    const userClient = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SB_PUBLISHABLE')!,
      { global: { headers: { Authorization: authHeader } } }
    )
    const { data: authResult, error: authError } = await userClient.auth.getUser()
    if (authError || !authResult?.user) return json(401, { error: 'Invalid session' })

    const authUserId = authResult.user.id
    const email = authResult.user.email
    if (!email) return json(401, { error: 'Missing email in token' })

    // Signature details still come from the body; identity does NOT.
    const body = await req.json().catch(() => ({}))
    const signature_name = body?.signature_name
    const version = body?.version
    const ip = body?.ip
    if (!signature_name || !version) {
      return json(400, { error: 'Missing required fields' })
    }

    const supabase = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SB_SERVICE_SECRET')!)

    // You may only sign the CURRENT agreement — reject a stale/forged version so the
    // acceptance record can't be pinned to arbitrary terms.
    const { data: currentVersion, error: versionError } = await supabase
      .from('agreement_versions')
      .select('version')
      .eq('is_current', true)
      .maybeSingle()
    if (versionError) return json(500, { error: versionError.message })
    if (!currentVersion || currentVersion.version !== version) {
      return json(409, { error: 'Not the current agreement version' })
    }

    const { data: userRow, error: userLookupError } = await supabase
      .from('users')
      .select('id')
      .eq('auth_user_id', authUserId)
      .maybeSingle()

    if (userLookupError) {
      return json(500, { error: userLookupError.message })
    }
    if (!userRow) {
      return json(404, { error: 'User not found' })
    }

    const acceptedAt = new Date().toISOString()

    const { error: acceptanceError } = await supabase.from('agreement_acceptances').insert({
      auth_user_id: authUserId,
      email,
      signature_name,
      version,
      ip: ip ?? null,
      accepted_at: acceptedAt,
    })

    if (acceptanceError) {
      return json(500, { error: acceptanceError.message })
    }

    // GET-99: accepting the agreement records the signed terms but does NOT make
    // the user a creator. `is_creator` is flipped only once the profile is completed
    // (a display name is saved) — see sync-creator-to-webflow. Accepting terms then
    // abandoning the Create-Profile step previously left a half-created creator
    // (nameless in listings, "Create Insyt" shown, profile page 404). (Decision A:
    // "when no display name is set we should not mark the user as creator.")
    const { error: userError } = await supabase
      .from('users')
      .update({
        agreement_version: version,
        signature_name,
        signature_ip: ip ?? null,
        signed_at: acceptedAt,
        creator_terms_accepted_at: acceptedAt,
      })
      .eq('auth_user_id', authUserId)

    if (userError) {
      return json(500, { error: userError.message })
    }

    return json(200, { success: true })
  } catch (err) {
    return json(500, { error: 'Internal server error' })
  }
})
