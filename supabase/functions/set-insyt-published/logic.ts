// GET-486 B2 (S3, AC3.5) — the unhide rule of the Content & Image Rules gate.
// Design: webflow-app-documentation/features/legal-follow-up/feature.md §3.1.
//
// Publishing a hidden Insyt back makes its content visible again, so it needs the five ticks
// when the content changed since the owner's last recorded confirmation, or the rules version
// changed since then (the DB decides: rules_confirmation_needed()). Hiding never needs them,
// and neither does a "publish" of an Insyt that is already visible.
// Pure, so it is unit-tested in index_test.ts (index.ts calls Deno.serve on load).
import { parseRulesConfirmation, ticksValid, type RulesConfirmation } from '../submit-create-insyt/rules.ts'

export type UnhideDecision =
  | { kind: 'skip' }
  | { kind: 'refuse'; status: 400 | 409; body: Record<string, string> }
  | { kind: 'record'; confirmation: RulesConfirmation }

/**
 * @param hidden      the requested state (true = hide)
 * @param wasHidden   the stored is_hidden
 * @param current     the current content_rules version, null when the rules aren't live
 * @param needed      rules_confirmation_needed(row) — only asked when it can matter
 * @param raw         the body's rules_confirmation
 */
export function unhideDecision(a: {
  hidden: boolean
  wasHidden: boolean
  current: string | null
  needed: boolean
  raw: unknown
}): UnhideDecision {
  if (a.hidden || !a.wasHidden || !a.current || !a.needed) return { kind: 'skip' }
  const conf = parseRulesConfirmation(a.raw)
  if (conf === 'invalid') return { kind: 'refuse', status: 400, body: { error: 'rules_ticks_invalid' } }
  if (!conf) {
    return { kind: 'refuse', status: 409, body: { error: 'rules_confirmation_required', current_version: a.current } }
  }
  if (conf.version !== a.current) {
    return { kind: 'refuse', status: 409, body: { error: 'rules_changed', current_version: a.current } }
  }
  if (!ticksValid(conf.ticks)) return { kind: 'refuse', status: 400, body: { error: 'rules_ticks_invalid' } }
  return { kind: 'record', confirmation: conf }
}

/** Only an actual unhide can need the ticks, so the DB is asked only then. */
export const mayNeedRules = (hidden: boolean, wasHidden: boolean, current: string | null) =>
  !hidden && wasHidden && !!current
