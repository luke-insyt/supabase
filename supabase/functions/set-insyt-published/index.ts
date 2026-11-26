import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
import { requestMeta, SERVER_SECRET_HEADER } from '../_shared/request-meta.ts'
import { currentRulesVersion, recordRulesConfirmation } from '../submit-create-insyt/rules.ts'
import { mayNeedRules, unhideDecision } from './logic.ts'

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
//       + GET-486 B2: rules_confirmation?: { version, ticks } and, from the RN server with a
//         valid x-gi-server-secret, ip / user_agent (see _shared/request-meta.ts)
// See webflow-app-documentation/features/disable-insyt/feature.md §6.
//
// GET-486 B2 (AC3.5): publishing a hidden Insyt back needs the five Content & Image Rules ticks
// when its content changed since the owner's last confirmation or the rules version changed
// (logic.ts). 409 rules_confirmation_required otherwise; with valid ticks an `unhide`
// confirmation is recorded before the flag flips. No current content_rules → no gate.

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': `authorization, apikey, content-type, x-client-info, ${SERVER_SECRET_HEADER}`,
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
      .select('id, insyt_id, creator_email, is_hidden, visibility, content_rev')
      .eq('insyt_id', insytId)
      .maybeSingle()
    if (insytError) return json(500, { error: 'Failed to load insyt', details: insytError.message })
    if (!insyt) return json(404, { error: 'Insyt not found' })

    const ownerEmail = String(insyt.creator_email || '').trim().toLowerCase()
    if (!ownerEmail || ownerEmail !== callerEmail) {
      return json(403, { error: 'You can only publish or unpublish your own insyts' })
    }

    // GET-328 (S7-AC4): a private inquiry insyt can't be unlisted — its
    // requester must always be able to buy it. Covers web and RN (the RN API
    // relays here).
    if (hidden && insyt.visibility === 'private') {
      return json(409, { error: 'An insyt delivered for an inquiry can’t be unlisted while it’s private.' })
    }

    // GET-486 B2: the rules gate on unhide (logic.ts).
    const rules = await currentRulesVersion(serviceClient)
    if (rules.error) return json(500, { error: 'rules_check_failed' })
    let needed = false
    if (mayNeedRules(hidden, !!insyt.is_hidden, rules.version)) {
      const { data: need, error: needErr } = await serviceClient.rpc('rules_confirmation_needed', {
        p_row_id: insyt.id,
      })
      if (needErr) return json(500, { error: 'rules_check_failed' })
      needed = need === true
    }
    const decision = unhideDecision({
      hidden,
      wasHidden: !!insyt.is_hidden,
      current: rules.version,
      needed,
      raw: payload.rules_confirmation,
    })
    if (decision.kind === 'refuse') return json(decision.status, decision.body)
    if (decision.kind === 'record') {
      const meta = requestMeta(req.headers, payload, Deno.env.get('GI_SERVER_SECRET'))
      const refused = await recordRulesConfirmation(serviceClient, rules.version!, {
        authUserId: String(claims.sub),
        correlationId: null,
        rowId: String(insyt.id),
        confirmation: decision.confirmation,
        context: 'unhide',
        contentRev: Number(insyt.content_rev || 0),
        ip: meta.ip,
        userAgent: meta.userAgent,
      })
      if (refused) return json(refused.status, refused.body)
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
