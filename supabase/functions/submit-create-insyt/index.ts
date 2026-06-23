// Handles the create-insyt-native submit/draft lifecycle: validates the
// creator + payload, then forwards "submit" to the n8n pipeline with a
// shared secret. See get-upload-url for the matching upload-URL issuer.
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
import { withLogging } from '../_shared/log.ts'
import type { GiLogger } from '../_shared/log.ts'

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

type Action =
  | 'save_draft'
  | 'submit'
  | 'discard'
  | 'load_draft'
  | 'list_drafts'
  | 'purchase_status'
  | 'update_published'
  | 'confirm_update'

type Attachment = {
  bucket: string
  path: string
  kind: 'thumbnail' | 'image' | 'video' | 'pdf'
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
  pdfs?: Attachment[]
  message?: string         // confirm_update: creator's optional note to buyers (GET-71)
}

const N8N_CREATE_INSYT_URL = (Deno.env.get('N8N_CREATE_INSYT_URL') || '').trim()
const N8N_SECRET           = (Deno.env.get('CREATE_INSYT_N8N_SECRET') || '').trim()
// Fire-and-forget "an insyt you bought was updated" dispatch (GET-71). New env
// var; when unset the confirm_update path simply skips the notify fetch — the
// insyts row + audit row are still written, buyers just aren't emailed yet.
const N8N_INSYT_UPDATED_WEBHOOK_URL = (Deno.env.get('N8N_INSYT_UPDATED_WEBHOOK_URL') || '').trim()

const uuidRe = /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/

Deno.serve(withLogging('submit-create-insyt', corsHeaders, async (req, log) => {
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
    Deno.env.get('SB_PUBLISHABLE')!,
    { global: { headers: { Authorization: authHeader } } },
  )
  const svc = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SB_SERVICE_SECRET')!,
  )

  const { data: authResult, error: authError } = await userClient.auth.getUser()
  if (authError || !authResult?.user) return json(401, { error: 'Invalid session' })

  const authUserId = authResult.user.id
  const creatorEmail = authResult.user.email
  if (!creatorEmail) return json(401, { error: 'Missing email in token' })

  const { data: userRow } = await svc
    .from('users')
    .select('is_creator, display_name, bio, webflow_creator_id')
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

  if (action === 'list_drafts') {
    return await listDrafts(svc, creatorEmail)
  }

  if (action === 'discard') {
    return await discardDraft(svc, creatorEmail, payload)
  }

  // ── Edit-published (GET-71) ────────────────────────────────────────────────
  // purchase_status is read-only (early heads-up): owner-gate + return the
  // one-time buyer count. It needs neither correlation_id nor attachment
  // validation, so it short-circuits before the create/draft payload checks.
  if (action === 'purchase_status') {
    const insytId = String(payload.insyt_id || '').trim()
    const gate = await assertOwner(svc, insytId, authUserId, creatorEmail)
    if ('error' in gate) return json(gate.status, { error: gate.error })
    return json(200, { buyer_count: await buyerCount(svc, insytId) })
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
    ...(payload.pdfs || []),
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

  if (action === 'update_published') {
    return await updatePublished(svc, {
      authUserId,
      creatorEmail,
      correlation_id,
      payload,
      userRow,
      log,
    })
  }

  if (action === 'confirm_update') {
    return await confirmUpdate(svc, {
      authUserId,
      creatorEmail,
      correlation_id,
      payload,
      userRow,
      log,
    })
  }

  // action === 'submit' — forward to n8n
  if (!N8N_CREATE_INSYT_URL) {
    return json(500, { error: 'N8N_CREATE_INSYT_URL is not configured' })
  }

  const forwardBody = buildCreateForwardBody({
    authUserId,
    creatorEmail,
    webflowCreatorId: userRow?.webflow_creator_id || null,
    correlation_id,
    payload,
    title,
    priceCents,
    isFree,
  })

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
    log.error('n8n unreachable', { err: (err as Error).message })
    return json(502, { error: `Failed to reach n8n: ${(err as Error).message}`, reqId: log.reqId })
  }

  const n8nText = await n8nResp.text()
  let n8nBody: unknown = n8nText
  try { n8nBody = JSON.parse(n8nText) } catch { /* keep as text */ }

  if (!n8nResp.ok) {
    log.error('n8n rejected the submission', { status: n8nResp.status, detail: n8nBody })
    return json(502, { error: 'n8n rejected the submission', detail: n8nBody, reqId: log.reqId })
  }

  return json(200, {
    success: true,
    correlation_id,
    n8n: n8nBody,
  })
}))

async function loadDraft(svc: ReturnType<typeof createClient>, creatorEmail: string) {
  const sevenDaysAgo = new Date(Date.now() - 7 * 24 * 60 * 60 * 1000).toISOString()
  const { data, error } = await svc
    .from('insyts')
    .select('*, insyt_attachments(*)')
    .eq('creator_email', creatorEmail)
    .eq('status', 'draft')
    .gte('created_at', sevenDaysAgo)
    .order('updated_at', { ascending: false })
    .limit(1)
    .maybeSingle()

  if (error) return json(500, { error: error.message })
  return json(200, { draft: data || null })
}

// Returns up to 10 of the creator's most-recently-edited drafts (≤7 days old).
// Each row is the full draft including its attachments, so the frontend can
// hydrate any of them via the same path as the single-draft resume banner —
// no second round-trip needed when the user picks one.
async function listDrafts(svc: ReturnType<typeof createClient>, creatorEmail: string) {
  const sevenDaysAgo = new Date(Date.now() - 7 * 24 * 60 * 60 * 1000).toISOString()
  const { data, error } = await svc
    .from('insyts')
    .select('*, insyt_attachments(*)')
    .eq('creator_email', creatorEmail)
    .eq('status', 'draft')
    .gte('created_at', sevenDaysAgo)
    .order('updated_at', { ascending: false })
    .limit(10)

  if (error) return json(500, { error: error.message })
  return json(200, { drafts: data || [] })
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
    body_html: String(payload.full_text || '').trim() || null,
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
    // correlation_id is intentionally NOT updated — it's fixed at first insert
    // so the {user_id}/{correlation_id}/ prefix on attachment paths stays valid
    // for the lifetime of the draft, including across resume sessions.
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
      .insert({ ...row, correlation_id: args.correlation_id })
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
    ...((payload.pdfs || []).map((a, i) => ({ ...a, kind: 'pdf' as const, position: i + 1 }))),
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

// ─── Edit-published shared helpers (GET-71) ──────────────────────────────────

type Svc = ReturnType<typeof createClient>

type OwnedInsyt = {
  id: string
  insyt_id: string | null
  creator_email: string | null
  creator_auth_user_id: string | null
  status: string | null
  title: string | null
  abstract: string | null
  content_type: string | null
  sport: string | null
  body_html: string | null
  price_eur: number | null
  tags: string[] | null
  thumbnail_url: string | null
}

type OwnerGate = OwnedInsyt | { error: string; status: number }

// Owner gate (AC-3): the caller's JWT must own this insyt and the insyt must be
// published/live (not a draft — drafts use the resume path). Identity comes
// from the verified token (authUserId/creatorEmail), never the client body.
async function assertOwner(
  svc: Svc,
  insytId: string,
  authUserId: string,
  creatorEmail: string,
): Promise<OwnerGate> {
  if (!insytId) return { error: 'insyt_id is required', status: 400 }
  const { data, error } = await svc
    .from('insyts')
    .select(
      'id, insyt_id, creator_email, creator_auth_user_id, status, title, abstract, content_type, sport, body_html, price_eur, tags, thumbnail_url',
    )
    .eq('insyt_id', insytId)
    .maybeSingle()
  if (error) return { error: error.message, status: 500 }
  if (!data) return { error: 'Insyt not found', status: 404 }
  const row = data as OwnedInsyt
  const owns =
    (row.creator_auth_user_id && row.creator_auth_user_id === authUserId) ||
    (row.creator_email && row.creator_email.toLowerCase() === creatorEmail.toLowerCase())
  if (!owns) return { error: 'Not your insyt', status: 403 }
  if (row.status !== 'published' && row.status !== 'live') {
    return { error: 'Only published insyts can be edited', status: 409 }
  }
  return row
}

// One-time buyer count for this insyt. Subscriptions are intentionally NOT
// counted (AC-2) — only rows in `purchases` with a non-null buyer_email.
async function buyerCount(svc: Svc, insytId: string): Promise<number> {
  const { count, error } = await svc
    .from('purchases')
    .select('insyt_id', { count: 'exact', head: true })
    .eq('insyt_id', insytId)
    .not('buyer_email', 'is', null)
  if (error) return 0
  return count || 0
}

// Distinct buyer emails for this insyt (recipient list for the update email).
async function distinctBuyers(svc: Svc, insytId: string): Promise<string[]> {
  const { data, error } = await svc
    .from('purchases')
    .select('buyer_email')
    .eq('insyt_id', insytId)
    .not('buyer_email', 'is', null)
  if (error || !data) return []
  const seen = new Set<string>()
  for (const r of data as { buyer_email: string | null }[]) {
    if (r.buyer_email) seen.add(r.buyer_email)
  }
  return Array.from(seen)
}

// Build the insyts row from the submitted payload, reusing save_draft's field
// mapping. Used by both update_published and confirm_update so the persisted
// shape is identical. (Does NOT set status — an edit keeps it published.)
function buildPublishedRow(payload: Payload) {
  return {
    title: String(payload.title || '').trim(),
    abstract: String(payload.description || '').trim() || ' ',
    content_type: String(payload.content_type || '').trim() || null,
    sport: String(payload.sport || '').trim() || 'soccer',
    body_html: String(payload.full_text || '').trim() || null,
    price_eur: payload.is_free ? 0 : Number(payload.price_cents || 0),
    tags: payload.tags || [],
    thumbnail_url: payload.cover?.path || null,
  }
}

// No-op guard (D-5): true when the submitted editable fields + media are
// byte-identical to what's stored, so saving would change nothing. Compares the
// mapped row fields and the full attachment set (cover + images + videos +
// pdfs) by storage path.
async function isNoOpEdit(
  svc: Svc,
  stored: OwnedInsyt,
  row: ReturnType<typeof buildPublishedRow>,
  payload: Payload,
): Promise<boolean> {
  const fieldsSame =
    String(stored.title || '') === row.title &&
    String(stored.abstract || '') === row.abstract &&
    (stored.content_type || null) === row.content_type &&
    (stored.sport || '') === row.sport &&
    (stored.body_html || null) === row.body_html &&
    Number(stored.price_eur || 0) === Number(row.price_eur || 0) &&
    JSON.stringify(stored.tags || []) === JSON.stringify(row.tags || []) &&
    (stored.thumbnail_url || null) === row.thumbnail_url
  if (!fieldsSame) return false

  // Compare media by the set of storage paths (order-independent).
  const submittedPaths = [
    ...(payload.cover ? [payload.cover.path] : []),
    ...(payload.images || []).map(a => a.path),
    ...(payload.videos || []).map(a => a.path),
    ...(payload.pdfs || []).map(a => a.path),
  ]
    .filter(Boolean)
    .sort()
  const { data: atts } = await svc
    .from('insyt_attachments')
    .select('storage_path')
    .eq('insyt_id', stored.id)
  const storedPaths = ((atts as { storage_path: string | null }[] | null) || [])
    .map(a => a.storage_path)
    .filter(Boolean)
    .sort()
  return JSON.stringify(submittedPaths) === JSON.stringify(storedPaths)
}

// Build the n8n create-insyt webhook body. Shared by `submit` (create) and the
// edit re-publish path; `is_edit` tells n8n to re-sync the existing Webflow CMS
// item instead of creating a new one.
function buildCreateForwardBody(args: {
  authUserId: string
  creatorEmail: string
  webflowCreatorId: string | null
  correlation_id: string
  payload: Payload
  title: string
  priceCents: number
  isFree: boolean
  is_edit?: boolean
}) {
  const supabaseUrl = Deno.env.get('SUPABASE_URL') || ''
  const env = supabaseUrl.includes('krapqgxrqprtajatxjzd') ? 'production' : 'staging'
  return {
    env,
    auth_user_id: args.authUserId,
    creator_email: args.creatorEmail,
    // null when the creator hasn't synced their profile yet. n8n should
    // skip the `creator` reference field on the Insyts CMS item in that
    // case; the binding falls back to creator-email until the next sync.
    webflow_creator_id: args.webflowCreatorId,
    correlation_id: args.correlation_id,
    insyt_id: args.payload.insyt_id || null,
    is_edit: !!args.is_edit,
    sport: args.payload.sport,
    content_type: args.payload.content_type,
    title: args.title,
    description: args.payload.description || '',
    full_text: args.payload.full_text || '',
    price_cents: args.isFree ? 0 : args.priceCents,
    is_free: args.isFree,
    tags: args.payload.tags || [],
    cover: args.payload.cover || null,
    images: args.payload.images || [],
    videos: args.payload.videos || [],
    pdfs: args.payload.pdfs || [],
  }
}

// Persist the edited insyts row in place (D-2) + resync attachments, then
// re-run the publish pipeline (n8n create-insyt, is_edit:true). Mirrors how
// saveDraft writes the row + attachments, but keeps the row published.
async function persistEditAndRepublish(
  svc: Svc,
  args: {
    stored: OwnedInsyt
    authUserId: string
    creatorEmail: string
    webflowCreatorId: string | null
    correlation_id: string
    payload: Payload
    row: ReturnType<typeof buildPublishedRow>
    log: GiLogger
  },
): Promise<{ error: string; status: number } | null> {
  const { stored, payload, row } = args
  const { error: upErr } = await svc
    .from('insyts')
    .update({ ...row, updated_at: new Date().toISOString() })
    .eq('id', stored.id)
  if (upErr) return { error: upErr.message, status: 500 }

  // Resync attachments (same add/remove strategy as saveDraft — avoids orphans).
  await svc.from('insyt_attachments').delete().eq('insyt_id', stored.id)
  const atts: Attachment[] = [
    ...(payload.cover ? [{ ...payload.cover, kind: 'thumbnail' as const, position: 0 }] : []),
    ...((payload.images || []).map((a, i) => ({ ...a, kind: 'image' as const, position: i + 1 }))),
    ...((payload.videos || []).map((a, i) => ({ ...a, kind: 'video' as const, position: i + 1 }))),
    ...((payload.pdfs || []).map((a, i) => ({ ...a, kind: 'pdf' as const, position: i + 1 }))),
  ]
  if (atts.length > 0) {
    const rows = atts.map(a => ({
      insyt_id: stored.id,
      kind: a.kind,
      bucket: a.bucket,
      storage_path: a.path,
      filename: a.filename || null,
      mime: a.mime || null,
      size_bytes: a.size_bytes || null,
      position: a.position ?? null,
    }))
    const { error: attErr } = await svc.from('insyt_attachments').insert(rows)
    if (attErr) console.error('[submit-create-insyt] edit attachment insert failed', attErr)
  }

  // Re-run publish (fire the n8n create-insyt webhook with is_edit:true). The
  // row is already saved (source of truth, D-2); a re-sync failure is logged
  // and surfaced as a non-blocking warning rather than losing the edit.
  if (N8N_CREATE_INSYT_URL) {
    const forwardBody = buildCreateForwardBody({
      authUserId: args.authUserId,
      creatorEmail: args.creatorEmail,
      webflowCreatorId: args.webflowCreatorId,
      correlation_id: args.correlation_id,
      payload,
      title: row.title,
      priceCents: Number(row.price_eur || 0),
      isFree: !!payload.is_free,
      is_edit: true,
    })
    try {
      const resp = await fetch(N8N_CREATE_INSYT_URL, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'x-create-insyt-secret': N8N_SECRET },
        body: JSON.stringify(forwardBody),
      })
      if (!resp.ok) {
        args.log.warn('edit republish: n8n rejected re-sync', { status: resp.status })
      }
    } catch (err) {
      args.log.warn('edit republish: n8n unreachable', { err: (err as Error).message })
    }
  }
  return null
}

// ─── update_published (GET-71) ───────────────────────────────────────────────
// Owner-gate, no-op guard (D-5), then branch on one-time purchase count:
//   0 buyers  → persist + re-publish immediately, no email  → { purchased:false }
//   ≥1 buyers → no write yet; client must confirm           → { purchased:true }
async function updatePublished(
  svc: Svc,
  args: {
    authUserId: string
    creatorEmail: string
    correlation_id: string
    payload: Payload
    userRow: { webflow_creator_id?: string | null } | null
    log: GiLogger
  },
) {
  const insytId = String(args.payload.insyt_id || '').trim()
  const gate = await assertOwner(svc, insytId, args.authUserId, args.creatorEmail)
  if ('error' in gate) return json(gate.status, { error: gate.error })

  const row = buildPublishedRow(args.payload)
  if (await isNoOpEdit(svc, gate, row, args.payload)) {
    return json(200, { noop: true })
  }

  const n = await buyerCount(svc, insytId)
  if (n >= 1) {
    // Don't write yet — the client shows the confirm modal and re-sends on confirm.
    return json(200, { purchased: true, buyer_count: n })
  }

  const persistErr = await persistEditAndRepublish(svc, {
    stored: gate,
    authUserId: args.authUserId,
    creatorEmail: args.creatorEmail,
    webflowCreatorId: args.userRow?.webflow_creator_id || null,
    correlation_id: args.correlation_id,
    payload: args.payload,
    row,
    log: args.log,
  })
  if (persistErr) return json(persistErr.status, { error: persistErr.error })
  return json(200, { purchased: false })
}

// ─── confirm_update (GET-71) ─────────────────────────────────────────────────
// Re-validates owner + no-op, persists + re-publishes, writes one audit row,
// then fires the fire-and-forget insyt_updated n8n webhook to each distinct
// buyer. Returns { sent: <number of buyers> }.
async function confirmUpdate(
  svc: Svc,
  args: {
    authUserId: string
    creatorEmail: string
    correlation_id: string
    payload: Payload & { message?: string }
    userRow: { webflow_creator_id?: string | null; display_name?: string | null } | null
    log: GiLogger
  },
) {
  const insytId = String(args.payload.insyt_id || '').trim()
  const gate = await assertOwner(svc, insytId, args.authUserId, args.creatorEmail)
  if ('error' in gate) return json(gate.status, { error: gate.error })

  const row = buildPublishedRow(args.payload)
  if (await isNoOpEdit(svc, gate, row, args.payload)) {
    return json(200, { noop: true })
  }

  const persistErr = await persistEditAndRepublish(svc, {
    stored: gate,
    authUserId: args.authUserId,
    creatorEmail: args.creatorEmail,
    webflowCreatorId: args.userRow?.webflow_creator_id || null,
    correlation_id: args.correlation_id,
    payload: args.payload,
    row,
    log: args.log,
  })
  if (persistErr) return json(persistErr.status, { error: persistErr.error })

  const buyers = await distinctBuyers(svc, insytId)
  const message = String(args.payload.message || '').trim() || null

  // Audit row (D-4): one row per confirmed update. sent_at defaults to now().
  const { error: auditErr } = await svc.from('insyt_update_notifications').insert({
    insyt_id: insytId,
    creator_email: args.creatorEmail,
    buyer_count: buyers.length,
    message,
  })
  if (auditErr) args.log.warn('insyt_update_notifications insert failed', { err: auditErr.message })

  // Fire-and-forget buyer-notify dispatch — never blocks the creator's save.
  if (N8N_INSYT_UPDATED_WEBHOOK_URL && buyers.length > 0) {
    const supabaseUrl = Deno.env.get('SUPABASE_URL') || ''
    const env = supabaseUrl.includes('krapqgxrqprtajatxjzd') ? 'production' : 'staging'
    const notifyBody = {
      event: 'insyt_updated',
      env,
      insyt_id: insytId,
      insyt_title: row.title,
      creator_id: args.authUserId,
      creator_name: args.userRow?.display_name || null,
      creator_email: args.creatorEmail,
      message,
      buyers: buyers.map(email => ({ email })),
    }
    try {
      await fetch(N8N_INSYT_UPDATED_WEBHOOK_URL, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'x-create-insyt-secret': N8N_SECRET },
        body: JSON.stringify(notifyBody),
      })
    } catch (err) {
      args.log.warn('insyt_updated dispatch failed', { err: (err as Error).message })
    }
  }

  return json(200, { sent: buyers.length })
}
