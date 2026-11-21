// GET-328 (GET-318 stage 4) — inquiry deliveries through the create pipeline.
//
// An insyt written against an accepted inquiry proposal is PRIVATE to the
// requester (S7-AC1) and sold at exactly the proposal price (S5-AC4). This
// module is the choke point every create/edit action passes through:
//   * the proposal must be the caller's, and in a deliverable state;
//   * the price is the proposal's, on every action — a different one is refused;
//     except on a released open-mode insyt, where it is €0 for good (GET-459 §5);
//   * a private insyt is published HERE, never forwarded to the n8n
//     create-insyt pipeline: that pipeline always creates a Webflow CMS item and
//     a Stripe payment link (and its n8n instance serves production too), and a
//     private insyt must have neither (S7-AC1; feature.md §6.3 — deviation
//     recorded in implementation.md, stage 4).
// The row it writes mirrors the n8n `Upsert insyts row` node field for field,
// plus visibility / private_until / release_price_cents / inquiry_proposal_id. The insyts trigger
// `insyts_mark_proposal_delivered` then marks the proposal delivered.
import type { SupabaseClient } from 'https://esm.sh/@supabase/supabase-js@2'

// Untyped schema: the generated types aren't in this repo.
// deno-lint-ignore no-explicit-any
type Svc = SupabaseClient<any>

// GET-459: who gets the delivered insyt (inquiries.access_mode).
export type AccessMode = 'exclusive' | 'timed' | 'open'

export type InquiryProposal = {
  id: string
  status: string
  price_cents: number
  access_mode: AccessMode
  // GET-459 §5: the insyt being edited is a released open-mode insyt — its price is €0 for good.
  price_locked?: boolean
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
    .select('id, status, price_cents, insyter_auth_user_id, inquiries(access_mode, is_exclusive)')
    .eq('id', proposalId)
    .maybeSingle()
  if (error) return { error: error.message, status: 500 }
  const row = data as
    | {
      id: string
      status: string
      price_cents: number
      insyter_auth_user_id: string | null
      inquiries: { access_mode: string | null; is_exclusive: boolean } | null
    }
    | null
  if (!row || row.insyter_auth_user_id !== authUserId) return { error: 'Proposal not found', status: 404 }
  return {
    id: row.id,
    status: row.status,
    price_cents: Number(row.price_cents),
    access_mode: accessMode(row.inquiries),
  }
}

// A proposal only exists on a published inquiry, and the GET-459 migration gives every
// published inquiry a mode — so the is_exclusive fallback is only a backstop. It maps the way
// the migration's sync trigger does; an unknown value is treated as exclusive, the one mode
// that never makes anything public.
export function accessMode(inquiry: { access_mode?: string | null; is_exclusive?: boolean | null } | null): AccessMode {
  const m = inquiry?.access_mode
  if (m === 'exclusive' || m === 'timed' || m === 'open') return m
  if (m != null) return 'exclusive'
  return inquiry?.is_exclusive ? 'exclusive' : 'timed'
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

// GET-459 §5 / S5-AC5: a released open-mode insyt is free for good. released_at is stamped
// once by release_inquiry_insyt; release_price_cents = 0 is what made it free.
export function isPriceLocked(row: { released_at?: string | null; release_price_cents?: number | null } | null): boolean {
  return !!row?.released_at && row.release_price_cents != null && Number(row.release_price_cents) === 0
}

export type InquiryPrice =
  | { ok: true; price_cents: number; is_free: boolean }
  | { ok: false; status: number; body: { error: string } }

// The price every inquiry action is saved with. Normally the accepted proposal's price
// (priceRefusal). On a released open insyt it is €0 with is_free, so the edit's n8n re-sync
// carries €0 and never makes a payment link; the client may echo 0 or omit the price, and
// only a non-zero price is refused — not "can't be free", which would undo the release.
export function inquiryPrice(
  inquiry: Pick<InquiryProposal, 'price_cents' | 'price_locked'>,
  payload: { price_cents?: number; is_free?: boolean },
): InquiryPrice {
  if (inquiry.price_locked) {
    if (payload.price_cents != null && Number(payload.price_cents) !== 0) {
      return { ok: false, status: 400, body: { error: 'price_locked' } }
    }
    return { ok: true, price_cents: 0, is_free: true }
  }
  const refusal = priceRefusal(inquiry.price_cents, payload)
  if (refusal) return { ok: false, status: 400, body: { error: refusal } }
  return { ok: true, price_cents: inquiry.price_cents, is_free: false }
}

// S7-AC2 / GET-459 §3: exclusive → private forever; timed → 30 days after delivery (the
// stage-5 sweep flips it public then); open → private until the requester's purchase
// releases it (no time-based release).
export function privateUntil(mode: AccessMode, now: Date): string {
  if (mode === 'timed') {
    return new Date(now.getTime() + NON_EXCLUSIVE_PRIVATE_DAYS * 24 * 60 * 60 * 1000).toISOString()
  }
  return 'infinity'
}

// GET-459 §3: the price the insyt takes at release. Open mode is free for everyone once
// released; null keeps the Insyter's price (timed, and exclusive, which is never released).
export function releasePriceCents(mode: AccessMode): number | null {
  return mode === 'open' ? 0 : null
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

// The public thumbnail URL the n8n pipeline stores (`Edit Fields`), from the
// cover attachment — null without one (so the edit no-op check, which reads
// a missing thumbnail as null, matches an unchanged coverless insyt).
export function publicThumbnailUrl(cover: { bucket?: string; path?: string } | null | undefined): string | null {
  if (!cover?.bucket || !cover?.path) return null
  return `${Deno.env.get('SUPABASE_URL') || ''}/storage/v1/object/public/${cover.bucket}/${cover.path}`
}

// The derived fields n8n's `is_edit` re-sync would rewrite on an edit; a
// private insyt skips that re-sync, so its edits set them here instead.
export function privateEditFields(payload: {
  cover?: { bucket?: string; path?: string } | null
  full_text?: string
  description?: string
}) {
  return {
    thumbnail_url: publicThumbnailUrl(payload.cover),
    read_time_min: readTimeMin(String(payload.full_text || ''), String(payload.description || '')),
  }
}

// Publish a private delivery in place of the n8n pipeline: the insyts row
// (private, priced), its attachments, then — LAST — the flip to live, which is
// what marks the proposal delivered (insyts_mark_proposal_delivered). A failure
// before the flip leaves the proposal's draft, so the claim reverts and the
// Insyter can retry; nothing is half-delivered. Then the completed status row
// the create screen polls. No CMS item, no payment link, no notifications.
export async function publishPrivate(svc: Svc, a: PrivatePublishArgs): Promise<Fail | null> {
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
      thumbnail_url: publicThumbnailUrl(a.cover),
      is_hidden: true,
      status: 'draft',
      visibility: 'private',
      private_until: privateUntil(a.proposal.access_mode, a.now),
      release_price_cents: releasePriceCents(a.proposal.access_mode),
      inquiry_proposal_id: a.proposal.id,
    },
    { onConflict: 'id' },
  )
  if (upErr) {
    // 23505 on insyts_inquiry_proposal_id_key: another row already carries
    // this proposal (its insyt, or a second draft).
    if ((upErr as { code?: string }).code === '23505') {
      return { error: 'This proposal already has an insyt or a draft in progress.', status: 409 }
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

  const { error: liveErr } = await svc
    .from('insyts')
    .update({ status: 'live', is_hidden: false })
    .eq('id', a.insytUuid)
  if (liveErr) return { error: liveErr.message, status: 500 }

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
