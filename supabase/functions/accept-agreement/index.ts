import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, apikey, content-type, x-client-info',
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders })
  }

  try {
    const { auth_user_id, email, signature_name, version, ip } = await req.json()

    if (!auth_user_id || !email || !signature_name || !version) {
      return new Response(
        JSON.stringify({ error: 'Missing required fields' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      )
    }

    const supabase = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SB_SERVICE_SECRET')!
    )

    const { data: userRow, error: userLookupError } = await supabase
      .from('users')
      .select('id')
      .eq('auth_user_id', auth_user_id)
      .maybeSingle()

    if (userLookupError) {
      return new Response(
        JSON.stringify({ error: userLookupError.message }),
        { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      )
    }

    if (!userRow) {
      return new Response(
        JSON.stringify({ error: 'User not found' }),
        { status: 404, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      )
    }

    const acceptedAt = new Date().toISOString()

    const { error: acceptanceError } = await supabase
      .from('agreement_acceptances')
      .insert({
        auth_user_id,
        email,
        signature_name,
        version,
        ip: ip ?? null,
        accepted_at: acceptedAt,
      })

    if (acceptanceError) {
      return new Response(
        JSON.stringify({ error: acceptanceError.message }),
        { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      )
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
      .eq('auth_user_id', auth_user_id)

    if (userError) {
      return new Response(
        JSON.stringify({ error: userError.message }),
        { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      )
    }

    return new Response(
      JSON.stringify({ success: true }),
      { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    )
  } catch (err) {
    return new Response(
      JSON.stringify({ error: 'Internal server error' }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    )
  }
})
