// Upserts the authenticated user's profile into the Webflow CMS
// Creators collection so Insyts items can reference it for display
// name + bio. Called from account.js after a successful save, and
// from submit-create-insyt before forwarding to n8n.
//
// Idempotent: looks up users.webflow_creator_id first; PATCHes when
// present, POSTs and stores the id when absent. Always publishes the
// item so the change is live (Insyts reads the live view).
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}

const json = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  })

const WEBFLOW_API_TOKEN          = (Deno.env.get('WEBFLOW_API_TOKEN') || '').trim()
const WEBFLOW_CREATORS_COLLECTION_ID = (Deno.env.get('WEBFLOW_CREATORS_COLLECTION_ID') || '').trim()

const WEBFLOW_API = 'https://api.webflow.com/v2'

type CreatorFields = {
  name: string
  slug: string
  email: string
  'auth-user-id': string
  bio?: string
  headline?: string
  'profile-image'?: { url: string }
  'joined-date'?: string
  username?: string
  location?: string
  website?: string
  youtube?: string
  instagram?: string
  facebook?: string
  tiktok?: string
}

type SocialPlatform = 'youtube' | 'instagram' | 'facebook' | 'tiktok'
const SOCIAL_PLATFORMS: SocialPlatform[] = ['youtube', 'instagram', 'facebook', 'tiktok']

function buildAvatarUrl(supabaseUrl: string, profileImage: string | null): string | undefined {
  if (!profileImage) return undefined
  if (/^https?:\/\//i.test(profileImage)) return profileImage
  // Bucket is public so the object endpoint resolves directly.
  return `${supabaseUrl.replace(/\/+$/, '')}/storage/v1/object/public/creator-avatars/${profileImage.replace(/^\/+/, '')}`
}

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
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders })
  }
  if (req.method !== 'POST') {
    return json(405, { error: 'Method not allowed' })
  }

  if (!WEBFLOW_API_TOKEN) {
    return json(500, { error: 'WEBFLOW_API_TOKEN is not configured' })
  }
  if (!WEBFLOW_CREATORS_COLLECTION_ID) {
    return json(500, { error: 'WEBFLOW_CREATORS_COLLECTION_ID is not configured' })
  }

  const authHeader = req.headers.get('Authorization')
  if (!authHeader) return json(401, { error: 'Missing Authorization header' })

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
  const email = authResult.user.email
  if (!email) return json(401, { error: 'Missing email in token' })

  const { data: userRow, error: userErr } = await svc
    .from('users')
    .select('display_name, bio, headline, profile_image_url, creator_activated_at, created_at, webflow_creator_id, username, location, website')
    .eq('auth_user_id', authUserId)
    .maybeSingle()
  if (userErr) return json(500, { error: userErr.message })
  if (!userRow) return json(404, { error: 'User row not found' })

  const { data: socialRows, error: socialErr } = await svc
    .from('user_social_links')
    .select('platform, handle')
    .eq('user_id', authUserId)
  if (socialErr) return json(500, { error: socialErr.message })

  const socials: Record<SocialPlatform, string> = { youtube: '', instagram: '', facebook: '', tiktok: '' }
  for (const row of (socialRows || []) as { platform: string; handle: string }[]) {
    if ((SOCIAL_PLATFORMS as string[]).includes(row.platform)) {
      socials[row.platform as SocialPlatform] = (row.handle || '').trim()
    }
  }

  const displayName = (userRow.display_name || '').trim() || email
  const bio = (userRow.bio || '').trim()
  const headline = (userRow.headline || '').trim()
  const username = ((userRow.username as string | null) || '').trim()
  const location = ((userRow.location as string | null) || '').trim()
  const website = ((userRow.website as string | null) || '').trim()
  const profileImage = buildAvatarUrl(
    Deno.env.get('SUPABASE_URL') || '',
    (userRow.profile_image_url as string | null) || null,
  )
  const joinedDate = (userRow.creator_activated_at as string | null) || (userRow.created_at as string | null) || undefined

  const fields: CreatorFields = {
    name: displayName,
    slug: authUserId,
    email,
    'auth-user-id': authUserId,
    bio,
    headline,
    'profile-image': profileImage ? { url: profileImage } : undefined,
    'joined-date': joinedDate,
    username,
    location,
    website,
    youtube: socials.youtube,
    instagram: socials.instagram,
    facebook: socials.facebook,
    tiktok: socials.tiktok,
  }

  let webflowCreatorId = userRow.webflow_creator_id as string | null

  if (webflowCreatorId) {
    // Update + publish the existing Creator item.
    const patch = await wf(`/collections/${WEBFLOW_CREATORS_COLLECTION_ID}/items/${webflowCreatorId}/live`, {
      method: 'PATCH',
      body: JSON.stringify({ fieldData: fields }),
    })
    if (!patch.ok) {
      return json(502, { error: 'Webflow PATCH failed', detail: patch.body })
    }
    return json(200, { success: true, webflow_creator_id: webflowCreatorId, action: 'updated' })
  }

  // Create + publish a new Creator item.
  const create = await wf(`/collections/${WEBFLOW_CREATORS_COLLECTION_ID}/items/live`, {
    method: 'POST',
    body: JSON.stringify({ fieldData: fields }),
  })
  if (!create.ok) {
    return json(502, { error: 'Webflow POST failed', detail: create.body })
  }

  const createdId = (create.body as { id?: string } | null)?.id
  if (!createdId) {
    return json(502, { error: 'Webflow POST returned no id', detail: create.body })
  }

  const { error: updateErr } = await svc
    .from('users')
    .update({ webflow_creator_id: createdId })
    .eq('auth_user_id', authUserId)
  if (updateErr) {
    console.error('[sync-creator-to-webflow] failed to persist webflow_creator_id', updateErr)
    // The Webflow item exists; surface the id so the client can proceed.
  }

  return json(200, { success: true, webflow_creator_id: createdId, action: 'created' })
})
