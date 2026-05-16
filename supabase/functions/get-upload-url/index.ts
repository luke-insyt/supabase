// Issues a short-lived Supabase Storage signed upload URL for the
// create-insyt-native two-phase upload flow. See submit-create-insyt
// for the matching submit/draft handler.
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

type Role = 'cover' | 'image' | 'video'

const ROLE_BUCKETS: Record<Role, string> = {
  cover: 'insyt-thumbnails',
  image: 'insyt-images',
  video: 'insyt-videos',
}

const ROLE_MAX_BYTES: Record<Role, number> = {
  cover: 5  * 1024 * 1024,
  image: 10 * 1024 * 1024,
  video: 100 * 1024 * 1024,
}

function safeName(name: string): string {
  return name.replace(/[^a-zA-Z0-9._-]/g, '_').slice(0, 120) || 'file'
}

function uuidRe(): RegExp {
  return /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders })
  }
  if (req.method !== 'POST') {
    return json(405, { error: 'Method not allowed' })
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
  if (!uuidRe().test(authUserId)) return json(401, { error: 'Invalid auth user id' })

  const { data: userRow } = await svc
    .from('users')
    .select('is_creator')
    .eq('auth_user_id', authUserId)
    .maybeSingle()
  if (!userRow?.is_creator) return json(403, { error: 'Not an active creator' })

  let body: {
    role?: Role
    correlation_id?: string
    filename?: string
    size_bytes?: number
  }
  try {
    body = await req.json()
  } catch {
    return json(400, { error: 'Invalid JSON body' })
  }

  const role = body.role
  if (!role || !(role in ROLE_BUCKETS)) {
    return json(400, { error: 'role must be one of: cover, image, video' })
  }

  const correlation_id = String(body.correlation_id || '').trim()
  if (!uuidRe().test(correlation_id)) {
    return json(400, { error: 'correlation_id must be a UUID' })
  }

  const filename = safeName(String(body.filename || ''))
  const size = Number(body.size_bytes || 0)
  if (!size || size <= 0) return json(400, { error: 'size_bytes is required' })
  if (size > ROLE_MAX_BYTES[role]) {
    return json(413, {
      error: `File too large for ${role}; max ${ROLE_MAX_BYTES[role]} bytes`,
    })
  }

  const bucket = ROLE_BUCKETS[role]
  const path = `${authUserId}/${correlation_id}/${role}-${Date.now()}-${filename}`

  const { data: signed, error: signError } = await svc
    .storage
    .from(bucket)
    .createSignedUploadUrl(path)

  if (signError || !signed) {
    return json(500, { error: signError?.message || 'Failed to create signed URL' })
  }

  return json(200, {
    bucket,
    path,
    token: signed.token,
    signed_url: signed.signedUrl,
  })
})
