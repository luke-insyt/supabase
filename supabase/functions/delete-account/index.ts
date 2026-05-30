// Self-service account deletion. The caller can only delete THEIR OWN account:
// we identify them from their JWT, then use the service role to (1) remove their
// Webflow Creators CMS item if they have one, and (2) delete the auth user.
//
// Deleting the auth user cascades to all rows keyed by auth.users(id):
//   - public.users            (users_id_fkey ... ON DELETE CASCADE)
//   - public.user_social_links (user_id ... ON DELETE CASCADE)
//   - public.creator_expertise (user_id ... ON DELETE CASCADE)
//   - public.follows           (follower_id / creator_id ... ON DELETE CASCADE)
//   - public.insyt_ratings     (user_id ... ON DELETE CASCADE)
//
// Intentionally NOT deleted:
//   - public.insyts   — keyed by creator_email, and BUYERS may have paid for them.
//                       Orphaning the rows keeps purchasers' access intact.
//   - public.purchases — historical financial record (keyed by buyer_email).
//
// Browser-callable: deploy with --no-verify-jwt (the function validates the
// Bearer token itself). Requires a `{ confirm: true }` body so a stray call
// can't nuke an account.
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, apikey, content-type, x-client-info',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}

const json = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  })

const WEBFLOW_API_TOKEN = (Deno.env.get('WEBFLOW_API_TOKEN') || '').trim()
const WEBFLOW_CREATORS_COLLECTION_ID = (Deno.env.get('WEBFLOW_CREATORS_COLLECTION_ID') || '').trim()
const WEBFLOW_API = 'https://api.webflow.com/v2'

async function wf(path: string, init?: RequestInit) {
  const resp = await fetch(`${WEBFLOW_API}${path}`, {
    ...init,
    headers: {
      Authorization: `Bearer ${WEBFLOW_API_TOKEN}`,
      'Content-Type': 'application/json',
      accept: 'application/json',
      ...(init?.headers || {}),
    },
  })
  const text = await resp.text()
  let body: unknown = text
  try { body = JSON.parse(text) } catch { /* keep as text */ }
  return { ok: resp.ok, status: resp.status, body }
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })
  if (req.method !== 'POST') return json(405, { error: 'Method not allowed' })

  const authHeader = req.headers.get('Authorization')
  if (!authHeader) return json(401, { error: 'Missing Authorization header' })

  let payload: { confirm?: boolean } = {}
  try { payload = await req.json() } catch { /* empty body */ }
  if (payload.confirm !== true) {
    return json(400, { error: 'Account deletion requires { confirm: true }' })
  }

  const userClient = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_ANON_KEY')!,
    { global: { headers: { Authorization: authHeader } } },
  )
  const svc = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
  )

  const { data: authResult, error: authError } = await userClient.auth.getUser()
  if (authError || !authResult?.user) return json(401, { error: 'Invalid session' })

  const authUserId = authResult.user.id

  // 1. Best-effort: remove the Webflow Creators CMS item so the public
  //    /creators/<id> profile disappears. Non-blocking — a Webflow failure
  //    must not prevent the auth deletion below.
  try {
    if (WEBFLOW_API_TOKEN && WEBFLOW_CREATORS_COLLECTION_ID) {
      const { data: userRow } = await svc
        .from('users')
        .select('webflow_creator_id')
        .eq('auth_user_id', authUserId)
        .maybeSingle()
      const itemId = userRow?.webflow_creator_id as string | null
      if (itemId) {
        // Unpublish from the live site, then delete the staged item.
        await wf(`/collections/${WEBFLOW_CREATORS_COLLECTION_ID}/items/${itemId}/live`, { method: 'DELETE' })
        await wf(`/collections/${WEBFLOW_CREATORS_COLLECTION_ID}/items/${itemId}`, { method: 'DELETE' })
      }
    }
  } catch (err) {
    console.warn('[delete-account] Webflow cleanup failed (continuing):', err)
  }

  // 2. Delete the auth user — cascades all auth-FK-keyed rows (see header).
  const { error: delErr } = await svc.auth.admin.deleteUser(authUserId)
  if (delErr) {
    console.error('[delete-account] admin.deleteUser failed:', delErr)
    return json(500, { error: 'Failed to delete account', details: delErr.message })
  }

  return json(200, { success: true })
})
