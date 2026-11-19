// GET-373 — inquiry email invites migration, checked on a real Postgres (PGlite,
// in-process; no Docker, no network, no secrets).
//
// Runs 20261120090000_get373_inquiry_email_invites.sql on a minimal stand-in of the
// tables it touches (auth.users, inquiries, inquiry_targets + the GET-318 cap trigger),
// then asserts:
//   - add_inquiry_email_invites: inserts normalised rows; refuses non-owner, "all Insyters",
//     the requester's own address, live duplicates, a total over 10, a 24 h cap over 20;
//     a revoked address can be invited again;
//   - inquiry_targets_cap: counts picked targets + pending invites (DD2);
//   - claim_inquiry_email_invite: invited→joined + target row, never twice, never for the
//     requester, no duplicate target for an already-picked Insyter, and succeeds at total 10;
//   - deleting the requester's account deletes their invites (S5-AC5);
//   - server-only: RLS on, no anon/authenticated table grants, RPCs service_role only (S1-AC6).
// PGlite is one connection, so the row-lock serialisation itself is not exercised here;
// every write path takes the same `for update` on the inquiry row.
//
// Run (from the repo root):  deno test -A supabase/tests/inquiry_email_invites_test.ts
// No local Deno?             npx -y deno@2.1.4 test -A --node-modules-dir=none supabase/tests/inquiry_email_invites_test.ts
import { assert, assertEquals, assertRejects } from 'jsr:@std/assert@1'
import { PGlite } from 'npm:@electric-sql/pglite@0.2.17'

const migration = await Deno.readTextFile(
  new URL('../migrations/20261120090000_get373_inquiry_email_invites.sql', import.meta.url),
)

// The columns the migration reads, plus the GET-318 cap trigger it replaces.
const STAND_IN = `
create role anon; create role authenticated; create role service_role;
create schema auth;
create table auth.users (id uuid primary key default gen_random_uuid(), email text);
create table public.inquiries (
  id uuid primary key default gen_random_uuid(),
  requester_auth_user_id uuid references auth.users (id) on delete set null,
  status text not null default 'draft',
  audience text not null default 'all_insyters',
  moderated_at timestamptz);
create table public.inquiry_targets (
  inquiry_id uuid not null references public.inquiries (id) on delete cascade,
  creator_auth_user_id uuid not null references auth.users (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (inquiry_id, creator_auth_user_id));
create or replace function public.inquiry_targets_cap() returns trigger language plpgsql as $$
declare n integer;
begin
  perform 1 from public.inquiries where id = new.inquiry_id for update;
  select count(*) into n from public.inquiry_targets
   where inquiry_id = new.inquiry_id and creator_auth_user_id is distinct from new.creator_auth_user_id;
  if n >= 10 then raise exception 'an inquiry can target at most 10 Insyters' using errcode = 'check_violation'; end if;
  return new;
end; $$;
create trigger inquiry_targets_cap before insert or update of inquiry_id on public.inquiry_targets
  for each row execute function public.inquiry_targets_cap();
grant all on all tables in schema public to anon, authenticated;
-- Supabase's default privileges: every NEW table/function in public is granted to the API roles.
-- Without these the S1-AC6 revoke checks below could never fail.
alter default privileges in schema public grant all on tables to anon, authenticated;
alter default privileges in schema public grant execute on functions to anon, authenticated;
`

type Fixture = { pg: PGlite; requester: string; inquiry: string }

async function db(): Promise<Fixture> {
  const pg = new PGlite()
  await pg.exec(STAND_IN)
  await pg.exec(migration)
  const requester = await user(pg, 'Requester@Getinsyts.test')
  const inquiry = (await pg.query<{ id: string }>(
    `insert into public.inquiries (requester_auth_user_id, status, audience) values ($1, 'open', 'specific') returning id`,
    [requester],
  )).rows[0].id
  return { pg, requester, inquiry }
}

async function user(pg: PGlite, email: string): Promise<string> {
  return (await pg.query<{ id: string }>(`insert into auth.users (email) values ($1) returning id`, [email])).rows[0].id
}

async function add(f: Fixture, emails: string[], who = f.requester, inquiry = f.inquiry, now?: string) {
  return (await f.pg.query<{ r: Record<string, unknown> }>(
    now
      ? `select public.add_inquiry_email_invites($1, $2, $3::text[], $4::timestamptz) as r`
      : `select public.add_inquiry_email_invites($1, $2, $3::text[]) as r`,
    now ? [inquiry, who, emails, now] : [inquiry, who, emails],
  )).rows[0].r
}

async function claim(f: Fixture, invite: string, who: string) {
  return (await f.pg.query<{ r: { claimed: boolean } }>(
    `select public.claim_inquiry_email_invite($1, $2) as r`,
    [invite, who],
  )).rows[0].r
}

async function pick(f: Fixture, n: number): Promise<string[]> {
  const ids: string[] = []
  for (let i = 0; i < n; i++) {
    const id = await user(f.pg, `picked${i}@getinsyts.test`)
    await f.pg.query(`insert into public.inquiry_targets (inquiry_id, creator_auth_user_id) values ($1, $2)`, [f.inquiry, id])
    ids.push(id)
  }
  return ids
}

const count = async (pg: PGlite, sql: string, params: unknown[] = []) =>
  (await pg.query<{ n: number }>(sql, params)).rows[0].n

Deno.test('add stores trimmed, lower-cased, de-duplicated rows as invited', async () => {
  const f = await db()
  const r = await add(f, ['  Ana@Example.com ', 'ana@example.com', 'bo@example.com'])
  assertEquals(r.ok, true)
  const rows = (await f.pg.query<{ email: string; status: string; emailed_at: string | null }>(
    `select email, status, emailed_at from public.inquiry_email_invites order by email`,
  )).rows
  assertEquals(rows, [
    { email: 'ana@example.com', status: 'invited', emailed_at: null },
    { email: 'bo@example.com', status: 'invited', emailed_at: null },
  ])
})

Deno.test('add refuses a non-owner and an "all Insyters" inquiry with no rows written', async () => {
  const f = await db()
  const stranger = await user(f.pg, 'stranger@getinsyts.test')
  assertEquals((await add(f, ['x@example.com'], stranger)).refused, 'not_found')
  await f.pg.query(`update public.inquiries set audience = 'all_insyters' where id = $1`, [f.inquiry])
  assertEquals((await add(f, ['x@example.com'])).refused, 'audience')
  assertEquals(await count(f.pg, `select count(*)::int as n from public.inquiry_email_invites`), 0)
})

Deno.test("add refuses the requester's own address, whatever its case", async () => {
  const f = await db()
  assertEquals((await add(f, ['requester@getinsyts.test'])).refused, 'self')
})

Deno.test('add refuses a live duplicate; a revoked address can be invited again', async () => {
  const f = await db()
  await add(f, ['ana@example.com'])
  const dup = await add(f, ['ANA@example.com', 'new@example.com'])
  assertEquals(dup.refused, 'dupes')
  assertEquals(dup.dupes, ['ana@example.com'])
  await f.pg.query(`update public.inquiry_email_invites set status = 'revoked', revoked_at = now()`)
  assertEquals((await add(f, ['ana@example.com'])).ok, true)
})

Deno.test('add refuses when picked targets + pending invites would exceed 10', async () => {
  const f = await db()
  await pick(f, 8)
  assertEquals((await add(f, ['a@x.io', 'b@x.io'])).ok, true)
  assertEquals((await add(f, ['c@x.io'])).refused, 'total')
})

Deno.test('add refuses past 20 invites per requester per rolling 24 h, and reports the oldest', async () => {
  const f = await db()
  for (let i = 0; i < 2; i++) {
    const other = (await f.pg.query<{ id: string }>(
      `insert into public.inquiries (requester_auth_user_id, status, audience) values ($1, 'open', 'specific') returning id`,
      [f.requester],
    )).rows[0].id
    const ten = Array.from({ length: 10 }, (_, k) => `p${i}-${k}@x.io`)
    assertEquals((await add(f, ten, f.requester, other)).ok, true)
  }
  const r = await add(f, ['one-more@x.io'])
  assertEquals(r.refused, 'cap')
  assert(r.cap_oldest_at)
})

Deno.test('the cap trigger counts pending invites: a 10th picked target is refused with invitee_total', async () => {
  const f = await db()
  await pick(f, 7)
  await add(f, ['a@x.io', 'b@x.io', 'c@x.io'])
  const extra = await user(f.pg, 'extra@getinsyts.test')
  await assertRejects(
    () => f.pg.query(`insert into public.inquiry_targets (inquiry_id, creator_auth_user_id) values ($1, $2)`, [f.inquiry, extra]),
    Error,
    'invitee_total',
  )
})

Deno.test('claim flips invited→joined and adds the target; a second claim is a no-op', async () => {
  const f = await db()
  await add(f, ['ana@example.com'])
  const invite = (await f.pg.query<{ id: string }>(`select id from public.inquiry_email_invites`)).rows[0].id
  const ana = await user(f.pg, 'ana@example.com')
  assertEquals((await claim(f, invite, ana)).claimed, true)
  assertEquals((await claim(f, invite, ana)).claimed, false)
  const row = (await f.pg.query<{ status: string; claimed_by: string }>(
    `select status, claimed_by from public.inquiry_email_invites where id = $1`, [invite],
  )).rows[0]
  assertEquals(row, { status: 'joined', claimed_by: ana })
  assertEquals(await count(f.pg, `select count(*)::int as n from public.inquiry_targets where creator_auth_user_id = $1`, [ana]), 1)
})

Deno.test('claim by an already-picked Insyter joins without a second target row', async () => {
  const f = await db()
  const [picked] = await pick(f, 1)
  await add(f, ['picked0@getinsyts.test'])
  const invite = (await f.pg.query<{ id: string }>(`select id from public.inquiry_email_invites`)).rows[0].id
  assertEquals((await claim(f, invite, picked)).claimed, true)
  assertEquals(await count(f.pg, `select count(*)::int as n from public.inquiry_targets where inquiry_id = $1`, [f.inquiry]), 1)
})

Deno.test('the requester can never claim an invite on their own inquiry', async () => {
  const f = await db()
  await add(f, ['someone@x.io'])
  const invite = (await f.pg.query<{ id: string }>(`select id from public.inquiry_email_invites`)).rows[0].id
  assertEquals((await claim(f, invite, f.requester)).claimed, false)
  assertEquals(await count(f.pg, `select count(*)::int as n from public.inquiry_targets`), 0)
})

Deno.test('a claim at a total of 10 succeeds (it swaps a pending invite for a target)', async () => {
  const f = await db()
  await pick(f, 9)
  await add(f, ['last@x.io'])
  const invite = (await f.pg.query<{ id: string }>(`select id from public.inquiry_email_invites`)).rows[0].id
  const last = await user(f.pg, 'last@x.io')
  assertEquals((await claim(f, invite, last)).claimed, true)
  assertEquals(await count(f.pg, `select count(*)::int as n from public.inquiry_targets where inquiry_id = $1`, [f.inquiry]), 10)
})

Deno.test("deleting the requester's account deletes their invites", async () => {
  const f = await db()
  await add(f, ['a@x.io', 'b@x.io'])
  await f.pg.query(`delete from auth.users where id = $1`, [f.requester])
  assertEquals(await count(f.pg, `select count(*)::int as n from public.inquiry_email_invites`), 0)
})

Deno.test('server-only: RLS on, no browser-role grants, RPCs callable by service_role only', async () => {
  const f = await db()
  assertEquals((await f.pg.query<{ r: boolean }>(
    `select relrowsecurity as r from pg_class where relname = 'inquiry_email_invites'`,
  )).rows[0].r, true)
  assertEquals(await count(f.pg, `select count(*)::int as n from pg_policies where tablename = 'inquiry_email_invites'`), 0)
  for (const role of ['anon', 'authenticated']) {
    assertEquals((await f.pg.query<{ r: boolean }>(
      `select has_table_privilege($1, 'public.inquiry_email_invites', 'select') as r`, [role],
    )).rows[0].r, false)
    for (const fn of [
      'public.add_inquiry_email_invites(uuid, uuid, text[], timestamptz)',
      'public.claim_inquiry_email_invite(uuid, uuid)',
    ]) {
      assertEquals((await f.pg.query<{ r: boolean }>(
        `select has_function_privilege($1, $2, 'execute') as r`, [role, fn],
      )).rows[0].r, false)
    }
  }
  assertEquals((await f.pg.query<{ r: boolean }>(
    `select has_function_privilege('service_role', 'public.claim_inquiry_email_invite(uuid, uuid)', 'execute') as r`,
  )).rows[0].r, true)
})

Deno.test('add refuses empty input and a malformed address (tab, comma, double @)', async () => {
  const f = await db()
  assertEquals((await add(f, ['  ', ''])).refused, 'empty')
  assertEquals((await add(f, ['ok@x.io', 'a\tb@x.io'])).refused, 'malformed')
  assertEquals((await add(f, ['a,b@x.io'])).refused, 'malformed')
  assertEquals((await add(f, ['a@b@x.io'])).refused, 'malformed')
  assertEquals((await add(f, ['\tana@x.io\n'])).ok, true) // surrounding whitespace is trimmed
  assertEquals(await count(f.pg, `select count(*)::int as n from public.inquiry_email_invites where email = 'ana@x.io'`), 1)
})

Deno.test('a joined address is refused as a duplicate', async () => {
  const f = await db()
  await add(f, ['ana@example.com'])
  await f.pg.query(`update public.inquiry_email_invites set status = 'joined'`)
  assertEquals((await add(f, ['ana@example.com'])).refused, 'dupes')
})

Deno.test('the daily cap is a rolling 24 h window: older invites drop out, revoked ones still count', async () => {
  const f = await db()
  const old = new Date(Date.now() - 25 * 3600_000).toISOString()
  const recent = new Date(Date.now() - 3600_000).toISOString()
  for (let i = 0; i < 2; i++) {
    const other = (await f.pg.query<{ id: string }>(
      `insert into public.inquiries (requester_auth_user_id, status, audience) values ($1, 'open', 'specific') returning id`,
      [f.requester],
    )).rows[0].id
    const ten = Array.from({ length: 10 }, (_, k) => `w${i}-${k}@x.io`)
    assertEquals((await add(f, ten, f.requester, other, i === 0 ? old : recent)).ok, true)
  }
  // In the window: the 10 recent ones (revoked still count). The 10 older than 24 h don't,
  // so exactly 10 more fit (30 would be refused if the old ones counted) …
  await f.pg.query(`update public.inquiry_email_invites set status = 'revoked' where email like 'w1-%'`)
  const ten = Array.from({ length: 10 }, (_, k) => `n${k}@x.io`)
  assertEquals((await add(f, ten)).ok, true)
  // … and the 21st in the window is refused, on yet another inquiry.
  const fresh = (await f.pg.query<{ id: string }>(
    `insert into public.inquiries (requester_auth_user_id, status, audience) values ($1, 'open', 'specific') returning id`,
    [f.requester],
  )).rows[0].id
  assertEquals((await add(f, ['one-more@x.io'], f.requester, fresh)).refused, 'cap')
})

Deno.test('the redefined trigger still lets the no-op re-upsert of existing targets through at a total of 10', async () => {
  const f = await db()
  const ids = await pick(f, 10)
  for (const id of ids) {
    await f.pg.query(
      `insert into public.inquiry_targets (inquiry_id, creator_auth_user_id) values ($1, $2) on conflict do nothing`,
      [f.inquiry, id],
    )
  }
  assertEquals(await count(f.pg, `select count(*)::int as n from public.inquiry_targets`), 10)
})

Deno.test('claim refuses a null user and an inquiry that is completed, archived or taken down', async () => {
  const f = await db()
  await add(f, ['ana@example.com'])
  const invite = (await f.pg.query<{ id: string }>(`select id from public.inquiry_email_invites`)).rows[0].id
  const ana = await user(f.pg, 'ana@example.com')
  assertEquals((await f.pg.query<{ r: { claimed: boolean } }>(
    `select public.claim_inquiry_email_invite($1, null) as r`, [invite],
  )).rows[0].r.claimed, false)
  for (const sql of [
    `update public.inquiries set status = 'completed'`,
    `update public.inquiries set status = 'archived'`,
    `update public.inquiries set status = 'unpublished', moderated_at = now()`,
  ]) {
    await f.pg.query(sql)
    assertEquals((await claim(f, invite, ana)).claimed, false)
    await f.pg.query(`update public.inquiries set status = 'open', moderated_at = null`)
  }
  assertEquals((await claim(f, invite, ana)).claimed, true)
})
