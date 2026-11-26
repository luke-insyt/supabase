// GET-470 — accept-agreement: type-filtered current version, the ledger-only write via
// record_insyter_acceptance (GET-486 A1), server-secret request meta.
// Run: DENO_NO_PACKAGE_JSON=1 deno test supabase/functions/accept-agreement/
import { assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts'
import { requestMeta } from '../_shared/request-meta.ts'
import { acceptRpcParams, currentInsyterVersion, recordInsyterAcceptance } from './logic.ts'

function fakeSvc(opts: {
  current?: string | null
  readError?: { message: string } | null
  rpcData?: unknown
  rpcError?: { message: string } | null
}) {
  const seen: unknown[] = []
  const chain = {
    select: (cols: string) => (seen.push(['select', cols]), chain),
    eq: (col: string, val: unknown) => (seen.push(['eq', col, val]), chain),
    maybeSingle: () =>
      Promise.resolve({
        data: opts.current == null ? null : { version: opts.current },
        error: opts.readError ?? null,
      }),
  }
  const svc = {
    from: (t: string) => (seen.push(['from', t]), chain),
    rpc: (fn: string, args: unknown) => {
      seen.push(['rpc', fn, args])
      return Promise.resolve({ data: opts.rpcData ?? null, error: opts.rpcError ?? null })
    },
  }
  // deno-lint-ignore no-explicit-any
  return { svc: svc as any, seen }
}

const meta = { ip: '203.0.113.5', userAgent: 'RealBrowser/1.0', trusted: true }
const args = { authUserId: 'u-1', email: 'a@b.test', signatureName: 'Ana Insyter', version: 'v1.0', meta }

Deno.test('currentInsyterVersion filters by document_type = insyter_agreement (feature §2.2 hazard)', async () => {
  const { svc, seen } = fakeSvc({ current: 'v1.0' })
  assertEquals(await currentInsyterVersion(svc), { version: 'v1.0', error: null })
  assertEquals(seen, [
    ['from', 'agreement_versions'],
    ['select', 'version'],
    ['eq', 'document_type', 'insyter_agreement'],
    ['eq', 'is_current', true],
  ])
})

Deno.test('currentInsyterVersion: none current → null; read error → error message', async () => {
  assertEquals(await currentInsyterVersion(fakeSvc({ current: null }).svc), { version: null, error: null })
  assertEquals(await currentInsyterVersion(fakeSvc({ readError: { message: 'boom' } }).svc), { version: null, error: 'boom' })
})

Deno.test('recordInsyterAcceptance: ONE rpc call carrying signature, version and request meta', async () => {
  const { svc, seen } = fakeSvc({ rpcData: 'ledger-id' })
  assertEquals(await recordInsyterAcceptance(svc, args), { ok: true, ledgerId: 'ledger-id' })
  assertEquals(seen, [[
    'rpc',
    'record_insyter_acceptance',
    { p_user: 'u-1', p_email: 'a@b.test', p_signature_name: 'Ana Insyter', p_version: 'v1.0', p_ip: '203.0.113.5', p_ua: 'RealBrowser/1.0' },
  ]])
})

Deno.test('recordInsyterAcceptance: terms_changed from the DB is a 409, anything else a 500', async () => {
  const stale = await recordInsyterAcceptance(fakeSvc({ rpcError: { message: 'terms_changed' } }).svc, args)
  assertEquals(stale, { ok: false, status: 409, body: { error: 'Not the current agreement version', code: 'terms_changed' } })
  const other = await recordInsyterAcceptance(fakeSvc({ rpcError: { message: 'connection reset' } }).svc, args)
  assertEquals(other, { ok: false, status: 500, body: { error: 'connection reset' } })
})

Deno.test('server-secret meta: forged body ip is ignored on a direct call, used with the secret', () => {
  const body = { ip: '6.6.6.6', user_agent: 'Forged/1.0' }
  const direct = requestMeta(new Headers({ 'user-agent': 'Safari', 'cf-connecting-ip': '198.51.100.4' }), body, 'sec')
  assertEquals(acceptRpcParams({ ...args, meta: direct }).p_ip, '198.51.100.4')
  assertEquals(acceptRpcParams({ ...args, meta: direct }).p_ua, 'Safari')
  const viaServer = requestMeta(new Headers({ 'x-gi-server-secret': 'sec', 'user-agent': 'node' }), body, 'sec')
  assertEquals(acceptRpcParams({ ...args, meta: viaServer }).p_ip, '6.6.6.6')
  assertEquals(acceptRpcParams({ ...args, meta: viaServer }).p_ua, 'Forged/1.0')
})
