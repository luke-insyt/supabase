// Handles the create-insyt-native submit/draft lifecycle: validates the
// creator + payload, then forwards "submit" to the n8n pipeline with a
// shared secret. See get-upload-url for the matching upload-URL issuer.
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
import { withLogging } from '../_shared/log.ts'
import type { GiLogger } from '../_shared/log.ts'
import { inquiryPrice, isPriceLocked, loadOwnProposal, privateEditFields, publishPrivate, skipsWebflowResync, type InquiryProposal } from './inquiry.ts'
import { agreementRefusal, needsAgreementCheck } from './agreement.ts'
import {
  contentChanged,
  currentRulesVersion,
  needsRulesForSubmit,
  parseRulesConfirmation,
  recordRulesConfirmation,
  rulesRefusal,
  rulesRelevant,
  type RulesConfirmation,
} from './rules.ts'
import { requestMeta, SERVER_SECRET_HEADER, type RequestMeta } from '../_shared/request-meta.ts'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': `authorization, apikey, content-type, x-client-info, ${SERVER_SECRET_HEADER}`,
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
  inquiry_proposal_id?: string  // GET-328: delivering against an accepted inquiry proposal
  // GET-486 B2: the five Content & Image Rules ticks (see rules.ts)
  rules_confirmation?: unknown
  // GET-486 B2: the user's IP / UA, trusted only with a valid x-gi-server-secret (request-meta.ts)
  ip?: unknown
  user_agent?: unknown
}

// GET-486 B2: what the rules gate resolved for this request (null-current → version null).
type RulesState = {
  version: string | null
  confirmation: RulesConfirmation | null
  meta: RequestMeta
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
    .select('is_creator, display_name, bio, webflow_creator_id, agreement_version')
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

  // GET-357: a new publish needs the current Creator Agreement (see agreement.ts).
  // Before tag resolution, so a refused submit writes nothing.
  if (needsAgreementCheck(action, payload)) {
    const refusal = await agreementRefusal(svc, userRow.agreement_version, log)
    if (refusal) return json(refusal.status, refusal.body)
  }

  // GET-486 B2: the Content & Image Rules — early check, no write (see rules.ts). A publish or
  // delivery must carry the ticks; an edit's are validated whenever present and required later,
  // only if the edit changes content.
  let rules: RulesState | null = null
  if (rulesRelevant(action)) {
    const cur = await currentRulesVersion(svc)
    if (cur.error) {
      log.error('content_rules read failed', { err: cur.error })
      return json(500, { error: 'rules_check_failed' })
    }
    const refusal = rulesRefusal(cur.version, payload.rules_confirmation, needsRulesForSubmit(action))
    if (refusal) return json(refusal.status, refusal.body)
    const parsed = parseRulesConfirmation(payload.rules_confirmation)
    rules = {
      version: cur.version,
      confirmation: cur.version && parsed && parsed !== 'invalid' ? parsed : null,
      meta: requestMeta(req.headers, payload, Deno.env.get('GI_SERVER_SECRET')),
    }
  }

  if (action === 'load_draft') {
    const pid = String(payload.inquiry_proposal_id || '').trim()
    if (pid) return await loadInquiryDraft(svc, creatorEmail, pid, authUserId)
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

  // ── Tags (GET-190) ─────────────────────────────────────────────────────────
  // Resolve ONCE here, before any row is built, so every write path below stores
  // canonical labels. Must run before diffEdit's comparison (buildPublishedRow)
  // or a re-save of unchanged tags would look like a change and re-fire the n8n
  // republish + buyer notifications.
  // p_created_by: auth.uid() is NULL under the service key, so the author has to be
  // passed explicitly or insyt_tag_vocab.created_by could never be populated.
  const rawTags = Array.isArray(payload.tags) ? payload.tags : []
  let tags: string[] = []
  if (rawTags.length) {
    const { data, error } = await svc.rpc('resolve_insyt_tags', {
      p_labels: rawTags,
      p_created_by: authUserId,
    })
    if (error) return json(400, { error: 'Invalid tags: ' + error.message })
    tags = (data as string[]) || []
  }

  // ── Inquiry deliveries (GET-328) ─────────────────────────────────────────
  // Every create/edit action on an inquiry draft or insyt passes this gate:
  // the proposal must be the caller's, the price is the proposal's (S5-AC4) —
  // or €0 for good once an open-mode insyt is released (GET-459 §5, S5-AC5) —
  // and a private insyt never reaches n8n (see inquiry.ts).
  const inquiry = await resolveInquiry(svc, action, payload, authUserId)
  if (inquiry && 'error' in inquiry) return json(inquiry.status, { error: inquiry.error })
  if (inquiry) {
    const price = inquiryPrice(inquiry, payload)
    if (!price.ok) return json(price.status, price.body)
    payload.price_cents = price.price_cents
    payload.is_free = price.is_free
    payload.inquiry_proposal_id = inquiry.id
  }

  if (action === 'save_draft') {
    if (inquiry && !['accepted', 'delivering'].includes(inquiry.status)) {
      return json(409, { error: 'This proposal can no longer be delivered.' })
    }
    return await saveDraft(svc, {
      authUserId,
      creatorEmail,
      correlation_id,
      payload,
      tags,
      insyt_id: payload.insyt_id,
      inquiry,
    })
  }

  if (action === 'update_published') {
    return await updatePublished(svc, {
      authUserId,
      creatorEmail,
      correlation_id,
      payload,
      tags,
      userRow,
      log,
      rules,
    })
  }

  if (action === 'confirm_update') {
    return await confirmUpdate(svc, {
      authUserId,
      creatorEmail,
      correlation_id,
      payload,
      tags,
      userRow,
      log,
      rules,
    })
  }

  if (inquiry) {
    // The RN API claims the proposal (accepted → delivering) before relaying
    // the submit, so a double tap can't start two publishes (S6-AC2).
    if (inquiry.status !== 'delivering') {
      return json(409, { error: 'Start the delivery from the app — this proposal isn’t being delivered.' })
    }
    return await submitPrivate(svc, {
      inquiry,
      creatorEmail,
      authUserId,
      correlation_id,
      payload,
      title,
      tags,
      rules,
    })
  }

  // action === 'submit' — forward to n8n
  if (!N8N_CREATE_INSYT_URL) {
    return json(500, { error: 'N8N_CREATE_INSYT_URL is not configured' })
  }

  // GET-486 B2: record the confirmation right before the content goes to the pipeline. The row
  // doesn't exist yet, so it is keyed on correlation_id at content_rev 0. If n8n then fails,
  // the row stays as evidence of what was confirmed; a retry records another.
  if (rules?.version && rules.confirmation) {
    const refused = await recordRulesConfirmation(svc, rules.version, {
      authUserId,
      correlationId: correlation_id,
      rowId: null,
      confirmation: rules.confirmation,
      context: 'publish',
      contentRev: 0,
      ip: rules.meta.ip,
      userAgent: rules.meta.userAgent,
    })
    if (refused) return json(refused.status, refused.body)
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
    tags,
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
    .is('inquiry_proposal_id', null)   // inquiry drafts resume from the proposal (GET-328)
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
    .is('inquiry_proposal_id', null)   // inquiry drafts resume from the proposal (GET-328)
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

// ─── Inquiry deliveries (GET-328) ────────────────────────────────────────────

type Fail = { error: string; status: number }

// The proposal an action is delivering against, or null for a normal insyt.
// The row's own link wins over the payload, so an inquiry draft or insyt stays
// one whatever the client sends (the choke point can't be skipped by omitting
// inquiry_proposal_id).
async function resolveInquiry(
  svc: ReturnType<typeof createClient>,
  action: Action,
  payload: Payload,
  authUserId: string,
): Promise<InquiryProposal | Fail | null> {
  const isEdit = action === 'update_published' || action === 'confirm_update'
  const ref = String(payload.insyt_id || '').trim()
  let rowPid: string | null = null
  let priceLocked = false
  if (ref && (isEdit || uuidRe.test(ref))) {
    const { data, error } = await svc
      .from('insyts')
      .select('inquiry_proposal_id, released_at, release_price_cents')
      .eq(isEdit ? 'insyt_id' : 'id', ref)
      .maybeSingle()
    if (error) return { error: error.message, status: 500 }
    rowPid = (data?.inquiry_proposal_id as string | null) ?? null
    // GET-459 §5: read from the stored row, never the payload, so a client can't unlock it.
    priceLocked = isPriceLocked(data as { released_at: string | null; release_price_cents: number | null } | null)
  }
  const asked = String(payload.inquiry_proposal_id || '').trim() || null
  if (asked && !uuidRe.test(asked)) return { error: 'inquiry_proposal_id must be a UUID', status: 400 }
  if (asked && rowPid && asked !== rowPid) return { error: 'This insyt belongs to another proposal', status: 400 }
  if (asked && !rowPid && isEdit) return { error: 'This insyt isn’t an inquiry delivery', status: 400 }
  const pid = rowPid || asked
  if (!pid) return null
  const proposal = await loadOwnProposal(svc, pid, authUserId)
  if ('error' in proposal) return proposal
  return { ...proposal, price_locked: priceLocked }
}

// Resume the draft of one proposal (the RN create screen opened from it).
async function loadInquiryDraft(
  svc: ReturnType<typeof createClient>,
  creatorEmail: string,
  proposalId: string,
  authUserId: string,
) {
  if (!uuidRe.test(proposalId)) return json(400, { error: 'inquiry_proposal_id must be a UUID' })
  const proposal = await loadOwnProposal(svc, proposalId, authUserId)
  if ('error' in proposal) return json(proposal.status, { error: proposal.error })
  const { data, error } = await svc
    .from('insyts')
    .select('*, insyt_attachments(*)')
    .eq('creator_email', creatorEmail)
    .eq('status', 'draft')
    .eq('inquiry_proposal_id', proposalId)
    .maybeSingle()
  if (error) return json(500, { error: error.message })
  return json(200, { draft: data || null })
}

// Publish a private delivery (no n8n — see inquiry.ts). The draft row, when
// there is one, becomes the insyt: same id, like the n8n upsert.
async function submitPrivate(
  svc: ReturnType<typeof createClient>,
  args: {
    inquiry: InquiryProposal
    creatorEmail: string
    authUserId: string
    correlation_id: string
    payload: Payload
    title: string
    tags: string[]
    rules: RulesState | null
  },
) {
  const { inquiry, creatorEmail, payload, rules } = args
  let insytUuid: string | null = null
  const ref = String(payload.insyt_id || '').trim()
  if (ref) {
    // Only an existing draft of this creator for this proposal: never upsert
    // over someone else's row, nor mint a row at a client-chosen id.
    const { data, error } = await svc
      .from('insyts')
      .select('id, creator_email, status, inquiry_proposal_id')
      .eq('id', ref)
      .maybeSingle()
    if (error) return json(500, { error: error.message })
    if (!data) return json(404, { error: 'Draft not found' })
    if (data.creator_email !== creatorEmail) return json(403, { error: 'Not your draft' })
    if (data.status !== 'draft' || (data.inquiry_proposal_id && data.inquiry_proposal_id !== inquiry.id)) {
      return json(409, { error: 'This draft can’t be delivered.' })
    }
    insytUuid = ref
  } else {
    const { data, error } = await svc
      .from('insyts')
      .select('id, status')
      .eq('inquiry_proposal_id', inquiry.id)
      .maybeSingle()
    if (error) return json(500, { error: error.message })
    if (data && data.status !== 'draft') return json(409, { error: 'This proposal has already been delivered.' })
    insytUuid = (data?.id as string | undefined) ?? crypto.randomUUID()
  }

  // GET-486 B2 (AC3.5): a delivery is content made visible, so it carries the ticks. Recorded
  // before the publish (so nothing goes live unconfirmed), with the row id when the draft row
  // already exists; a brand-new delivery is keyed on its correlation_id like a public publish.
  if (rules?.version && rules.confirmation) {
    const { data: existing } = await svc.from('insyts').select('id').eq('id', insytUuid).maybeSingle()
    const refused = await recordRulesConfirmation(svc, rules.version, {
      authUserId: args.authUserId,
      correlationId: args.correlation_id,
      rowId: existing ? insytUuid : null,
      confirmation: rules.confirmation,
      context: 'delivery',
      contentRev: 0,
      ip: rules.meta.ip,
      userAgent: rules.meta.userAgent,
    })
    if (refused) return json(refused.status, refused.body)
  }

  const failed = await publishPrivate(svc, {
    insytUuid,
    proposal: inquiry,
    creatorEmail,
    correlationId: args.correlation_id,
    title: args.title,
    description: String(payload.description || ''),
    fullText: String(payload.full_text || ''),
    sport: String(payload.sport || ''),
    contentType: String(payload.content_type || ''),
    tags: args.tags,
    cover: payload.cover || null,
    images: payload.images || [],
    videos: payload.videos || [],
    pdfs: payload.pdfs || [],
    now: new Date(),
  })
  if (failed) return json(failed.status, { error: failed.error })

  // Same response shape as the n8n path, so the create screen needs no branch;
  // no forward_url — a private insyt has no public page.
  return json(200, {
    success: true,
    correlation_id: args.correlation_id,
    private: true,
    n8n: { ok: true, insyt_id: insytUuid, correlation_id: args.correlation_id, status: 'live', forward_url: null },
  })
}

async function saveDraft(
  svc: ReturnType<typeof createClient>,
  args: {
    authUserId: string
    creatorEmail: string
    correlation_id: string
    insyt_id?: string
    payload: Payload
    tags: string[]
    inquiry?: InquiryProposal | null
  },
) {
  const { creatorEmail, payload, tags, inquiry } = args
  let insyt_id = args.insyt_id
  // One draft per proposal (insyts_inquiry_proposal_id_key): a fresh save for a
  // proposal that already has a draft continues that draft.
  if (inquiry && !insyt_id) {
    const { data: existing } = await svc
      .from('insyts')
      .select('id, status')
      .eq('inquiry_proposal_id', inquiry.id)
      .maybeSingle()
    if (existing && existing.status !== 'draft') return json(409, { error: 'This proposal has already been delivered.' })
    insyt_id = (existing?.id as string | undefined) ?? undefined
  }

  const row = {
    title: String(payload.title || '').trim() || 'Untitled draft',
    abstract: String(payload.description || '').trim() || ' ',
    content_type: String(payload.content_type || '').trim() || null,
    sport: String(payload.sport || '').trim() || 'soccer',
    body_html: String(payload.full_text || '').trim() || null,
    price_eur: payload.is_free ? 0 : Number(payload.price_cents || 0),
    tags,
    creator_email: creatorEmail,
    status: 'draft',
    is_hidden: true,
    thumbnail_url: payload.cover?.path || null,
    updated_at: new Date().toISOString(),
    // Drafts are hidden anyway; private from the first save so nothing can
    // ever publish this row publicly by mistake (S7-AC1).
    ...(inquiry ? { inquiry_proposal_id: inquiry.id, visibility: 'private' } : {}),
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
  visibility: string | null
  // GET-459: set on an inquiry delivery — its edits never re-sync to Webflow
  inquiry_proposal_id: string | null
  // GET-486 B2: the content revision a rules confirmation covers
  content_rev: number | null
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
      'id, insyt_id, creator_email, creator_auth_user_id, status, title, abstract, content_type, sport, body_html, price_eur, tags, thumbnail_url, visibility, inquiry_proposal_id, content_rev',
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
// tags arrive already canonicalized by resolve_insyt_tags (GET-190) so diffEdit
// below compares canonical-vs-canonical.
function buildPublishedRow(payload: Payload, tags: string[]) {
  return {
    title: String(payload.title || '').trim(),
    abstract: String(payload.description || '').trim() || ' ',
    content_type: String(payload.content_type || '').trim() || null,
    sport: String(payload.sport || '').trim() || 'soccer',
    body_html: String(payload.full_text || '').trim() || null,
    price_eur: payload.is_free ? 0 : Number(payload.price_cents || 0),
    tags,
    thumbnail_url: payload.cover?.path || null,
  }
}

// GET-328 / GET-459: an inquiry insyt (private or released) skips the n8n
// is_edit re-sync, which is what rewrites the public thumbnail URL and the read
// time on a public edit — so set them here (else the cover becomes a bare
// storage path).
function editRow(stored: OwnedInsyt, payload: Payload, tags: string[]) {
  const row = buildPublishedRow(payload, tags)
  return skipsWebflowResync(stored) ? { ...row, ...privateEditFields(payload) } : row
}

// No-op guard (D-5): `noop` is true when the submitted editable fields + media
// are byte-identical to what's stored, so saving would change nothing. Compares
// the mapped row fields and the full attachment set (cover + images + videos +
// pdfs) by storage path. GET-486 B2: `content` says whether the CONTENT changed
// (rules.ts contentChanged) — only then does the edit need the rules ticks and
// bump insyts.content_rev.
async function diffEdit(
  svc: Svc,
  stored: OwnedInsyt,
  row: ReturnType<typeof buildPublishedRow>,
  payload: Payload,
): Promise<{ noop: boolean; content: boolean }> {
  const fieldsSame =
    String(stored.title || '') === row.title &&
    String(stored.abstract || '') === row.abstract &&
    (stored.content_type || null) === row.content_type &&
    (stored.sport || '') === row.sport &&
    (stored.body_html || null) === row.body_html &&
    Number(stored.price_eur || 0) === Number(row.price_eur || 0) &&
    JSON.stringify(stored.tags || []) === JSON.stringify(row.tags || []) &&
    (stored.thumbnail_url || null) === row.thumbnail_url

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
  const mediaSame = JSON.stringify(submittedPaths) === JSON.stringify(storedPaths)
  return {
    noop: fieldsSame && mediaSame,
    content: contentChanged(stored, row, storedPaths as string[], submittedPaths as string[]),
  }
}

// GET-486 B2: a content edit needs a valid rules confirmation (already validated early in the
// handler when present). null = go on.
function editRulesRefusal(rules: RulesState | null, content: boolean) {
  if (!content || !rules?.version || rules.confirmation) return null
  return json(409, { error: 'rules_confirmation_required', current_version: rules.version })
}

// GET-486 B2: record the confirmation of a persisted content edit at its new content_rev. The
// edit is already saved, so a failure here is logged (and alerts) but doesn't fail the save —
// the ticks were validated before anything was written.
async function recordEditConfirmation(
  svc: Svc,
  args: { stored: OwnedInsyt; authUserId: string; rules: RulesState | null; newRev: number | null; log: GiLogger },
) {
  const { rules } = args
  if (!rules?.version || !rules.confirmation || args.newRev === null) return
  const refused = await recordRulesConfirmation(svc, rules.version, {
    authUserId: args.authUserId,
    correlationId: null,
    rowId: args.stored.id,
    confirmation: rules.confirmation,
    context: 'update_published',
    contentRev: args.newRev,
    ip: rules.meta.ip,
    userAgent: rules.meta.userAgent,
  })
  if (refused) {
    args.log.error('rules confirmation not recorded after a content edit', {
      insyt: args.stored.insyt_id,
      status: refused.status,
      error: refused.body.error,
    })
  }
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
  tags: string[]
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
    tags: args.tags,
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
    // GET-486 B2: a content edit bumps insyts.content_rev
    contentChanged: boolean
  },
): Promise<{ error: string; status: number } | { newRev: number | null }> {
  const { stored, payload, row } = args
  const newRev = args.contentChanged ? Number(stored.content_rev || 0) + 1 : null
  const { error: upErr } = await svc
    .from('insyts')
    .update({
      ...row,
      ...(newRev !== null ? { content_rev: newRev } : {}),
      updated_at: new Date().toISOString(),
    })
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
  // An inquiry insyt (GET-328 private; GET-459 released too) has no CMS item or
  // payment link to re-sync, and the pipeline would create both — the saved row
  // is the whole edit.
  if (N8N_CREATE_INSYT_URL && !skipsWebflowResync(stored)) {
    const forwardBody = buildCreateForwardBody({
      authUserId: args.authUserId,
      creatorEmail: args.creatorEmail,
      webflowCreatorId: args.webflowCreatorId,
      correlation_id: args.correlation_id,
      payload,
      title: row.title,
      priceCents: Number(row.price_eur || 0),
      isFree: !!payload.is_free,
      // already canonicalized — row came from buildPublishedRow(payload, tags)
      tags: row.tags,
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
  return { newRev }
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
    tags: string[]
    userRow: { webflow_creator_id?: string | null } | null
    log: GiLogger
    rules: RulesState | null
  },
) {
  const insytId = String(args.payload.insyt_id || '').trim()
  const gate = await assertOwner(svc, insytId, args.authUserId, args.creatorEmail)
  if ('error' in gate) return json(gate.status, { error: gate.error })

  const row = editRow(gate, args.payload, args.tags)
  const diff = await diffEdit(svc, gate, row, args.payload)
  if (diff.noop) {
    return json(200, { noop: true })
  }
  const rulesRefused = editRulesRefusal(args.rules, diff.content)
  if (rulesRefused) return rulesRefused

  const n = await buyerCount(svc, insytId)
  if (n >= 1) {
    // Don't write yet — the client shows the confirm modal and re-sends on confirm.
    // GET-486 B2: nothing is recorded either; confirm_update records when it persists.
    return json(200, { purchased: true, buyer_count: n })
  }

  const persisted = await persistEditAndRepublish(svc, {
    stored: gate,
    authUserId: args.authUserId,
    creatorEmail: args.creatorEmail,
    webflowCreatorId: args.userRow?.webflow_creator_id || null,
    correlation_id: args.correlation_id,
    payload: args.payload,
    row,
    log: args.log,
    contentChanged: diff.content,
  })
  if ('error' in persisted) return json(persisted.status, { error: persisted.error })
  await recordEditConfirmation(svc, {
    stored: gate,
    authUserId: args.authUserId,
    rules: args.rules,
    newRev: persisted.newRev,
    log: args.log,
  })
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
    tags: string[]
    userRow: { webflow_creator_id?: string | null; display_name?: string | null } | null
    log: GiLogger
    rules: RulesState | null
  },
) {
  const insytId = String(args.payload.insyt_id || '').trim()
  const gate = await assertOwner(svc, insytId, args.authUserId, args.creatorEmail)
  if ('error' in gate) return json(gate.status, { error: gate.error })

  const row = editRow(gate, args.payload, args.tags)
  const diff = await diffEdit(svc, gate, row, args.payload)
  if (diff.noop) {
    return json(200, { noop: true })
  }
  const rulesRefused = editRulesRefusal(args.rules, diff.content)
  if (rulesRefused) return rulesRefused

  const persisted = await persistEditAndRepublish(svc, {
    stored: gate,
    authUserId: args.authUserId,
    creatorEmail: args.creatorEmail,
    webflowCreatorId: args.userRow?.webflow_creator_id || null,
    correlation_id: args.correlation_id,
    payload: args.payload,
    row,
    log: args.log,
    contentChanged: diff.content,
  })
  if ('error' in persisted) return json(persisted.status, { error: persisted.error })
  await recordEditConfirmation(svc, {
    stored: gate,
    authUserId: args.authUserId,
    rules: args.rules,
    newRev: persisted.newRev,
    log: args.log,
  })

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
  // Never for a private insyt (GET-328): its only buyer is the requester, and
  // nothing about it may leave the app while private.
  if (N8N_INSYT_UPDATED_WEBHOOK_URL && buyers.length > 0 && gate.visibility !== 'private') {
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
