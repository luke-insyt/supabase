// GET-486 B4 — insyt_reports + the order-proof deletion follow-up trigger (D-9), checked on a real
// Postgres in-process (PGlite: no Docker, no network, no secrets).
//
// Asserts (implementation.md B4 tests, feature.md §2.6–§2.7):
//   * check constraints (reason enum, note ≤ 1000, email ≤ 200, a reporter must be present,
//     resolution pairs);
//   * the two partial unique indexes: one open report per (Insyt, user) and per (Insyt, email,
//     case-insensitive); a resolved report frees the slot;
//   * anon/authenticated have no table privilege; the trigger fn is executable by nobody;
//   * D-9: deleting a reporter works with ONLY insyt_reports present (B2 not merged yet) and with
//     BOTH tables present (insyt_rules_confirmations stand-in) — reports keep the note, lose
//     id/email/IP, get reporter_deleted_at; confirmations lose IP/UA and get anonymised_at;
//   * the migration is idempotent (re-runs cleanly).
//
// Run (from the supabase repo root):
//   DENO_NO_PACKAGE_JSON=1 deno test -A supabase/tests/get486_insyt_reports_test.ts
//   no local Deno: DENO_NO_PACKAGE_JSON=1 npx -y deno@2.1.4 test -A supabase/tests/get486_insyt_reports_test.ts
import { assert, assertEquals, assertRejects } from 'jsr:@std/assert@1'
import { PGlite } from 'npm:@electric-sql/pglite@0.2.17'

const MIG = await Deno.readTextFile(new URL('../migrations/20261126170000_get486_insyt_reports.sql', import.meta.url))

const STAND_IN = `
create role anon; create role authenticated; create role service_role bypassrls;
create schema auth;
create table auth.users (id uuid primary key default gen_random_uuid(), email text);
alter default privileges in schema public grant all on tables to anon, authenticated, service_role;
alter default privileges in schema public grant execute on functions to anon, authenticated, service_role;
`

// B2's table, only the columns the follow-up trigger touches (+ its append-only rule, simplified:
// any update other than the anonymise path raises — so a second anonymise would roll back the delete).
const CONFIRMATIONS = `
create table public.insyt_rules_confirmations (
  id uuid primary key default gen_random_uuid(),
  auth_user_id uuid not null, ip inet, user_agent text, anonymised_at timestamptz);
create function public.rc_append_only() returns trigger language plpgsql as $$
begin
  if old.anonymised_at is not null then raise exception 'append-only'; end if;
  return new;
end $$;
create trigger rc_append_only before update on public.insyt_rules_confirmations
  for each row execute function public.rc_append_only();
`

async function db(withConfirmations: boolean): Promise<PGlite> {
  const pg = new PGlite()
  await pg.exec(STAND_IN)
  if (withConfirmations) await pg.exec(CONFIRMATIONS)
  await pg.exec(MIG)
  return pg
}

const U1 = '11111111-1111-1111-1111-111111111111'
const U2 = '22222222-2222-2222-2222-222222222222'

async function addUsers(pg: PGlite) {
  await pg.exec(`insert into auth.users (id, email) values ('${U1}', 'a@x.test'), ('${U2}', 'b@x.test')`)
}

Deno.test('check constraints', async () => {
  const pg = await db(false)
  const bad = [
    `insert into public.insyt_reports (insyt_id, reporter_email, reason) values ('s', 'a@x.test', 'spam')`,
    `insert into public.insyt_reports (insyt_id, reporter_email, reason, note) values ('s', 'a@x.test', 'other', repeat('x', 1001))`,
    `insert into public.insyt_reports (insyt_id, reporter_email, reason) values ('s', repeat('x', 201), 'other')`,
    `insert into public.insyt_reports (insyt_id, reason) values ('s', 'other')`,
    `insert into public.insyt_reports (insyt_id, reporter_email, reason, resolved_at) values ('s', 'a@x.test', 'other', now())`,
    `insert into public.insyt_reports (insyt_id, reporter_email, reason, resolved_at, resolution) values ('s', 'a@x.test', 'other', now(), 'no_action')`,
    `insert into public.insyt_reports (insyt_id, reporter_email, reason, resolved_at, resolution, resolution_reason) values ('s', 'a@x.test', 'other', now(), 'no_action', 'bogus')`,
    `insert into public.insyt_reports (insyt_id, reporter_email, reason, resolved_at, resolution, resolution_reason, resolution_note) values ('s', 'a@x.test', 'other', now(), 'no_action', 'duplicate', repeat('x', 501))`,
  ]
  for (const sql of bad) await assertRejects(() => pg.exec(sql), Error, undefined, sql)
  await pg.exec(`insert into public.insyt_reports (insyt_id, reporter_email, reason, note) values ('s', 'a@x.test', 'other', repeat('x', 1000))`)
  await pg.exec(`insert into public.insyt_reports (insyt_id, reporter_auth_user_id, reason, resolved_at, resolution, resolution_reason, resolution_note)
                 values ('s', '${U1}', 'minor', now(), 'taken_down', 'minor', 'ok')`)
})

Deno.test('one open report per (Insyt, user) and per (Insyt, email ci); resolving frees the slot', async () => {
  const pg = await db(false)
  await pg.exec(`insert into public.insyt_reports (insyt_id, reporter_auth_user_id, reason) values ('s', '${U1}', 'other')`)
  await assertRejects(() => pg.exec(`insert into public.insyt_reports (insyt_id, reporter_auth_user_id, reason) values ('s', '${U1}', 'copied')`))
  // another Insyt, another user: fine
  await pg.exec(`insert into public.insyt_reports (insyt_id, reporter_auth_user_id, reason) values ('t', '${U1}', 'other')`)
  await pg.exec(`insert into public.insyt_reports (insyt_id, reporter_auth_user_id, reason) values ('s', '${U2}', 'other')`)

  await pg.exec(`insert into public.insyt_reports (insyt_id, reporter_email, reason) values ('s', 'Anon@X.test', 'other')`)
  await assertRejects(() => pg.exec(`insert into public.insyt_reports (insyt_id, reporter_email, reason) values ('s', 'anon@x.TEST', 'other')`))

  await pg.exec(`update public.insyt_reports set resolved_at = now(), resolution = 'no_action', resolution_reason = 'not_a_violation' where insyt_id = 's'`)
  await pg.exec(`insert into public.insyt_reports (insyt_id, reporter_auth_user_id, reason) values ('s', '${U1}', 'copied')`)
  await pg.exec(`insert into public.insyt_reports (insyt_id, reporter_email, reason) values ('s', 'anon@x.test', 'other')`)
})

Deno.test('no client privileges; RLS on; trigger fn executable by nobody', async () => {
  const pg = await db(false)
  for (const role of ['anon', 'authenticated']) {
    const r = await pg.query<{ p: boolean }>(
      `select has_table_privilege('${role}', 'public.insyt_reports', 'select,insert,update,delete') as p`)
    assertEquals(r.rows[0].p, false, role)
  }
  const rls = await pg.query<{ r: boolean }>(`select relrowsecurity as r from pg_class where oid = 'public.insyt_reports'::regclass`)
  assertEquals(rls.rows[0].r, true)
  for (const role of ['anon', 'authenticated', 'service_role']) {
    const r = await pg.query<{ p: boolean }>(
      `select has_function_privilege('${role}', 'public.auth_user_deleted_anonymise_followup()', 'execute') as p`)
    assertEquals(r.rows[0].p, false, role)
  }
})

async function deletionCase(withConfirmations: boolean) {
  const pg = await db(withConfirmations)
  await addUsers(pg)
  await pg.exec(`insert into public.insyt_reports (insyt_id, reporter_auth_user_id, reporter_email, reporter_ip, reason, note)
                 values ('s', '${U1}', 'a@x.test', '203.0.113.1', 'copied', 'the notice'),
                        ('s', '${U2}', 'b@x.test', '203.0.113.2', 'other', 'keep me')`)
  if (withConfirmations) {
    await pg.exec(`insert into public.insyt_rules_confirmations (auth_user_id, ip, user_agent)
                   values ('${U1}', '203.0.113.1', 'UA'), ('${U2}', '203.0.113.2', 'UA')`)
  }
  await pg.exec(`delete from auth.users where id = '${U1}'`)

  const gone = await pg.query<Record<string, unknown>>(`select * from public.insyt_reports where note = 'the notice'`)
  assertEquals(gone.rows.length, 1, 'the report stays')
  const r = gone.rows[0]
  assertEquals(r.reporter_auth_user_id, null)
  assertEquals(r.reporter_email, null)
  assertEquals(r.reporter_ip, null)
  assert(r.reporter_deleted_at, 'reporter_deleted_at set')
  const kept = await pg.query<Record<string, unknown>>(`select * from public.insyt_reports where note = 'keep me'`)
  assertEquals(kept.rows[0].reporter_auth_user_id, U2, 'other reporter untouched')
  assertEquals(kept.rows[0].reporter_deleted_at, null)

  if (withConfirmations) {
    const c = await pg.query<Record<string, unknown>>(`select * from public.insyt_rules_confirmations where auth_user_id = '${U1}'`)
    assertEquals(c.rows[0].ip, null)
    assertEquals(c.rows[0].user_agent, null)
    assert(c.rows[0].anonymised_at)
    const o = await pg.query<Record<string, unknown>>(`select * from public.insyt_rules_confirmations where auth_user_id = '${U2}'`)
    assertEquals(o.rows[0].anonymised_at, null)
  }
  // the migration re-runs cleanly (same body, either order — D-9)
  await pg.exec(MIG)
  await pg.exec(`delete from auth.users where id = '${U2}'`)
}

Deno.test('D-9: deleting a reporter with only insyt_reports present', () => deletionCase(false))
Deno.test('D-9: deleting a reporter with insyt_rules_confirmations present too', () => deletionCase(true))

Deno.test('D-9: the trigger never touches a missing table (no insyt_reports either)', async () => {
  // A user delete still works if the function exists while a table is gone (order-proof guard).
  const pg = await db(false)
  await addUsers(pg)
  await pg.exec(`drop table public.insyt_reports`)
  await pg.exec(`delete from auth.users where id = '${U1}'`)
})
