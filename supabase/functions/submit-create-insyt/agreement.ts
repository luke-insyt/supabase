// GET-357 — new commitments only under the current Creator Agreement (R4-AC3).
//
// A publish is a new commitment, so a stale Insyter (their accepted
// `users.agreement_version` isn't the current `agreement_versions` row) is
// refused with 409 { error: 'agreement_outdated', current_version } and sent to
// re-accept. The gate lives here, not only in the RN app, because the web and
// any client can call this function directly with their own JWT.
//   * Only `submit` is gated: drafts, discards, reads and edits of an existing
//     insyt aren't new commitments.
//   * An inquiry delivery is exempt: the commitment was made when the proposal
//     was accepted, and blocking it would hurt the requester. A bogus or foreign
//     `inquiry_proposal_id` can't use the exemption as a bypass — resolveInquiry
//     rejects any id that isn't the caller's own proposal.
//   * No current version at all → 500 + alert: blocking is the safe default.
// Design: webflow-app-documentation/features/agreement-rollout/feature.md §3.1.
// Separate from index.ts because index.ts calls Deno.serve on load, so it can't
// be imported by a test.
import type { SupabaseClient } from 'https://esm.sh/@supabase/supabase-js@2'
import type { GiLogger } from '../_shared/log.ts'

// Untyped schema: the generated types aren't in this repo.
// deno-lint-ignore no-explicit-any
type Svc = SupabaseClient<any>

export type AgreementRefusal = {
  status: 409 | 500
  body: { error: 'agreement_outdated'; current_version: string } | { error: 'no current agreement' }
}

// `action` is the raw payload value: index.ts treats an absent one as submit.
// The id is trimmed exactly as resolveInquiry trims it, so a blank id can't
// claim the delivery exemption while the submit goes out as a public one.
export function needsAgreementCheck(
  action: string | undefined,
  payload: { inquiry_proposal_id?: string | null },
): boolean {
  if ((action || 'submit') !== 'submit') return false
  return !String(payload.inquiry_proposal_id || '').trim()
}

// null = the caller may go on. Read on every call, never cached, so a flip
// takes effect at once.
export async function agreementRefusal(
  svc: Svc,
  userVersion: string | null | undefined,
  log?: Pick<GiLogger, 'error'>,
): Promise<AgreementRefusal | null> {
  const { data, error } = await svc
    .from('agreement_versions')
    .select('version')
    .eq('is_current', true)
    .maybeSingle()
  const current = (data as { version: string } | null)?.version
  if (error || !current) {
    log?.error('no current agreement', { err: error?.message ?? null })
    return { status: 500, body: { error: 'no current agreement' } }
  }
  if (userVersion === current) return null
  return { status: 409, body: { error: 'agreement_outdated', current_version: current } }
}
