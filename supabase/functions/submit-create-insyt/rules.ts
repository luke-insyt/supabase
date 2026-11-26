// GET-486 B2 (S3, AC3.3–AC3.5) — the Content & Image Rules gate on everything that makes
// Insyt content visible: a public publish, an inquiry delivery, a content edit of a published
// Insyt (here) and the Insyter's own unhide (set-insyt-published).
// Design: webflow-app-documentation/features/legal-follow-up/feature.md §2.4, §3.1.
//
// The gate lives in the edge fns, not only in the RN app, because both functions are callable
// directly with any user JWT (GET-470 §3.4(c) reasoning).
//   * Null-current safe: while no content_rules version is current there is no gate at all and
//     nothing is recorded.
//   * The client sends `rules_confirmation: { version, ticks }`. A present one is always
//     validated early (stale → 409 rules_changed + current_version; wrong ticks → 400
//     rules_ticks_invalid), before anything is written.
//   * Publish + delivery: required (409 rules_confirmation_required) and recorded before the
//     content goes live. Content edits: required only when content fields change; recorded
//     only by the call that actually persists (never on `purchased: true`).
//   * auth_user_id is the verified JWT subject; confirmed_at is the DB's now().
// Separate from index.ts because index.ts calls Deno.serve on load, so it can't be imported by
// a test (rules_test.ts).
import type { SupabaseClient } from 'https://esm.sh/@supabase/supabase-js@2'

// Untyped schema: the generated types aren't in this repo.
// deno-lint-ignore no-explicit-any
type Svc = SupabaseClient<any>

/**
 * D-3: the five tick ids are a code constant tied to content_rules v1.0, sorted. Mirrors
 * public.content_rules_tick_ids() (migration 20261126180000_get486_content_rules.sql) and
 * RULE_TICKS in getinsyts-native/app/src/lib/content-rules.ts; tests pin all three.
 */
export const RULE_TICK_IDS = [
  'images_licensed',
  'minors_initials',
  'no_confidential',
  'opinions',
  'own_work',
] as const

export type RulesConfirmation = { version: string; ticks: string[] }
export type RulesContext = 'publish' | 'delivery' | 'update_published' | 'unhide'

export type RulesRefusal = {
  status: 400 | 403 | 404 | 409 | 500
  body:
    | { error: 'rules_confirmation_required'; current_version: string }
    | { error: 'rules_changed'; current_version: string }
    | { error: 'rules_ticks_invalid' }
    | { error: 'not_owner' }
    | { error: 'Insyt not found' }
    | { error: 'rules_check_failed' }
}

/** The body's `rules_confirmation`: null when absent, 'invalid' when present but malformed. */
export function parseRulesConfirmation(raw: unknown): RulesConfirmation | null | 'invalid' {
  if (raw === undefined || raw === null) return null
  if (typeof raw !== 'object' || Array.isArray(raw)) return 'invalid'
  const r = raw as { version?: unknown; ticks?: unknown }
  if (typeof r.version !== 'string' || !r.version.trim()) return 'invalid'
  if (!Array.isArray(r.ticks) || !r.ticks.every((t) => typeof t === 'string')) return 'invalid'
  return { version: r.version.trim(), ticks: r.ticks as string[] }
}

/** Exactly the five ids, each once, in any order. */
export function ticksValid(ticks: readonly string[]): boolean {
  if (ticks.length !== RULE_TICK_IDS.length) return false
  const sorted = [...ticks].sort()
  return sorted.every((t, i) => t === RULE_TICK_IDS[i])
}

/** The current content_rules version, or null when the rules aren't live. Never cached. */
export async function currentRulesVersion(svc: Svc): Promise<{ version: string | null; error: string | null }> {
  const { data, error } = await svc
    .from('agreement_versions')
    .select('version')
    .eq('document_type', 'content_rules')
    .eq('is_current', true)
    .maybeSingle()
  if (error) return { version: null, error: error.message }
  return { version: (data as { version: string } | null)?.version ?? null, error: null }
}

/**
 * The early check (no write). `required` = this call makes content visible and must carry a
 * confirmation. Returns null when the caller may go on.
 */
export function rulesRefusal(
  current: string | null,
  raw: unknown,
  required: boolean,
): RulesRefusal | null {
  if (!current) return null // null-current: no gate
  const conf = parseRulesConfirmation(raw)
  if (conf === 'invalid') return { status: 400, body: { error: 'rules_ticks_invalid' } }
  if (!conf) {
    return required
      ? { status: 409, body: { error: 'rules_confirmation_required', current_version: current } }
      : null
  }
  if (conf.version !== current) return { status: 409, body: { error: 'rules_changed', current_version: current } }
  if (!ticksValid(conf.ticks)) return { status: 400, body: { error: 'rules_ticks_invalid' } }
  return null
}

/** Which actions publish new content (the confirmation is required up front). */
export function needsRulesForSubmit(action: string | undefined): boolean {
  return (action || 'submit') === 'submit'
}

/** Actions whose body may carry a confirmation (validated early whenever present). */
export function rulesRelevant(action: string | undefined): boolean {
  const a = action || 'submit'
  return a === 'submit' || a === 'update_published' || a === 'confirm_update'
}

// ── Content-edit detection (OQ-5) ───────────────────────────────────────────

/** The stored fields a content edit compares (a subset of submit-create-insyt's OwnedInsyt). */
export type ContentFields = {
  title: string | null
  abstract: string | null
  body_html: string | null
  thumbnail_url: string | null
}

/**
 * True when an edit changes CONTENT (title, abstract, body, cover, attachments). Price, tags,
 * sport and content type are not content: such edits need no re-tick and don't bump
 * insyts.content_rev. Paths are compared as sets.
 */
export function contentChanged(
  stored: ContentFields,
  row: ContentFields,
  storedPaths: readonly string[],
  submittedPaths: readonly string[],
): boolean {
  if (String(stored.title || '') !== String(row.title || '')) return true
  if (String(stored.abstract || '') !== String(row.abstract || '')) return true
  if ((stored.body_html || null) !== (row.body_html || null)) return true
  if ((stored.thumbnail_url || null) !== (row.thumbnail_url || null)) return true
  const a = [...storedPaths].filter(Boolean).sort()
  const b = [...submittedPaths].filter(Boolean).sort()
  return JSON.stringify(a) !== JSON.stringify(b)
}

// ── Recording ───────────────────────────────────────────────────────────────

/** A record_rules_confirmation error → the HTTP refusal (P0001 messages from the migration). */
export function rpcErrorRefusal(
  err: { message?: string; details?: string | null } | null | undefined,
  current: string,
): RulesRefusal {
  const m = String(err?.message || '')
  if (m.includes('rules_changed')) {
    return { status: 409, body: { error: 'rules_changed', current_version: String(err?.details || current) } }
  }
  if (m.includes('rules_ticks_invalid')) return { status: 400, body: { error: 'rules_ticks_invalid' } }
  if (m.includes('not_owner')) return { status: 403, body: { error: 'not_owner' } }
  if (m.includes('insyt_not_found')) return { status: 404, body: { error: 'Insyt not found' } }
  if (m.includes('rules_not_live')) {
    // The version was flipped off between the early read and the write: ask again.
    return { status: 409, body: { error: 'rules_changed', current_version: current } }
  }
  return { status: 500, body: { error: 'rules_check_failed' } }
}

export type RecordArgs = {
  authUserId: string
  correlationId: string | null
  rowId: string | null
  confirmation: RulesConfirmation
  context: RulesContext
  contentRev: number
  ip: string | null
  userAgent: string | null
}

/** Writes one confirmation row. null = recorded. */
export async function recordRulesConfirmation(
  svc: Svc,
  current: string,
  a: RecordArgs,
): Promise<RulesRefusal | null> {
  const { error } = await svc.rpc('record_rules_confirmation', {
    p_user: a.authUserId,
    p_correlation: a.correlationId,
    p_row_id: a.rowId,
    p_version: a.confirmation.version,
    p_ticks: a.confirmation.ticks,
    p_context: a.context,
    p_rev: a.contentRev,
    p_ip: a.ip,
    p_ua: a.userAgent,
  })
  return error ? rpcErrorRefusal(error, current) : null
}
