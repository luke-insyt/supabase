// GET-328 (GET-318 stage 4) — inquiry deliveries through the create pipeline.
//
// An insyt written against an accepted inquiry proposal is PRIVATE to the
// requester (S7-AC1) and sold at exactly the proposal price (S5-AC4). This
// module is the choke point every create/edit action passes through:
//   * the proposal must be the caller's, and in a deliverable state;
//   * the price is the proposal's, on every action — a different one is refused;
//   * a private insyt is published HERE, never forwarded to the n8n
//     create-insyt pipeline: that pipeline always creates a Webflow CMS item and
//     a Stripe payment link (and its n8n instance serves production too), and a
//     private insyt must have neither (S7-AC1; feature.md §6.3 — deviation
//     recorded in implementation.md, stage 4).
// The row it writes mirrors the n8n `Upsert insyts row` node field for field,
// plus visibility / private_until / inquiry_proposal_id. The insyts trigger
// `insyts_mark_proposal_delivered` then marks the proposal delivered.
import type { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

type Svc = ReturnType<typeof createClient>

export type InquiryProposal = {
  id: string
  status: string
  price_cents: number
  is_exclusive: boolean
}

type Fail = { error: string; status: number }

const NON_EXCLUSIVE_PRIVATE_DAYS = 30

// The caller's own proposal, or a 404 that never confirms someone else's id.
export async function loadOwnProposal(
  svc: Svc,
  proposalId: string,
  authUserId: string,
): Promise<InquiryProposal | Fail> {
  const { data, error } = await svc
    .from('inquiry_proposals')
    .select('id, status, price_cents, insyter_auth_user_id, inquiries(is_exclusive)')
    .eq('id', proposalId)
    .maybeSingle()
  if (error) return { error: error.message, status: 500 }
  const row = data as
    | { id: string; status: string; price_cents: number; insyter_auth_user_id: string | null; inquiries: { is_exclusive: boolean } | null }
    | null
  if (!row || row.insyter_auth_user_id !== authUserId) return { error: 'Proposal not found', status: 404 }
  return {
    id: row.id,
    status: row.status,
    price_cents: Number(row.price_cents),
    is_exclusive: !!row.inquiries?.is_exclusive,
  }
}

// S5-AC4: the client may echo the fixed price (the form shows it read-only),
// but never send a different one or mark the insyt free.
export function priceRefusal(
  fixedCents: number,
  payload: { price_cents?: number; is_free?: boolean },
): string | null {
  if (payload.is_free) return 'An inquiry insyt can’t be free — it’s sold at the accepted proposal price.'
  if (payload.price_cents != null && Number(payload.price_cents) !== fixedCents) {
    return `The price is fixed to the accepted proposal (€${fixedCents / 100}).`
  }
  return null
}

// S7-AC2: exclusive → private forever; otherwise 30 days after delivery
// (the stage-5 sweep flips it public then).
export function privateUntil(isExclusive: boolean, now: Date): string {
  if (isExclusive) return 'infinity'
  return new Date(now.getTime() + NON_EXCLUSIVE_PRIVATE_DAYS * 24 * 60 * 60 * 1000).toISOString()
}

// n8n `Edit Fields` read time: words of full text + description, 200 wpm, ≥ 1.
export function readTimeMin(fullText: string, description: string): number {
  const words = (s: string) => String(s || '').replace(/<[^>]+>/g, ' ').split(/\s+/).filter(Boolean).length
  return Math.max(1, Math.ceil((words(fullText) + words(description)) / 200))
}

type Attachment = {
  bucket: string
  path: string
  filename?: string
  mime?: string
  size_bytes?: number
}

export type PrivatePublishArgs = {
  insytUuid: string
  proposal: InquiryProposal
  creatorEmail: string
  correlationId: string
  title: string
  description: string
  fullText: string
  sport: string
  contentType: string
  tags: string[]
  cover: Attachment | null
  images: Attachment[]
  videos: Attachment[]
  pdfs: Attachment[]
  now: Date
}

// Publish a private delivery in place of the n8n pipeline: the insyts row
// (live, private, priced), its attachments and the completed status row the
// create screen polls. No CMS item, no payment link, no notifications.
export async function publishPrivate(svc: Svc, a: PrivatePublishArgs): Promise<Fail | null> {
  const supabaseUrl = Deno.env.get('SUPABASE_URL') || ''
  const thumbnailUrl = a.cover?.bucket && a.cover?.path
    ? `${supabaseUrl}/storage/v1/object/public/${a.cover.bucket}/${a.cover.path}`
    : ''

  const { error: upErr } = await svc.from('insyts').upsert(
    {
      id: a.insytUuid,
      insyt_id: a.insytUuid,
      title: a.title,
      abstract: a.description,
      body_html: a.fullText,
      sport: a.sport,
      content_type: a.contentType,
      tags: a.tags,
      price_eur: a.proposal.price_cents,
      creator_email: a.creatorEmail,
      correlation_id: a.correlationId,
      read_time_min: readTimeMin(a.fullText, a.description),
      thumbnail_url: thumbnailUrl,
      is_hidden: false,
      status: 'live',
      visibility: 'private',
      private_until: privateUntil(a.proposal.is_exclusive, a.now),
      inquiry_proposal_id: a.proposal.id,
    },
    { onConflict: 'id' },
  )
  if (upErr) {
    // 23505 on insyts_inquiry_proposal_id_key: this proposal already has an insyt.
    if ((upErr as { code?: string }).code === '23505') {
      return { error: 'This proposal has already been delivered.', status: 409 }
    }
    return { error: upErr.message, status: 500 }
  }

  await svc.from('insyt_attachments').delete().eq('insyt_id', a.insytUuid)
  const rows = [
    ...(a.cover?.path ? [{ ...a.cover, kind: 'thumbnail', bucket: a.cover.bucket || 'insyt-thumbnails', position: 0 }] : []),
    ...a.images.map((x, i) => ({ ...x, kind: 'image', bucket: x.bucket || 'insyt-images', position: i + 1 })),
    ...a.videos.map((x, i) => ({ ...x, kind: 'video', bucket: x.bucket || 'insyt-videos', position: i + 1 })),
    ...a.pdfs.map((x, i) => ({ ...x, kind: 'pdf', bucket: x.bucket || 'insyt-pdfs', position: i + 1 })),
  ].map(x => ({
    insyt_id: a.insytUuid,
    kind: x.kind,
    bucket: x.bucket,
    storage_path: x.path,
    filename: x.filename || null,
    mime: x.mime || null,
    size_bytes: x.size_bytes || null,
    position: x.position,
  }))
  if (rows.length) {
    const { error: attErr } = await svc.from('insyt_attachments').insert(rows)
    if (attErr) return { error: attErr.message, status: 500 }
  }

  const { error: statusErr } = await svc.from('insyt_status').insert({
    correlation_id: a.correlationId,
    insyt_id: a.insytUuid,
    creator_email: a.creatorEmail,
    status: 'success',
    step: 'completed',
  })
  if (statusErr) console.error('[submit-create-insyt] private status row failed', statusErr.message)
  return null
}
