// GET-470 — legal registry + acceptance ledger migrations, checked on a real Postgres (PGlite,
// in-process; no Docker, no network, no secrets).
//
// Runs, in order, on a stand-in of the pre-GET-470 schema (built from the real earlier
// migrations where possible: GET-330's v1.1 seed, GET-357's notices, GET-332 §1's purchase
// stamp):
//   20261125120000_get470_drop_agreement_v1_1.sql   (P0)
//   20261125121000_get470_registry_columns.sql      (P1, migration A)
//   20261125122000_get470_legal_registry.sql        (P2, migration B)
//   20261126120000_get470_drop_legacy_acceptances.sql (GET-486 A1 = GET-470 P7: legacy table dropped)
// and asserts the P0/P2 test lists of implementation.md that can run offline — including the
// destructive ones (registry/ledger immutability, truncate, user deletion) that must never
// run against live staging (those are also in supabase/tests/sql/legal_destructive.sql for a
// psql run on a Supabase branch).
//
// The stand-in still creates public.agreement_acceptances: it models the schema BEFORE GET-470,
// which the historical migrations (P0, B's backfill) need. After `migrated()` the table is gone
// (GET-486 A1), so every current-state test runs against the ledger-only schema.
//
// Run (from the supabase repo root):
//   DENO_NO_PACKAGE_JSON=1 deno test -A supabase/tests/get470_legal_registry_test.ts
//   no local Deno: DENO_NO_PACKAGE_JSON=1 npx -y deno@2.1.4 test -A supabase/tests/get470_legal_registry_test.ts
import { assert, assertEquals } from 'jsr:@std/assert@1'
import {
  DROP_LEGACY,
  MIG_A,
  MIG_B,
  P0,
  SHA_B,
  SHA_C,
  V10_SHA,
  base,
  code,
  migrated,
  msg,
  one,
  publish,
  tableExists,
  throughB,
  user,
  type Db,
} from './_legal_pglite.ts'

const rec = (pg: Db, args: unknown[]) =>
  pg.query<{ id: string | null }>(
    `select public.record_terms_acceptance($1, $2, $3, $4, $5, $6, $7, $8, $9, $10) as id`,
    args,
  )

// ---------------------------------------------------------------------------- P0

Deno.test('P0: v1.1 unused → removed; v1.0 untouched (AC0.2, AC0.3)', async () => {
  const pg = await base()
  assertEquals((await one<{ n: number }>(pg, `select count(*)::int n from agreement_versions where version = 'v1.1'`)).n, 1)
  await pg.exec(P0)
  assertEquals((await pg.query(`select version, is_current from agreement_versions order by version`)).rows, [
    { version: 'v1.0', is_current: true },
  ])
})

Deno.test('P0: a v1.1 acceptance, a v1.1-stamped user or a current v1.1 → raises, nothing deleted (AC0.1)', async () => {
  for (const seed of [
    `insert into agreement_acceptances (auth_user_id, email, signature_name, version) values (gen_random_uuid(), 'a@b', 'A', 'v1.1')`,
    `insert into users (auth_user_id, email, agreement_version) values (gen_random_uuid(), 'a@b', 'v1.1')`,
    `update agreement_versions set is_current = (version = 'v1.1')`,
  ]) {
    const pg = await base()
    await pg.exec(seed)
    const m = await msg(pg.exec(P0))
    assert(m.includes('v1.1 is in use'), m)
    await pg.exec('rollback')
    assertEquals((await one<{ n: number }>(pg, `select count(*)::int n from agreement_versions where version = 'v1.1'`)).n, 1)
  }
})

// ---------------------------------------------------------------------------- registry

Deno.test('registry: existing rows typed insyter_agreement, v1.0 hash pinned, sha256 NOT NULL, no type default', async () => {
  const pg = await migrated()
  assertEquals((await pg.query(`select document_type, version, sha256 from agreement_versions`)).rows, [
    { document_type: 'insyter_agreement', version: 'v1.0', sha256: V10_SHA },
  ])
  // no default: a new row must name its type (AC1.1)
  assertEquals(await code(pg.query(
    `insert into agreement_versions (version, title, url, effective_date, sha256) values ('v9', 't', 'u', now(), $1)`, [SHA_B])), '23502')
  assertEquals(await code(pg.query(
    `insert into agreement_versions (document_type, version, title, url, effective_date) values ('privacy', 'v9', 't', 'u', now())`)), '23502')
  assertEquals(await code(publish(pg, 'cookies', 'v1.0', SHA_B)), '23514')
  assertEquals(await code(publish(pg, 'privacy', 'v1.0', 'NOT-HEX')), '23514')
})

Deno.test('registry: migration B refuses a row without sha256 and a conflicting v1.0 hash', async () => {
  const pg = await base()
  await pg.exec(P0)
  await pg.exec(MIG_A)
  await pg.exec(`insert into agreement_versions (document_type, version, title, url, effective_date) values ('privacy', 'v0', 't', 'u', now())`)
  assert((await msg(pg.exec(MIG_B))).includes('without sha256 (privacy v0)'))
  await pg.exec('rollback')

  const pg2 = await base()
  await pg2.exec(P0)
  await pg2.exec(MIG_A)
  await pg2.exec(`update agreement_versions set sha256 = '${SHA_C}' where version = 'v1.0'`)
  assert((await msg(pg2.exec(MIG_B))).includes('different sha256'))
})

Deno.test('registry: unique per (type, version); one current PER TYPE (AC1.3)', async () => {
  const pg = await migrated()
  await publish(pg, 'buyer_terms', 'v1.0', SHA_B, true) // same version string as insyter v1.0: fine
  await publish(pg, 'privacy', 'v1.0', SHA_C, true)
  assertEquals(await code(publish(pg, 'buyer_terms', 'v1.0', SHA_C)), '23505')
  assertEquals(await code(publish(pg, 'buyer_terms', 'v2.0', SHA_C, true)), '23505')
  assertEquals((await one<{ n: number }>(pg, `select count(*)::int n from agreement_versions where is_current`)).n, 3)
})

Deno.test('registry: immutable except is_current (+ sha256 null→value once); never deleted (AC1.4)', async () => {
  const pg = await migrated()
  await publish(pg, 'privacy', 'v1.0', SHA_B)
  await pg.exec(`update agreement_versions set is_current = true where document_type = 'privacy'`)
  for (const sql of [
    `update agreement_versions set title = 'x' where version = 'v1.0' and document_type = 'privacy'`,
    `update agreement_versions set effective_date = '2030-01-01' where document_type = 'privacy'`,
    `update agreement_versions set url = 'https://elsewhere' where document_type = 'privacy'`,
    `update agreement_versions set sha256 = '${SHA_C}' where document_type = 'privacy'`,
    `delete from agreement_versions where document_type = 'insyter_agreement' and version = 'v1.0'`,
    `truncate agreement_versions cascade`,
  ]) {
    assert((await msg(pg.exec(sql))).includes('agreement_versions'), sql)
  }
  // still there and unchanged
  assertEquals(await one(pg, `select title, sha256 from agreement_versions where document_type = 'privacy'`), {
    title: 'privacy v1.0',
    sha256: SHA_B,
  })
})

Deno.test('registry: anon/authenticated read-only (AC1.5)', async () => {
  const pg = await migrated()
  for (const role of ['anon', 'authenticated']) {
    await pg.exec(`set role ${role}`)
    assertEquals((await pg.query(`select version from public.agreement_versions`)).rows.length, 1)
    assertEquals(await code(pg.query(
      `insert into public.agreement_versions (document_type, version, title, url, effective_date, sha256) values ('privacy', 'v1', 't', 'u', now(), '${SHA_B}')`)), '42501')
    assertEquals(await code(pg.query(`update public.agreement_versions set is_current = false`)), '42501')
    await pg.exec('reset role')
  }
})

// ---------------------------------------------------------------------------- ledger + RPCs

Deno.test('record_terms_acceptance: sha copied from the registry; email fallback; bad ip → null', async () => {
  const pg = await migrated()
  const u = await user(pg, 'buyer@getinsyts.test')
  await publish(pg, 'buyer_terms', 'v2.0', SHA_B, true)
  const id = (await rec(pg, [u, null, 'buyer_terms', 'v2.0', 'signup', null, null, 'not-an-ip', 'UA', true])).rows[0].id
  assert(id)
  assertEquals(await one(pg, `select email, sha256, context, ip, user_agent from terms_acceptances where id = $1`, [id]), {
    email: 'buyer@getinsyts.test',
    sha256: SHA_B,
    context: 'signup',
    ip: null,
    user_agent: 'UA',
  })
  const id2 = (await rec(pg, [u, 'x@y', 'buyer_terms', 'v2.0', 'reaccept', null, null, '203.0.113.4', null, true])).rows[0].id
  assertEquals((await one<{ ip: string }>(pg, `select host(ip) ip from terms_acceptances where id = $1`, [id2])).ip, '203.0.113.4')
})

Deno.test('record_terms_acceptance: stale version → terms_changed unless p_require_current = false (AC2.3)', async () => {
  const pg = await migrated()
  const u = await user(pg, 'b@getinsyts.test')
  await publish(pg, 'buyer_terms', 'v1.0', SHA_B, false)
  await publish(pg, 'buyer_terms', 'v2.0', SHA_C, true)
  const m = await msg(rec(pg, [u, null, 'buyer_terms', 'v1.0', 'reaccept', null, null, null, null, true]))
  assertEquals(m, 'terms_changed')
  // the checkout webhook: consented at session creation
  assert((await rec(pg, [u, null, 'buyer_terms', 'v1.0', 'checkout', 'cs_1', null, null, null, false])).rows[0].id)
  assertEquals(await msg(rec(pg, [u, null, 'buyer_terms', 'v9.9', 'reaccept', null, null, null, null, false])), 'unknown_version')
  assertEquals(await code(rec(pg, [u, null, 'buyer_terms', 'v2.0', 'bogus', null, null, null, null, true])), '23514')
})

Deno.test('record_terms_acceptance: ref_once — a webhook retry returns null and writes nothing (AC4.4)', async () => {
  const pg = await migrated()
  const u = await user(pg, 'b@getinsyts.test')
  await publish(pg, 'buyer_terms', 'v2.0', SHA_B, true)
  await publish(pg, 'withdrawal_waiver', 'v1.0', SHA_C, true, 'I want immediate access…')
  const a = [u, null, 'buyer_terms', 'v2.0', 'checkout', 'cs_9', '2026-12-01T10:00:00Z', null, null, false]
  assert((await rec(pg, a)).rows[0].id)
  assertEquals((await rec(pg, a)).rows[0].id, null)
  // the waiver row for the same session is a different document type: allowed once
  assert((await rec(pg, [u, null, 'withdrawal_waiver', 'v1.0', 'checkout', 'cs_9', null, null, null, false])).rows[0].id)
  assertEquals((await one<{ n: number }>(pg, `select count(*)::int n from terms_acceptances where reference_id = 'cs_9'`)).n, 2)
})

Deno.test('ledger: append-only, even for the superuser; only the anonymise update passes (AC2.2)', async () => {
  const pg = await migrated()
  const u = await user(pg, 'b@getinsyts.test')
  await publish(pg, 'privacy', 'v1.0', SHA_B, true)
  const id = (await rec(pg, [u, null, 'privacy', 'v1.0', 'signup', null, null, '1.2.3.4', 'UA', true])).rows[0].id
  for (const sql of [
    `update terms_acceptances set version = 'v1.0', context = 'reaccept'`,
    `update terms_acceptances set accepted_at = now() - interval '1 day'`,
    `update terms_acceptances set email = null`, // partial anonymise isn't the anonymise path
    `delete from terms_acceptances`,
    `truncate terms_acceptances`,
  ]) {
    assert((await msg(pg.exec(sql))).includes('append-only'), sql)
  }
  assertEquals(await one<{ n: number }>(pg, `select public.anonymise_terms_acceptances($1) n`, [u]), { n: 1 })
  assertEquals(await one(pg, `select email, ip, user_agent, anonymised_at is not null as anon from terms_acceptances where id = $1`, [id]), {
    email: null,
    ip: null,
    user_agent: null,
    anon: true,
  })
  // once anonymised, nothing changes any more
  assert((await msg(pg.exec(`update terms_acceptances set anonymised_at = now()`))).includes('append-only'))
})

Deno.test('ledger + RPC grants: API roles cannot write; authenticated sees only own rows; 42501 on every RPC', async () => {
  const pg = await migrated()
  const me = await user(pg, 'me@getinsyts.test')
  const other = await user(pg, 'other@getinsyts.test')
  await publish(pg, 'privacy', 'v1.0', SHA_B, true)
  await rec(pg, [me, null, 'privacy', 'v1.0', 'signup', null, null, null, null, true])
  await rec(pg, [other, null, 'privacy', 'v1.0', 'signup', null, null, null, null, true])

  await pg.exec(`set role authenticated; select set_config('request.jwt.claim.sub', '${me}', false);`)
  assertEquals((await pg.query(`select auth_user_id from public.terms_acceptances`)).rows, [{ auth_user_id: me }])
  assertEquals(await code(pg.query(
    `insert into public.terms_acceptances (auth_user_id, document_type, version, sha256, context, accepted_at) values ('${me}', 'privacy', 'v1.0', '${SHA_B}', 'signup', now())`)), '42501')
  for (const call of [
    `select public.legal_current()`,
    `select public.buyer_terms_status('${me}')`,
    `select public.record_terms_acceptance('${me}', null, 'privacy', 'v1.0', 'signup')`,
    `select public.record_insyter_acceptance('${me}', null, 'Me', 'v1.0')`,
    `select public.anonymise_terms_acceptances('${other}')`,
    `select public.agreement_notices_claim('v1.0', array['${me}'::uuid])`,
    `select public.agreement_notices_record('${me}', 'v1.0', 'sent', null)`,
    `select public.submit_inquiry_proposal(gen_random_uuid(), '${me}', 'a', 'o', 1, 100, current_date, 5)`,
  ]) {
    assertEquals(await code(pg.query(call)), '42501', call)
  }
  await pg.exec(`set role anon`)
  assertEquals((await pg.query(`select * from public.terms_acceptances`).catch((e) => ({ rows: e.code }))).rows, '42501')
  await pg.exec(`reset role; select set_config('request.jwt.claim.sub', '', false);`)

  await pg.exec(`set role service_role`)
  assertEquals((await pg.query(`select document_type from public.legal_current()`)).rows, [
    { document_type: 'insyter_agreement' },
    { document_type: 'privacy' },
  ])
  await pg.exec(`reset role`)
})

Deno.test('buyer_terms_status: null-current → accepted; current → needs a row of that version', async () => {
  const pg = await migrated()
  const u = await user(pg, 'b@getinsyts.test')
  const st = () => one(pg, `select * from public.buyer_terms_status($1)`, [u])
  assertEquals(await st(), {
    buyer_terms: null, privacy: null, withdrawal_waiver: null, accepted_buyer_terms: true, acknowledged_privacy: true,
  })
  await publish(pg, 'buyer_terms', 'v2.0', SHA_B, true)
  await publish(pg, 'privacy', 'v1.0', SHA_C, true)
  await publish(pg, 'withdrawal_waiver', 'v1.0', 'd'.repeat(64), true, 'waiver sentence')
  assertEquals(await st(), {
    buyer_terms: 'v2.0', privacy: 'v1.0', withdrawal_waiver: 'v1.0', accepted_buyer_terms: false, acknowledged_privacy: false,
  })
  await rec(pg, [u, null, 'buyer_terms', 'v2.0', 'signup', null, null, null, null, true])
  assertEquals((await st() as { accepted_buyer_terms: boolean }).accepted_buyer_terms, true)
})

Deno.test('record_insyter_acceptance: one ledger row per call; become_insyter then reaccept; stale writes nothing (AC2.6)', async () => {
  const pg = await migrated()
  const u = await user(pg, 'ins@getinsyts.test')
  const call = (v: string) =>
    pg.query<{ id: string }>(`select public.record_insyter_acceptance($1, null, ' Ana ', $2, '198.51.100.7', 'UA') id`, [u, v])
  assert((await call('v1.0')).rows[0].id)
  assert((await call('v1.0')).rows[0].id)
  assertEquals((await pg.query(
    `select context, signature_name, sha256, email, host(ip) ip from terms_acceptances where auth_user_id = $1 order by recorded_at, context`, [u])).rows, [
    { context: 'become_insyter', signature_name: 'Ana', sha256: V10_SHA, email: 'ins@getinsyts.test', ip: '198.51.100.7' },
    { context: 'reaccept', signature_name: 'Ana', sha256: V10_SHA, email: 'ins@getinsyts.test', ip: '198.51.100.7' },
  ])
  assertEquals(await msg(call('v2.0')), 'terms_changed')
  assertEquals(await msg(pg.query(`select public.record_insyter_acceptance($1, null, '  ', 'v1.0')`, [u])), 'signature_required')
  assertEquals((await one<{ n: number }>(pg, `select count(*)::int n from terms_acceptances where auth_user_id = $1`, [u])).n, 2)
  // "no email for user" is kept on purpose (AC2.3 step 2)
  const noMail = (await one<{ id: string }>(pg, `insert into auth.users (email) values (null) returning id`)).id
  assertEquals(await code(pg.query(`select public.record_insyter_acceptance($1, null, 'X', 'v1.0')`, [noMail])), '22004')
})

Deno.test('deleting an auth user with ledger rows succeeds and anonymises them (AC8.1–8.3, AC2.5)', async () => {
  const pg = await migrated()
  const u = await user(pg, 'gone@getinsyts.test')
  const keep = await user(pg, 'stay@getinsyts.test')
  await pg.query(`select public.record_insyter_acceptance($1, null, 'Gone', 'v1.0', '1.2.3.4', 'UA')`, [u])
  await pg.query(`select public.record_insyter_acceptance($1, null, 'Stay', 'v1.0', '1.2.3.4', 'UA')`, [keep])
  await pg.query(`delete from auth.users where id = $1`, [u])
  assertEquals(await one(pg, `select auth_user_id, email, signature_name, ip, user_agent, anonymised_at is not null a from terms_acceptances where auth_user_id = $1`, [u]), {
    auth_user_id: u, email: null, signature_name: null, ip: null, user_agent: null, a: true,
  })
  assertEquals((await one<{ email: string }>(pg, `select email from terms_acceptances where auth_user_id = $1`, [keep])).email, 'stay@getinsyts.test')
})

// ---------------------------------------------------------------------------- purchases

const insertPurchase = (pg: Db, session: string, extra = '') =>
  pg.query(`insert into purchases (insyt_id, buyer_email, stripe_session_id${extra ? ', stripe_blob' : ''})
            values ('ins-1', 'buyer@x', $1${extra ? `, '${extra}'` : ''})`, [session])

async function checkoutRows(pg: Db, u: string, session: string) {
  await rec(pg, [u, null, 'buyer_terms', 'v2.0', 'checkout', session, '2026-12-01T10:00:00Z', null, null, false])
  await rec(pg, [u, null, 'withdrawal_waiver', 'v1.0', 'checkout', session, '2026-12-01T10:00:00Z', null, null, false])
}

Deno.test('purchase stamps: ledger first or purchase first, every row of the session ends up stamped (AC4.5)', async () => {
  const pg = await migrated()
  const u = await user(pg, 'b@getinsyts.test')
  await publish(pg, 'buyer_terms', 'v2.0', SHA_B, true)
  await publish(pg, 'withdrawal_waiver', 'v1.0', SHA_C, true, 'waiver')
  // order 1: ledger, then both writers
  await checkoutRows(pg, u, 'cs_a')
  await insertPurchase(pg, 'cs_a')
  await insertPurchase(pg, 'cs_a', '{"object":{"metadata":{}}}')
  // order 2: purchase rows, then ledger
  await insertPurchase(pg, 'cs_b')
  await insertPurchase(pg, 'cs_b', '{"object":{"metadata":{}}}')
  await checkoutRows(pg, u, 'cs_b')
  // a session without consent stays null
  await insertPurchase(pg, 'cs_c')
  const rows = (await pg.query<Record<string, unknown>>(
    `select stripe_session_id s, terms_version t, withdrawal_waiver_version w, withdrawal_waiver_at::text wa
       from purchases order by id`)).rows
  for (const r of rows.filter((r) => r.s !== 'cs_c')) {
    assertEquals([r.t, r.w, r.wa], ['v2.0', 'v1.0', '2026-12-01 10:00:00+00'], String(r.s))
  }
  assertEquals(rows.filter((r) => r.s === 'cs_c').map((r) => [r.t, r.w]), [[null, null]])
})

Deno.test('purchase stamps: the GET-332 anonymity + creator_email logic still runs', async () => {
  const pg = await migrated()
  const requester = await user(pg, 'req@getinsyts.test')
  const inq = (await one<{ id: string }>(pg,
    `insert into inquiries (requester_auth_user_id, is_anonymous) values ($1, true) returning id`, [requester])).id
  const prop = (await one<{ id: string }>(pg,
    `insert into inquiry_proposals (inquiry_id, abstract, outline_html, read_time_min, price_cents, deliver_by, terms_accepted_at)
     values ($1, 'a', 'o', 1, 100, current_date, now()) returning id`, [inq])).id
  await pg.query(`insert into insyts (insyt_id, creator_email, visibility, inquiry_proposal_id) values ('anon-1', 'c@x', 'private', $1)`, [prop])
  await pg.query(`insert into insyts (insyt_id, creator_email) values ('ins-1', 'c2@x')`)
  await pg.query(`insert into purchases (insyt_id, buyer_email, stripe_session_id) values ('anon-1', 'req@getinsyts.test', 'cs_anon')`)
  await pg.query(`insert into purchases (insyt_id, buyer_email, stripe_session_id) values ('ins-1', 'b@x', 'cs_pub')`)
  assertEquals((await pg.query(`select insyt_id, is_anonymous, creator_email from purchases order by id`)).rows, [
    { insyt_id: 'anon-1', is_anonymous: true, creator_email: 'c@x' },
    { insyt_id: 'ins-1', is_anonymous: false, creator_email: 'c2@x' },
  ])
})

Deno.test('purchases: new columns + purchases_rn_session_once rejects a second RN row', async () => {
  const pg = await migrated()
  await pg.query(`insert into purchases (insyt_id, stripe_session_id, writer, tax_amount_cents) values ('s', 'cs_1', 'rn_webhook', 144)`)
  await pg.query(`insert into purchases (insyt_id, stripe_session_id, writer) values ('s', 'cs_1', 'n8n')`)
  assertEquals(await code(pg.query(`insert into purchases (insyt_id, stripe_session_id, writer) values ('s', 'cs_1', 'rn_webhook')`)), '23505')
  assertEquals(await code(pg.query(`insert into purchases (insyt_id, stripe_session_id, writer) values ('s', 'cs_2', 'zapier')`)), '23514')
  await pg.query(`select terms_version, withdrawal_waiver_version, withdrawal_waiver_at from creator_subscriptions`)
})

// ---------------------------------------------------------------------------- notices

Deno.test('agreement_notices: claim/record per document type (same user + version, two types)', async () => {
  const pg = await migrated()
  const u = await user(pg, 'n@getinsyts.test')
  const claim = (type?: string) =>
    pg.query<{ id: string }>(
      type
        ? `select public.agreement_notices_claim('v1.0', array[$1::uuid], $2) id`
        : `select public.agreement_notices_claim('v1.0', array[$1::uuid]) id`,
      type ? [u, type] : [u],
    )
  assertEquals((await claim()).rows.length, 1) // default = insyter_agreement (today's call shape)
  assertEquals((await claim('privacy')).rows.length, 1)
  assertEquals((await claim('privacy')).rows.length, 0) // live 'sending' → not claimed again
  await pg.query(`select public.agreement_notices_record($1, 'v1.0', 'sent', null, 'privacy')`, [u])
  assertEquals((await pg.query(`select document_type, status from agreement_notices order by document_type`)).rows, [
    { document_type: 'insyter_agreement', status: 'sending' },
    { document_type: 'privacy', status: 'sent' },
  ])
})

// ---------------------------------------------------------------------------- proposals

Deno.test('submit_inquiry_proposal: stamps agreement_version + proposal ledger row; stale version → terms_changed', async () => {
  const pg = await migrated()
  const requester = await user(pg, 'req@getinsyts.test')
  const ins = await user(pg, 'ins@getinsyts.test')
  const inq = (await one<{ id: string }>(pg,
    `insert into inquiries (requester_auth_user_id, insyts_wanted) values ($1, 3) returning id`, [requester])).id
  const submit = (version: string | null) =>
    pg.query<{ r: { result: string; proposal: { id: string; agreement_version: string } } }>(
      `select public.submit_inquiry_proposal($1, $2, 'abs', '<p>o</p>', 3, 500, current_date + 7, 5, null, '203.0.113.8', 'UA', $3) r`,
      [inq, ins, version],
    )
  const ok = (await submit('v1.0')).rows[0].r
  assertEquals(ok.result, 'ok')
  assertEquals(ok.proposal.agreement_version, 'v1.0')
  assertEquals(await one(pg,
    `select document_type, version, context, reference_id, email, host(ip) ip, sha256 from terms_acceptances where context = 'proposal'`), {
    document_type: 'insyter_agreement', version: 'v1.0', context: 'proposal', reference_id: ok.proposal.id,
    email: 'ins@getinsyts.test', ip: '203.0.113.8', sha256: V10_SHA,
  })
  assertEquals(await msg(submit('v0.9')), 'terms_changed')
  // today's server (no p_agreement_version, 8 named args) still works
  const legacy = (await one<{ r: { result: string } }>(pg,
    `select public.submit_inquiry_proposal(p_inquiry_id => $1, p_insyter => $2, p_abstract => 'a', p_outline_html => 'o',
       p_read_time_min => 1, p_price_cents => 100, p_deliver_by => current_date, p_daily_cap => 5) r`, [inq, ins])).r
  assertEquals(legacy.result, 'ok')
  assertEquals((await one<{ n: number }>(pg, `select count(*)::int n from inquiry_proposals`)).n, 2)
  assertEquals((await one<{ n: number }>(pg, `select count(*)::int n from terms_acceptances where context = 'proposal'`)).n, 2)
})

// ---------------------------------------------------------------------------- backfill + storage

Deno.test('backfill: every legacy acceptance gets a become_insyter twin; malformed ip → null (AC2.6)', async () => {
  const u1 = crypto.randomUUID()
  const u2 = crypto.randomUUID()
  const pg = await throughB(`
    insert into agreement_acceptances (auth_user_id, email, signature_name, version, ip, accepted_at) values
      ('${u1}', 'a@x', 'A', 'v1.0', '203.0.113.1', '2026-06-01T00:00:00Z'),
      ('${u2}', 'b@x', 'B', 'v1.0', 'unknown, 10.0.0.1', '2026-06-02T00:00:00Z');`)
  assertEquals((await pg.query(
    `select auth_user_id, email, signature_name, version, sha256, context, host(ip) ip from terms_acceptances order by accepted_at`)).rows, [
    { auth_user_id: u1, email: 'a@x', signature_name: 'A', version: 'v1.0', sha256: V10_SHA, context: 'become_insyter', ip: '203.0.113.1' },
    { auth_user_id: u2, email: 'b@x', signature_name: 'B', version: 'v1.0', sha256: V10_SHA, context: 'become_insyter', ip: null },
  ])
})

Deno.test('storage: public legal-documents bucket with a read-only policy', async () => {
  const pg = await migrated()
  assertEquals((await pg.query(`select id, public from storage.buckets`)).rows, [{ id: 'legal-documents', public: true }])
  assertEquals((await pg.query(`select policyname, cmd from pg_policies where schemaname = 'storage'`)).rows, [
    { policyname: 'legal-documents public read', cmd: 'SELECT' },
  ])
})

// ---------------------------------------------------------------------------- GET-486 A1: legacy table dropped

Deno.test('A1: table + helper gone; both RPCs ledger-only and still service_role-only (AC2.3)', async () => {
  const pg = await migrated()
  assertEquals(await tableExists(pg, 'public.agreement_acceptances'), false)
  assertEquals((await one<{ n: number }>(pg, `select count(*)::int n from pg_proc where proname = 'get470_safe_inet'`)).n, 0)
  assertEquals((await one<{ n: number }>(pg,
    `select count(*)::int n from pg_proc where prosrc ilike '%agreement_acceptances%'`)).n, 0)
  for (const fn of ['record_insyter_acceptance(uuid, text, text, text, text, text)', 'anonymise_terms_acceptances(uuid)']) {
    assertEquals(await one(pg, `select has_function_privilege('authenticated', 'public.${fn}', 'execute') a,
                                       has_function_privilege('anon', 'public.${fn}', 'execute') b,
                                       has_function_privilege('service_role', 'public.${fn}', 'execute') s`), { a: false, b: false, s: true }, fn)
  }
})

Deno.test('A1 guard: a legacy row without its ledger twin → raises, nothing dropped (AC2.2, AC2.3)', async () => {
  for (const seed of [
    // no twin at all (written behind the RPC's back after the backfill)
    `insert into agreement_acceptances (auth_user_id, email, signature_name, version, accepted_at)
       values (gen_random_uuid(), 'x@y', 'X', 'v1.0', '2026-07-01T00:00:00Z')`,
    // twin exists but the names differ
    `with a as (insert into agreement_acceptances (auth_user_id, email, signature_name, version, accepted_at)
                values (gen_random_uuid(), 'x@y', 'Legacy Name', 'v1.0', '2026-07-02T00:00:00Z') returning *)
     insert into terms_acceptances (auth_user_id, email, signature_name, document_type, version, sha256, context, accepted_at)
       select auth_user_id, email, 'Other Name', 'insyter_agreement', 'v1.0', '${V10_SHA}', 'become_insyter', accepted_at from a`,
    // legacy tokenised but the twin was never anonymised
    `with a as (insert into agreement_acceptances (auth_user_id, email, signature_name, version, accepted_at)
                values (gen_random_uuid(), 'deleted-user', 'deleted-user', 'v1.0', '2026-07-03T00:00:00Z') returning *)
     insert into terms_acceptances (auth_user_id, email, signature_name, document_type, version, sha256, context, accepted_at)
       select auth_user_id, 'x@y', 'Name', 'insyter_agreement', 'v1.0', '${V10_SHA}', 'become_insyter', accepted_at from a`,
  ]) {
    const pg = await throughB()
    await pg.exec(seed)
    const m = await msg(pg.exec(DROP_LEGACY))
    assert(m.includes('have no ledger twin'), m)
    await pg.exec('rollback')
    assertEquals(await tableExists(pg, 'public.agreement_acceptances'), true)
    assertEquals((await one<{ n: number }>(pg, `select count(*)::int n from pg_proc where proname = 'get470_safe_inet'`)).n, 1)
    assertEquals((await one<{ n: number }>(pg,
      `select count(*)::int n from pg_proc where proname = 'record_insyter_acceptance' and prosrc ilike '%agreement_acceptances%'`)).n, 1)
  }
})

Deno.test('A1: backfilled twin of a user deleted before GET-470 is anonymised by the migration', async () => {
  const ghost = crypto.randomUUID() // never in auth.users: deleted before the delete trigger existed
  let stay = ''
  const pg = await migrated(
    `insert into agreement_acceptances (auth_user_id, email, signature_name, version, ip, accepted_at)
       values ('${ghost}', 'ghost@x', 'Ghost', 'v1.0', '203.0.113.9', '2026-06-01T00:00:00Z');`,
    async (db) => {
      assertEquals((await one<{ e: string }>(db, `select email e from terms_acceptances where auth_user_id = $1`, [ghost])).e, 'ghost@x')
      stay = await user(db, 'stay@getinsyts.test')
      await db.query(`select public.record_insyter_acceptance($1, null, 'Stay', 'v1.0', '1.2.3.4', 'UA')`, [stay])
    },
  )
  assertEquals(await one(pg, `select email, signature_name, ip, user_agent, anonymised_at is not null a from terms_acceptances where auth_user_id = $1`, [ghost]), {
    email: null, signature_name: null, ip: null, user_agent: null, a: true,
  })
  // a live user's row is untouched
  assertEquals(await one(pg, `select signature_name, anonymised_at from terms_acceptances where auth_user_id = $1`, [stay]), {
    signature_name: 'Stay', anonymised_at: null,
  })
})

Deno.test('A1: a user deleted under GET-470 (tokenised legacy ↔ anonymised twin) passes the guard', async () => {
  const pg = await migrated('', async (db) => {
    const u = await user(db, 'gone@getinsyts.test')
    await db.query(`select public.record_insyter_acceptance($1, null, 'Gone', 'v1.0', '1.2.3.4', 'UA')`, [u])
    await db.query(`delete from auth.users where id = $1`, [u])
    assertEquals((await one<{ s: string }>(db, `select signature_name s from agreement_acceptances where auth_user_id = $1`, [u])).s, 'deleted-user')
  })
  assertEquals(await tableExists(pg, 'public.agreement_acceptances'), false)
  assertEquals((await one<{ n: number }>(pg, `select count(*)::int n from terms_acceptances where anonymised_at is not null`)).n, 1)
})

Deno.test('A1 pre-check (prod-ops/get486-legacy-precheck.sql) agrees with the guard and only reads', async () => {
  const PRECHECK = await Deno.readTextFile(new URL('../prod-ops/get486-legacy-precheck.sql', import.meta.url))
  assert(!/\b(insert|update|delete|drop|alter|create|truncate|grant|revoke)\b/i.test(PRECHECK.replace(/--.*$/gm, '')), 'select-only')
  const pg = await throughB(`
    insert into agreement_acceptances (auth_user_id, email, signature_name, version, accepted_at)
      values ('${crypto.randomUUID()}', 'g@x', 'G', 'v1.0', '2026-06-01T00:00:00Z');`)
  type R = { legacy_rows: number; unmatched_legacy_rows: number; orphan_ledger_users: number; functions_reading_legacy: string[] }
  const clean = (await pg.query<R>(PRECHECK)).rows[0]
  assertEquals([Number(clean.legacy_rows), Number(clean.unmatched_legacy_rows), Number(clean.orphan_ledger_users)], [1, 0, 1])
  assertEquals(clean.functions_reading_legacy, ['public.anonymise_terms_acceptances', 'public.record_insyter_acceptance'])
  await pg.exec(`insert into agreement_acceptances (auth_user_id, email, signature_name, version) values (gen_random_uuid(), 'x@y', 'X', 'v1.0')`)
  assertEquals(Number((await pg.query<R>(PRECHECK)).rows[0].unmatched_legacy_rows), 1)
})
