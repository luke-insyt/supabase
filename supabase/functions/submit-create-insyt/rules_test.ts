// GET-486 B2 — the Content & Image Rules gate. Run: deno test supabase/functions/submit-create-insyt/
import { assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts'
import {
  contentChanged,
  currentRulesVersion,
  needsRulesForSubmit,
  parseRulesConfirmation,
  recordRulesConfirmation,
  RULE_TICK_IDS,
  rulesRefusal,
  rulesRelevant,
  rpcErrorRefusal,
  ticksValid,
} from './rules.ts'

const TICKS = ['own_work', 'opinions', 'no_confidential', 'minors_initials', 'images_licensed']
const ok = { version: 'v1.0', ticks: TICKS }

Deno.test('RULE_TICK_IDS = the literal of content_rules_tick_ids() (D-3), sorted', async () => {
  assertEquals([...RULE_TICK_IDS], ['images_licensed', 'minors_initials', 'no_confidential', 'opinions', 'own_work'])
  const sql = await Deno.readTextFile(
    new URL('../../migrations/20261126180000_get486_content_rules.sql', import.meta.url),
  )
  const m = /array\[('images_licensed'[^\]]*)\]::text\[\]/.exec(sql)
  assertEquals(m?.[1].split(',').map((s) => s.trim().replace(/'/g, '')), [...RULE_TICK_IDS])
})

Deno.test('ticksValid: the five ids in any order, each once', () => {
  assertEquals(ticksValid(TICKS), true)
  assertEquals(ticksValid(TICKS.slice(0, 4)), false)
  assertEquals(ticksValid([...TICKS.slice(0, 4), 'own_work']), false)
  assertEquals(ticksValid([...TICKS, 'extra']), false)
  assertEquals(ticksValid([...TICKS.slice(0, 4), 'bogus']), false)
})

Deno.test('parseRulesConfirmation: absent → null, malformed → invalid', () => {
  assertEquals(parseRulesConfirmation(undefined), null)
  assertEquals(parseRulesConfirmation(null), null)
  assertEquals(parseRulesConfirmation('x'), 'invalid')
  assertEquals(parseRulesConfirmation([]), 'invalid')
  assertEquals(parseRulesConfirmation({ version: '', ticks: TICKS }), 'invalid')
  assertEquals(parseRulesConfirmation({ version: 'v1.0', ticks: 'own_work' }), 'invalid')
  assertEquals(parseRulesConfirmation({ version: 'v1.0', ticks: [1] }), 'invalid')
  assertEquals(parseRulesConfirmation({ version: ' v1.0 ', ticks: TICKS }), ok)
})

Deno.test('rulesRefusal: null-current → no gate, whatever the body says (AC3.3)', () => {
  assertEquals(rulesRefusal(null, undefined, true), null)
  assertEquals(rulesRefusal(null, { version: 'bogus', ticks: [] }, true), null)
  assertEquals(rulesRefusal(null, 'garbage', true), null)
})

Deno.test('rulesRefusal: a publish without ticks → 409 rules_confirmation_required', () => {
  assertEquals(rulesRefusal('v1.0', undefined, true), {
    status: 409,
    body: { error: 'rules_confirmation_required', current_version: 'v1.0' },
  })
})

Deno.test('rulesRefusal: an edit without ticks passes the early check (decided at persist)', () => {
  assertEquals(rulesRefusal('v1.0', undefined, false), null)
})

Deno.test('rulesRefusal: stale version → 409 rules_changed with current_version (AC3.3)', () => {
  assertEquals(rulesRefusal('v1.1', ok, true), {
    status: 409,
    body: { error: 'rules_changed', current_version: 'v1.1' },
  })
  // validated even where not required (an edit)
  assertEquals(rulesRefusal('v1.1', ok, false)?.body.error, 'rules_changed')
})

Deno.test('rulesRefusal: 4 ticks / malformed → 400 rules_ticks_invalid', () => {
  assertEquals(rulesRefusal('v1.0', { version: 'v1.0', ticks: TICKS.slice(1) }, true), {
    status: 400,
    body: { error: 'rules_ticks_invalid' },
  })
  assertEquals(rulesRefusal('v1.0', { nope: 1 }, false)?.status, 400)
})

Deno.test('rulesRefusal: the current version and five ticks → go on', () => {
  assertEquals(rulesRefusal('v1.0', ok, true), null)
})

Deno.test('needsRulesForSubmit / rulesRelevant: submit (and absent action) publishes; edits are relevant; drafts are not', () => {
  assertEquals(needsRulesForSubmit('submit'), true)
  assertEquals(needsRulesForSubmit(undefined), true)
  assertEquals(needsRulesForSubmit('update_published'), false)
  for (const a of ['submit', undefined, 'update_published', 'confirm_update']) assertEquals(rulesRelevant(a), true, String(a))
  for (const a of ['save_draft', 'discard', 'load_draft', 'list_drafts', 'purchase_status']) {
    assertEquals(rulesRelevant(a), false, a)
  }
})

const stored = { title: 'T', abstract: 'A', body_html: '<p>b</p>', thumbnail_url: 'u/c/cover.jpg' }

Deno.test('contentChanged: price-, tag- or taxonomy-only edits are not content (OQ-5)', () => {
  // the content fields are identical; price/tags/sport don't take part at all
  assertEquals(contentChanged(stored, { ...stored }, ['a', 'b'], ['b', 'a']), false)
})

Deno.test('contentChanged: title, abstract, body, cover or attachments → content', () => {
  assertEquals(contentChanged(stored, { ...stored, title: 'T2' }, [], []), true)
  assertEquals(contentChanged(stored, { ...stored, abstract: 'A2' }, [], []), true)
  assertEquals(contentChanged(stored, { ...stored, body_html: null }, [], []), true)
  assertEquals(contentChanged(stored, { ...stored, thumbnail_url: 'u/c/new.jpg' }, [], []), true)
  assertEquals(contentChanged(stored, { ...stored }, ['a'], ['a', 'b']), true)
  assertEquals(contentChanged(stored, { ...stored }, ['a'], ['b']), true)
})

Deno.test('rpcErrorRefusal maps the RPC errors', () => {
  assertEquals(rpcErrorRefusal({ message: 'rules_changed', details: 'v2.0' }, 'v1.0'), {
    status: 409,
    body: { error: 'rules_changed', current_version: 'v2.0' },
  })
  assertEquals(rpcErrorRefusal({ message: 'rules_ticks_invalid' }, 'v1.0').status, 400)
  assertEquals(rpcErrorRefusal({ message: 'not_owner' }, 'v1.0'), { status: 403, body: { error: 'not_owner' } })
  assertEquals(rpcErrorRefusal({ message: 'insyt_not_found' }, 'v1.0').status, 404)
  assertEquals(rpcErrorRefusal({ message: 'rules_not_live' }, 'v1.0').body.error, 'rules_changed')
  assertEquals(rpcErrorRefusal({ message: 'connection reset' }, 'v1.0'), {
    status: 500,
    body: { error: 'rules_check_failed' },
  })
})

// Just enough of supabase-js.
function fakeSvc(opts: { current?: string | null; readError?: string; rpcError?: { message: string; details?: string } }) {
  const calls: unknown[] = []
  const chain = {
    select: () => chain,
    eq: (c: string, v: unknown) => (calls.push(['eq', c, v]), chain),
    maybeSingle: () =>
      Promise.resolve({
        data: opts.current ? { version: opts.current } : null,
        error: opts.readError ? { message: opts.readError } : null,
      }),
  }
  const svc = {
    from: (t: string) => (calls.push(['from', t]), chain),
    rpc: (fn: string, args: unknown) => (calls.push(['rpc', fn, args]), Promise.resolve({ error: opts.rpcError ?? null })),
  }
  // deno-lint-ignore no-explicit-any
  return { svc: svc as any, calls }
}

Deno.test('currentRulesVersion reads the current content_rules row only', async () => {
  const { svc, calls } = fakeSvc({ current: 'v1.0' })
  assertEquals(await currentRulesVersion(svc), { version: 'v1.0', error: null })
  assertEquals(calls, [['from', 'agreement_versions'], ['eq', 'document_type', 'content_rules'], ['eq', 'is_current', true]])
  assertEquals(await currentRulesVersion(fakeSvc({ current: null }).svc), { version: null, error: null })
  assertEquals((await currentRulesVersion(fakeSvc({ readError: 'boom' }).svc)).error, 'boom')
})

Deno.test('recordRulesConfirmation passes identity, context, rev and meta to the RPC', async () => {
  const { svc, calls } = fakeSvc({})
  const r = await recordRulesConfirmation(svc, 'v1.0', {
    authUserId: 'u1',
    correlationId: 'c1',
    rowId: null,
    confirmation: ok,
    context: 'publish',
    contentRev: 0,
    ip: '203.0.113.9',
    userAgent: 'UA',
  })
  assertEquals(r, null)
  assertEquals(calls, [
    [
      'rpc',
      'record_rules_confirmation',
      {
        p_user: 'u1',
        p_correlation: 'c1',
        p_row_id: null,
        p_version: 'v1.0',
        p_ticks: TICKS,
        p_context: 'publish',
        p_rev: 0,
        p_ip: '203.0.113.9',
        p_ua: 'UA',
      },
    ],
  ])
})

Deno.test('recordRulesConfirmation: a stranger’s correlation_id → 403 not_owner', async () => {
  const { svc } = fakeSvc({ rpcError: { message: 'not_owner' } })
  const r = await recordRulesConfirmation(svc, 'v1.0', {
    authUserId: 'u2',
    correlationId: 'c1',
    rowId: null,
    confirmation: ok,
    context: 'publish',
    contentRev: 0,
    ip: null,
    userAgent: null,
  })
  assertEquals(r, { status: 403, body: { error: 'not_owner' } })
})
