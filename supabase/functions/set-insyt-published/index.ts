import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

// Creator-facing: publish / unpublish ("disable") one of the caller's own insyts by
// toggling insyts.is_hidden. Unpublished (is_hidden=true) insyts drop out of the feed,
// creator-profile cards and the discovery rails (those read paths filter is_hidden);
// buyers keep access (RLS grants buyers/creators read regardless of is_hidden — this is
// only a discovery flag). Reversible: publish again sets is_hidden=false.
//
// Ownership is gated on the CALLER'S JWT (decoded user email must equal the insyt's
// creator_email — mirrors the `insyts` "Creators read own insyts" RLS), never a
// client-sent identity. Mirrors the disable-subscription function's auth shape.
//
// Body: { insyt_id: string, hidden: boolean }   // hidden=true → unpublished
// See webflow-app-documentation/features/disable-insyt/feature.md §6.

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
    const authHeader = req.headers.get('Authorization')
    if (!authHeader) return json(401, { error: 'Missing Authorization header' })

    const payload = await req.json().catch(() => ({}))
    const insytId = String(payload.insyt_id || '').trim()
    if (!insytId) return json(400, { error: 'insyt_id is required' })
    if (typeof payload.hidden !== 'boolean') {
      return json(400, { error: 'hidden must be a boolean' })
    }
    const hidden = payload.hidden as boolean

    const userClient = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SB_PUBLISHABLE')!,
      { global: { headers: { Authorization: authHeader } } }
    )
    // Validate the caller by the token's verified CLAIMS (signature via JWKS), not a
    // session lookup. getUser()/auth/v1/user reject a still-valid token whose server
    // session was rotated/evicted ("session_not_found") — getClaims only checks the
    // signature, so it's correct for both real logins and the e2e's cached tokens.
    const token = authHeader.replace(/^Bearer\s+/i, '')
    const { data: claimsData, error: claimsError } = await userClient.auth.getClaims(token)
    const claims = claimsData && (claimsData.claims as Record<string, unknown> | undefined)
    if (claimsError || !claims || !claims.sub) {
      return json(401, { error: 'Invalid or expired token' })
    }

    const callerEmail = String((claims.email as string) || '')
      .trim()
      .toLowerCase()
    if (!callerEmail) return json(403, { error: 'No email on the caller account' })

    const serviceClient = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SB_SERVICE_SECRET')!
    )

    // Load the target insyt and verify the caller owns it (creator_email match).
    const { data: insyt, error: insytError } = await serviceClient
      .from('insyts')
      .select('insyt_id, creator_email, is_hidden')
      .eq('insyt_id', insytId)
      .maybeSingle()
    if (insytError) return json(500, { error: 'Failed to load insyt', details: insytError.message })
    if (!insyt) return json(404, { error: 'Insyt not found' })

    const ownerEmail = String(insyt.creator_email || '').trim().toLowerCase()
    if (!ownerEmail || ownerEmail !== callerEmail) {
      return json(403, { error: 'You can only publish or unpublish your own insyts' })
    }

    const { error: updError } = await serviceClient
      .from('insyts')
      .update({ is_hidden: hidden })
      .eq('insyt_id', insytId)
    if (updError) return json(500, { error: 'Failed to update insyt', details: updError.message })

    return json(200, { insyt_id: insytId, is_hidden: hidden })
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err)
    console.error('[set-insyt-published] Unhandled error:', message)
    return json(500, { error: 'Internal server error', details: message })
  }
})
