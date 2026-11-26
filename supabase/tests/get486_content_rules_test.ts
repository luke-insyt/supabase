// GET-486 B2 (S3) — the content_rules migration on a real Postgres (PGlite, in-process; no
// Docker, no network, no secrets). Runs 20261126180000_get486_content_rules.sql on top of the
// GET-470 legal schema (_legal_pglite.ts) and asserts feature.md §2.3, §2.4, §2.7:
// registry type + immutability, append-only confirmations + the one anonymise path, the RPCs
// (rules_changed, rules_ticks_invalid, not_owner, null-current, owner filter, legacy rows without
// correlation_id), grants (42501 for authenticated), and the D-9 deletion trigger with and
// without insyt_reports present. Destructive checks (delete/truncate) run here, never on staging.
//
// Run (from the supabase repo root):
//   DENO_NO_PACKAGE_JSON=1 npx -y deno@2.1.4 test -A supabase/tests/get486_content_rules_test.ts
import { assert, assertEquals } from 'jsr:@std/assert@1'
import { code, migrated, msg, one, publish, read, SHA_B, SHA_C, user, type Db } from './_legal_pglite.ts'

const B2 = await read('20261126180000_get486_content_rules.sql')
const TICKS = ['own_work', 'opinions', 'no_confidential', 'minors_initials', 'images_licensed']
const SORTED = [...TICKS].sort()

// The insyts columns B2 relies on (the GET-470 stand-in only models what GET-470 touched).
const INSYTS = `
alter table public.insyts
  add column id uuid not null default gen_random_uuid() unique,
  add column correlation_id uuid,
  add column creator_auth_user_id uuid,
  add column is_hidden boolean default false;
-- Like staging: the API roles read insyts through column grants only.
revoke all on public.insyts from anon, authenticated;
grant select (insyt_id, creator_email, visibility) on public.insyts to anon, authenticated;
`

async function db(opts: { live?: boolean; reports?: boolean } = {}): Promise<Db> {
  const pg = await migrated()
  await pg.exec(INSYTS)
  await pg.exec(B2)
  if (opts.reports) {
    // B4's table (shape from feature.md §2.6, only the columns the follow-up trigger touches).
    await pg.exec(`create table public.insyt_reports (
      id uuid primary key default gen_random_uuid(), insyt_row_id uuid, reason text, note text,
      reporter_auth_user_id uuid, reporter_email text, reporter_ip inet, reporter_deleted_at timestamptz)`)
  }
  if (opts.live ?? true) await publish(pg, 'content_rules', 'v1.0', SHA_B, true, 'In short.')
  return pg
}

async function insyt(pg: Db, owner: string | null, opts: { corr?: string | null; email?: string; rev?: number } = {}) {
  const corr = opts.corr === undefined ? crypto.randomUUID() : opts.corr
  const r = await one<{ id: string }>(
    pg,
    `insert into public.insyts (insyt_id, creator_email, correlation_id, creator_auth_user_id, content_rev)
     values ($1, $2, $3, $4, $5) returning id`,
    [`slug-${crypto.randomUUID().slice(0, 8)}`, opts.email ?? null, corr, owner, opts.rev ?? 0],
  )
  return { id: r.id, corr }
}

const rec = (
  pg: Db,
  a: { user: string; corr?: string | null; row?: string | null; version?: string; ticks?: string[]; ctx?: string; rev?: number; ip?: string | null },
) =>
  one<{ id: string }>(
    pg,
    `select public.record_rules_confirmation($1, $2, $3, $4, $5, $6, $7, $8, $9) as id`,
    [a.user, a.corr ?? null, a.row ?? null, a.version ?? 'v1.0', a.ticks ?? TICKS, a.ctx ?? 'publish', a.rev ?? 0, a.ip ?? '203.0.113.7', 'UA/1'],
  )

const needed = async (pg: Db, row: string) =>
  (await one<{ n: boolean }>(pg, `select public.rules_confirmation_needed($1) n`, [row])).n

Deno.test('registry: content_rules is a valid type; other types untouched; still immutable', async () => {
  const pg = await db()
  const row = await one<{ display_text: string; is_current: boolean }>(
    pg,
    `select display_text, is_current from agreement_versions where document_type = 'content_rules'`,
  )
  assertEquals(row, { display_text: 'In short.', is_current: true })
  assert((await msg(pg.query(`insert into agreement_versions (document_type, version, title, url, effective_date, sha256)
    values ('bogus', 'v1', 't', 'u', '2026-12-01', $1)`, [SHA_C]))).includes('document_type_check'))
  assert((await msg(pg.query(`update agreement_versions set display_text = 'x' where document_type = 'content_rules'`))).includes('immutable'))
  assert((await msg(pg.query(`delete from agreement_versions where document_type = 'content_rules'`))).includes('never be removed'))
})

Deno.test('content_rules_tick_ids() is the sorted literal', async () => {
  const pg = await db()
  assertEquals((await one<{ t: string[] }>(pg, `select public.content_rules_tick_ids() t`)).t, SORTED)
})

Deno.test('record: public submit by correlation_id → one row, server time, sorted ticks, IP/UA (AC3.4)', async () => {
  const pg = await db()
  const u = await user(pg, 'a@x.test')
  const corr = crypto.randomUUID()
  const { id } = await rec(pg, { user: u, corr })
  const row = await one<Record<string, unknown>>(
    pg,
    `select correlation_id, insyt_row_id, auth_user_id, rules_version, ticks, context, content_rev,
            host(ip) ip, user_agent, confirmed_at <= now() as server_time
       from insyt_rules_confirmations where id = $1`,
    [id],
  )
  assertEquals(row, {
    correlation_id: corr, insyt_row_id: null, auth_user_id: u, rules_version: 'v1.0', ticks: SORTED,
    context: 'publish', content_rev: 0, ip: '203.0.113.7', user_agent: 'UA/1', server_time: true,
  })
  // a malformed IP is stored as null, never an error
  const r2 = await rec(pg, { user: u, corr, ip: 'not-an-ip' })
  assertEquals((await one<{ ip: string | null }>(pg, `select ip::text from insyt_rules_confirmations where id = $1`, [r2.id])).ip, null)
})

Deno.test('record: stale version → rules_changed (detail = current); bad ticks → rules_ticks_invalid', async () => {
  const pg = await db()
  const u = await user(pg, 'a@x.test')
  const corr = crypto.randomUUID()
  const err = await (async () => {
    try { await rec(pg, { user: u, corr, version: 'v0.9' }) } catch (e) { return e as { message: string; detail?: string } }
  })()
  assertEquals(err?.message, 'rules_changed')
  assertEquals(err?.detail, 'v1.0')
  for (const ticks of [TICKS.slice(1), [...TICKS.slice(1), 'own_work', 'own_work'], [...TICKS, 'x'], []]) {
    assertEquals(await msg(rec(pg, { user: u, corr, ticks })), 'rules_ticks_invalid', JSON.stringify(ticks))
  }
  assertEquals(await msg(rec(pg, { user: u, corr, ctx: 'bogus' })), 'rules_context_invalid')
})

Deno.test('record: null-current → rules_not_live, nothing written', async () => {
  const pg = await db({ live: false })
  const u = await user(pg, 'a@x.test')
  assertEquals(await msg(rec(pg, { user: u, corr: crypto.randomUUID() })), 'rules_not_live')
  assertEquals((await one<{ n: number }>(pg, `select count(*)::int n from insyt_rules_confirmations`)).n, 0)
})

Deno.test('record: a stranger’s correlation_id or row → not_owner', async () => {
  const pg = await db()
  const owner = await user(pg, 'owner@x.test')
  const stranger = await user(pg, 'stranger@x.test')
  const i = await insyt(pg, owner)
  assertEquals(await msg(rec(pg, { user: stranger, corr: i.corr })), 'not_owner')
  assertEquals(await msg(rec(pg, { user: stranger, row: i.id, ctx: 'unhide' })), 'not_owner')
  assertEquals(await msg(rec(pg, { user: owner, row: crypto.randomUUID(), ctx: 'unhide' })), 'insyt_not_found')
  // the owner can
  await rec(pg, { user: owner, row: i.id, ctx: 'unhide' })
})

Deno.test('legacy rows: owner by creator_email when creator_auth_user_id is null; key = row id without correlation_id', async () => {
  const pg = await db()
  const owner = await user(pg, 'Legacy@X.test')
  const i = await insyt(pg, null, { corr: null, email: 'legacy@x.test', rev: 2 })
  assertEquals(await needed(pg, i.id), true)
  const { id } = await rec(pg, { user: owner, row: i.id, ctx: 'unhide', rev: 2 })
  assertEquals(
    (await one<{ c: string }>(pg, `select correlation_id::text c from insyt_rules_confirmations where id = $1`, [id])).c,
    i.id,
  )
  assertEquals(await needed(pg, i.id), false)
})

Deno.test('rules_confirmation_needed: null-current false; no confirmation true; same rev false; rev or version moved true', async () => {
  const pg = await db({ live: false })
  const u = await user(pg, 'a@x.test')
  const i = await insyt(pg, u)
  assertEquals(await needed(pg, i.id), false, 'null-current')
  await publish(pg, 'content_rules', 'v1.0', SHA_B, true, 'In short.')
  assertEquals(await needed(pg, i.id), true, 'never confirmed')
  await rec(pg, { user: u, corr: i.corr }) // publish at rev 0, before the row id is known
  assertEquals(await needed(pg, i.id), false, 'publish confirmation covers rev 0')
  await pg.query(`update insyts set content_rev = 1 where id = $1`, [i.id])
  assertEquals(await needed(pg, i.id), true, 'content edited since')
  await rec(pg, { user: u, row: i.id, ctx: 'update_published', rev: 1 })
  assertEquals(await needed(pg, i.id), false)
  // a new rules version made current → needed again
  await publish(pg, 'content_rules', 'v1.1', SHA_C)
  await pg.exec(`update agreement_versions set is_current = false where document_type = 'content_rules' and version = 'v1.0';
                 update agreement_versions set is_current = true where document_type = 'content_rules' and version = 'v1.1'`)
  assertEquals(await needed(pg, i.id), true, 'rules version changed')
  assertEquals(await needed(pg, crypto.randomUUID()), false, 'unknown row')
})

Deno.test('rules_confirmation_needed: only the OWNER’s confirmations count', async () => {
  const pg = await db()
  const owner = await user(pg, 'owner@x.test')
  const other = await user(pg, 'other@x.test')
  const i = await insyt(pg, owner)
  // a stray row by someone else with the same key (written directly, as the RPC would refuse it)
  await pg.query(
    `insert into insyt_rules_confirmations (correlation_id, auth_user_id, rules_version, ticks, context, content_rev)
     values ($1, $2, 'v1.0', $3, 'publish', 0)`,
    [i.corr, other, SORTED],
  )
  assertEquals(await needed(pg, i.id), true)
})

Deno.test('append-only: update/delete/truncate refused, even for the table owner; anonymise path only', async () => {
  const pg = await db()
  const u = await user(pg, 'a@x.test')
  const { id } = await rec(pg, { user: u, corr: crypto.randomUUID() })
  assert((await msg(pg.query(`update insyt_rules_confirmations set content_rev = 9 where id = $1`, [id]))).includes('append-only'))
  assert((await msg(pg.query(`update insyt_rules_confirmations set ip = null where id = $1`, [id]))).includes('append-only'))
  assert((await msg(pg.query(`delete from insyt_rules_confirmations where id = $1`, [id]))).includes('append-only'))
  assert((await msg(pg.query(`truncate insyt_rules_confirmations`))).includes('append-only'))
  await pg.query(`update insyt_rules_confirmations set ip = null, user_agent = null, anonymised_at = now() where id = $1`, [id])
  assert((await msg(pg.query(`update insyt_rules_confirmations set anonymised_at = now() where id = $1`, [id]))).includes('append-only'))
})

Deno.test('grants: authenticated gets 42501 on every new RPC and can’t write; reads only its own rows', async () => {
  const pg = await db()
  const u = await user(pg, 'a@x.test')
  const other = await user(pg, 'b@x.test')
  await rec(pg, { user: u, corr: crypto.randomUUID() })
  await rec(pg, { user: other, corr: crypto.randomUUID() })
  await pg.exec(`set role authenticated; select set_config('request.jwt.claim.sub', '${u}', false)`)
  for (const sql of [
    `select public.content_rules_tick_ids()`,
    `select public.get486_insyt_owner(gen_random_uuid())`,
    `select public.rules_confirmation_needed(gen_random_uuid())`,
    `select public.record_rules_confirmation('${u}', gen_random_uuid(), null, 'v1.0', array['own_work'], 'publish', 0, null, null)`,
    `insert into insyt_rules_confirmations (correlation_id, auth_user_id, rules_version, ticks, context, content_rev) values (gen_random_uuid(), '${u}', 'v1.0', '{}', 'publish', 0)`,
    `select content_rev from insyts`,
  ]) {
    assertEquals(await code(pg.query(sql)), '42501', sql)
  }
  assertEquals((await one<{ n: number }>(pg, `select count(*)::int n from insyt_rules_confirmations`)).n, 1)
  await pg.exec(`reset role`)
  await pg.exec(`set role anon`)
  assertEquals(await code(pg.query(`select * from insyt_rules_confirmations`)), '42501')
  await pg.exec(`reset role`)
})

Deno.test('account deletion: confirmations kept with auth_user_id raw, IP/UA nulled (AC3.9) — without insyt_reports', async () => {
  const pg = await db()
  const u = await user(pg, 'a@x.test')
  await rec(pg, { user: u, corr: crypto.randomUUID() })
  await rec(pg, { user: u, corr: crypto.randomUUID() })
  await pg.query(`delete from auth.users where id = $1`, [u])
  const rows = (await pg.query<Record<string, unknown>>(
    `select auth_user_id, ip, user_agent, anonymised_at is not null anon from insyt_rules_confirmations`,
  )).rows
  assertEquals(rows.length, 2)
  for (const r of rows) assertEquals(r, { auth_user_id: u, ip: null, user_agent: null, anon: true })
  // the GET-470 trigger still runs next to it
  assertEquals(
    (await one<{ n: number }>(pg, `select count(*)::int n from pg_trigger where tgrelid = 'auth.users'::regclass and tgname like 'on_auth_user_deleted_anonymise_%'`)).n,
    2,
  )
})

Deno.test('account deletion (D-9): with insyt_reports present too, both are anonymised and the delete succeeds', async () => {
  const pg = await db({ reports: true })
  const u = await user(pg, 'a@x.test')
  await rec(pg, { user: u, corr: crypto.randomUUID() })
  await pg.query(
    `insert into insyt_reports (reason, note, reporter_auth_user_id, reporter_email, reporter_ip) values ('other', 'kept', $1, 'a@x.test', '203.0.113.1')`,
    [u],
  )
  await pg.query(`delete from auth.users where id = $1`, [u])
  assertEquals(
    await one(pg, `select note, reporter_auth_user_id, reporter_email, reporter_ip, reporter_deleted_at is not null d from insyt_reports`),
    { note: 'kept', reporter_auth_user_id: null, reporter_email: null, reporter_ip: null, d: true },
  )
  assertEquals((await one<{ a: boolean }>(pg, `select anonymised_at is not null a from insyt_rules_confirmations`)).a, true)
})

Deno.test('the migration is re-runnable (idempotent)', async () => {
  const pg = await db()
  await pg.exec(B2)
  assertEquals((await one<{ n: number }>(pg, `select count(*)::int n from agreement_versions where document_type = 'content_rules'`)).n, 1)
})
