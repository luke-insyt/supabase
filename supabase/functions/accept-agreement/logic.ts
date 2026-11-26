// GET-470 — accept-agreement's pure logic (feature.md §3.6, implementation.md P1 item 2 + P4).
// Separate from index.ts because index.ts calls Deno.serve on load, so it can't be imported by
// a test.
//
//   * The current version is read for document_type = 'insyter_agreement' ONLY: once a second
//     type (buyer_terms, privacy, …) has a current row, an unfiltered `.maybeSingle()` errors
//     and every Insyter acceptance would 500 (feature.md §2.2 hazard).
//   * The acceptance is written by ONE RPC, record_insyter_acceptance, which inserts the
//     terms_acceptances ledger row — ledger only (GET-486 A1: the ledger is the only
//     acceptance record).
//   * IP / user agent come from request-meta: the body's values only with a valid server secret.
import type { SupabaseClient } from 'https://esm.sh/@supabase/supabase-js@2'
import type { RequestMeta } from '../_shared/request-meta.ts'

// deno-lint-ignore no-explicit-any
type Svc = SupabaseClient<any>

export const STALE_VERSION_BODY = { error: 'Not the current agreement version', code: 'terms_changed' } as const

export async function currentInsyterVersion(svc: Svc): Promise<{ version: string | null; error: string | null }> {
  const { data, error } = await svc
    .from('agreement_versions')
    .select('version')
    .eq('document_type', 'insyter_agreement')
    .eq('is_current', true)
    .maybeSingle()
  if (error) return { version: null, error: error.message }
  return { version: (data as { version: string } | null)?.version ?? null, error: null }
}

export type AcceptArgs = {
  authUserId: string
  email: string
  signatureName: string
  version: string
  meta: RequestMeta
}

export function acceptRpcParams(a: AcceptArgs) {
  return {
    p_user: a.authUserId,
    p_email: a.email,
    p_signature_name: a.signatureName,
    p_version: a.version,
    p_ip: a.meta.ip,
    p_ua: a.meta.userAgent,
  }
}

export type RecordOutcome =
  | { ok: true; ledgerId: string | null }
  | { ok: false; status: 409 | 500; body: Record<string, unknown> }

// record_insyter_acceptance raises 'terms_changed' (P0001) when the version went stale between
// the pre-check and the write (a make-current in between): that's a 409, like the pre-check.
export async function recordInsyterAcceptance(svc: Svc, a: AcceptArgs): Promise<RecordOutcome> {
  const { data, error } = await svc.rpc('record_insyter_acceptance', acceptRpcParams(a))
  if (error) {
    if (String(error.message || '').includes('terms_changed')) {
      return { ok: false, status: 409, body: { ...STALE_VERSION_BODY } }
    }
    return { ok: false, status: 500, body: { error: error.message } }
  }
  return { ok: true, ledgerId: (data as string | null) ?? null }
}
