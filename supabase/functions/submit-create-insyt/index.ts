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

type Action = 'save_draft' | 'submit' | 'discard' | 'load_draft'

type Attachment = {
  bucket: string
  path: string
  kind: 'thumbnail' | 'image' | 'video'
  filename?: string
  mime?: string
  size_bytes?: number
  position?: number
}

type Payload = {
  action?: Action
  insyt_id?: string         // present when updating an existing draft
  correlation_id?: string
  sport?: string
  content_type?: string
  title?: string
  description?: string
  full_text?: string
  price_cents?: number
  is_free?: boolean
  tags?: string[]
  cover?: Attachment | null
  images?: Attachment[]
  videos?: Attachment[]
}

const N8N_CREATE_INSYT_URL = (Deno.env.get('N8N_CREATE_INSYT_URL') || '').trim()
const N8N_SECRET           = (Deno.env.get('CREATE_INSYT_N8N_SECRET') || '').trim()

const uuidRe = /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/

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
  const creatorEmail = authResult.user.email
  if (!creatorEmail) return json(401, { error: 'Missing email in token' })

  const { data: userRow } = await svc
    .from('users')
    .select('is_creator')
    .eq('auth_user_id', authUserId)
    .maybeSingle()
  if (!userRow?.is_creator) return json(403, { error: 'Not an active creator' })

  let payload: Payload
  try {
    payload = await req.json()
  } catch {
    return json(400, { error: 'Invalid JSON body' })
  }

  const action = payload.action || 'submit'

  if (action === 'load_draft') {
    return await loadDraft(svc, creatorEmail)
  }

  if (action === 'discard') {
    return await discardDraft(svc, creatorEmail, payload)
  }

  // save_draft + submit both validate payload similarly
  const correlation_id = String(payload.correlation_id || '').trim()
  if (!uuidRe.test(correlation_id)) {
    return json(400, { error: 'correlation_id must be a UUID' })
  }

  const title = String(payload.title || '').trim()
  if (action === 'submit') {
    if (!title) return json(400, { error: 'Title is required' })
    if (title.length > 150) return json(400, { error: 'Title exceeds 150 characters' })
    if (!String(payload.sport || '').trim()) return json(400, { error: 'Sport is required' })
  }

  const priceCents = Number(payload.price_cents || 0)
  const isFree = !!payload.is_free
  if (action === 'submit' && !isFree) {
    if (!Number.isFinite(priceCents) || priceCents < 100 || priceCents > 1_000_000) {
      return json(400, { error: 'price_cents must be between 100 and 1000000' })
    }
  }

  // Verify any provided attachment paths belong to this creator + correlation_id.
  const allAttachments: Attachment[] = [
    ...(payload.cover ? [payload.cover] : []),
    ...(payload.images || []),
    ...(payload.videos || []),
  ]
  const expectedPrefix = `${authUserId}/${correlation_id}/`
  for (const a of allAttachments) {
    if (!a?.path?.startsWith(expectedPrefix)) {
      return json(400, { error: `Attachment path must start with ${expectedPrefix}` })
    }
  }

  if (action === 'save_draft') {
    return await saveDraft(svc, {
      authUserId,
      creatorEmail,
      correlation_id,
      payload,
      insyt_id: payload.insyt_id,
    })
  }

  // action === 'submit' — forward to n8n
  if (!N8N_CREATE_INSYT_URL) {
    return json(500, { error: 'N8N_CREATE_INSYT_URL is not configured' })
  }

  const supabaseUrl = Deno.env.get('SUPABASE_URL') || ''
  const env = supabaseUrl.includes('krapqgxrqprtajatxjzd') ? 'production' : 'staging'

  const forwardBody = {
    env,
    auth_user_id: authUserId,
    creator_email: creatorEmail,
    correlation_id,
    insyt_id: payload.insyt_id || null,
    sport: payload.sport,
    content_type: payload.content_type,
    title,
    description: payload.description || '',
    full_text: payload.full_text || '',
    price_cents: isFree ? 0 : priceCents,
    is_free: isFree,
    tags: payload.tags || [],
    cover: payload.cover || null,
    images: payload.images || [],
    videos: payload.videos || [],
  }

  let n8nResp: Response
  try {
    n8nResp = await fetch(N8N_CREATE_INSYT_URL, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'x-create-insyt-secret': N8N_SECRET,
      },
      body: JSON.stringify(forwardBody),
    })
  } catch (err) {
    return json(502, { error: `Failed to reach n8n: ${(err as Error).message}` })
  }

  const n8nText = await n8nResp.text()
  let n8nBody: unknown = n8nText
  try { n8nBody = JSON.parse(n8nText) } catch { /* keep as text */ }

  if (!n8nResp.ok) {
    return json(502, { error: 'n8n rejected the submission', detail: n8nBody })
  }

  return json(200, {
    success: true,
    correlation_id,
    n8n: n8nBody,
  })
})

async function loadDraft(svc: ReturnType<typeof createClient>, creatorEmail: string) {
  const sevenDaysAgo = new Date(Date.now() - 7 * 24 * 60 * 60 * 1000).toISOString()
  const { data, error } = await svc
    .from('insyts')
    .select('*, insyt_attachments(*)')
    .eq('creator_email', creatorEmail)
    .eq('status', 'draft')
    .gte('created_at', sevenDaysAgo)
    .order('created_at', { ascending: false })
    .limit(1)
    .maybeSingle()

  if (error) return json(500, { error: error.message })
  return json(200, { draft: data || null })
}

async function discardDraft(
  svc: ReturnType<typeof createClient>,
  creatorEmail: string,
  payload: Payload,
) {
  const insytId = String(payload.insyt_id || '').trim()
  if (!uuidRe.test(insytId)) return json(400, { error: 'insyt_id must be a UUID' })

  const { data: row, error: fetchError } = await svc
    .from('insyts')
    .select('id, creator_email, status')
    .eq('id', insytId)
    .maybeSingle()

  if (fetchError) return json(500, { error: fetchError.message })
  if (!row) return json(404, { error: 'Draft not found' })
  if (row.creator_email !== creatorEmail) return json(403, { error: 'Not your draft' })
  if (row.status !== 'draft') return json(409, { error: 'Only drafts can be discarded' })

  // Delete attachments + storage objects.
  const { data: atts } = await svc
    .from('insyt_attachments')
    .select('bucket, storage_path')
    .eq('insyt_id', insytId)

  for (const att of atts || []) {
    if (att.bucket && att.storage_path) {
      await svc.storage.from(att.bucket).remove([att.storage_path])
    }
  }

  await svc.from('insyt_attachments').delete().eq('insyt_id', insytId)
  const { error: delError } = await svc.from('insyts').delete().eq('id', insytId)
  if (delError) return json(500, { error: delError.message })

  return json(200, { success: true })
}

async function saveDraft(
  svc: ReturnType<typeof createClient>,
  args: {
    authUserId: string
    creatorEmail: string
    correlation_id: string
    insyt_id?: string
    payload: Payload
  },
) {
  const { creatorEmail, payload, insyt_id } = args

  const row = {
    title: String(payload.title || '').trim() || 'Untitled draft',
    abstract: String(payload.description || '').trim() || ' ',
    content_type: String(payload.content_type || '').trim() || null,
    sport: String(payload.sport || '').trim() || 'soccer',
    body_text: String(payload.full_text || '').trim() || null,
    price_eur: payload.is_free ? 0 : Number(payload.price_cents || 0),
    tags: payload.tags || [],
    creator_email: creatorEmail,
    status: 'draft',
    is_hidden: true,
    thumbnail_url: payload.cover?.path || null,
    updated_at: new Date().toISOString(),
  }

  let savedId: string | null = null

  if (insyt_id) {
    // Update existing draft (must belong to this creator and still be a draft).
    const { data, error } = await svc
      .from('insyts')
      .update(row)
      .eq('id', insyt_id)
      .eq('creator_email', creatorEmail)
      .eq('status', 'draft')
      .select('id')
      .maybeSingle()
    if (error) return json(500, { error: error.message })
    if (!data) return json(404, { error: 'Draft not found or not yours' })
    savedId = data.id as string
  } else {
    const { data, error } = await svc
      .from('insyts')
      .insert(row)
      .select('id')
      .single()
    if (error) return json(500, { error: error.message })
    savedId = data.id as string
  }

  // Sync attachments: drop existing rows, re-insert from payload.
  await svc.from('insyt_attachments').delete().eq('insyt_id', savedId)

  const atts: Attachment[] = [
    ...(payload.cover ? [{ ...payload.cover, kind: 'thumbnail' as const, position: 0 }] : []),
    ...((payload.images || []).map((a, i) => ({ ...a, kind: 'image' as const, position: i + 1 }))),
    ...((payload.videos || []).map((a, i) => ({ ...a, kind: 'video' as const, position: i + 1 }))),
  ]

  if (atts.length > 0) {
    const rows = atts.map(a => ({
      insyt_id: savedId,
      kind: a.kind,
      bucket: a.bucket,
      storage_path: a.path,
      filename: a.filename || null,
      mime: a.mime || null,
      size_bytes: a.size_bytes || null,
      position: a.position ?? null,
    }))
    const { error: attError } = await svc.from('insyt_attachments').insert(rows)
    if (attError) console.error('[submit-create-insyt] attachment insert failed', attError)
  }

  return json(200, {
    success: true,
    insyt_id: savedId,
    correlation_id: args.correlation_id,
  })
}
