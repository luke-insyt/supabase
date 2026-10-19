// GET-345 — area data sources migration, checked on a real Postgres (PGlite,
// in-process; no Docker, no network, no secrets).
//
// Runs the area migrations (GET-335, GET-340, GET-343) on the same minimal
// stand-in as search_enhancements_test.ts, then
// 20261019120000_get345_area_data_sources.sql, and asserts:
//   - save_area with p_data_sources stores the rows (scalar columns, array order);
//   - NULL keeps the stored rows, '[]' clears them, an array replaces them;
//   - the checks reject an unknown type, an unknown or empty role, a type twice,
//     > 50 leagues, a league > 80 chars, a bad period, a negative price, a
//     non-positive plan_requests / daily_cap — and a rejected save rolls back whole;
//   - rows go with their area (cascade);
//   - server-only: RLS on, no anon/authenticated grants, the function is
//     service_role only, exactly one overload, and the GET-343 call shapes still work;
//   - the migration is idempotent.
//
// Run (from the repo root):  deno test -A supabase/tests/area_data_sources_test.ts
// No local Deno?             npx -y deno@2.1.4 test -A --node-modules-dir=none supabase/tests/area_data_sources_test.ts
import { assert, assertEquals, assertRejects } from 'jsr:@std/assert@1'
import { PGlite } from 'npm:@electric-sql/pglite@0.2.17'

const MIGRATIONS = new URL('../migrations/', import.meta.url)
const read = (f: string) => Deno.readTextFile(new URL(f, MIGRATIONS))
const before = await Promise.all([
  read('20261016140000_social_search_areas.sql'),
  read('20261017210000_get340_insyt_search_reader.sql'),
  read('20261018120000_get340_insyt_reviews.sql'),
  read('20261018150000_get343_search_enhancements.sql'),
])
const migration = await read('20261019120000_get345_area_data_sources.sql')

// The columns the earlier migrations read, in their staging types.
const STAND_IN = `
create role anon; create role authenticated; create role service_role;
create table public.users (id uuid default gen_random_uuid(), auth_user_id uuid unique, profile_image_url varchar);
create table public.insyts (
  id uuid default gen_random_uuid() not null, title varchar(150) not null, abstract text not null,
  content_type varchar, sport varchar, price_eur integer not null, insyt_id varchar, tags text[],
  updated_at timestamptz default now(), is_hidden boolean default false, status varchar, published_at timestamptz,
  rating_avg numeric(3,2), rating_count int not null default 0, creator_auth_user_id uuid,
  creator_display_name varchar, visibility text not null default 'public');
create table public.social_searches (
  id uuid primary key, auth_user_id uuid, query text not null, created_at timestamptz not null default now());
create table public.social_search_reviews (
  id uuid primary key default gen_random_uuid(),
  search_id uuid not null references public.social_searches (id) on delete cascade,
  auth_user_id uuid, target_kind text not null check (target_kind in ('search', 'player', 'fact')),
  target_id text not null, player_name text, rating smallint not null, reason text,
  created_at timestamptz not null default now(),
  constraint social_search_reviews_rating_scale check (
    (target_kind = 'search' and rating between 1 and 5) or (target_kind <> 'search' and rating in (-1, 1))));
grant all on all tables in schema public to anon, authenticated;
`

const SAVE = `select public.social_search_save_area($1, $2, 'Football (soccer)', '{footballer}', '', '[]', '[]', '{}', 'admin', null, null, null, $3::jsonb) as v`

const WIKIDATA = { type: 'wikidata', roles: ['lookup'], leagues: [], priority: 0, enabled: true, dailyCap: null, planPriceUsd: 0, planRequests: null, planPeriod: 'month' }
const API_FOOTBALL = {
  type: 'api-football', roles: ['verify', 'discovery'], leagues: ['Oberliga Baden-Württemberg', '753'], priority: 10, enabled: false,
  dailyCap: 7500, planPriceUsd: 19, planRequests: 7500, planPeriod: 'day',
}

async function db(): Promise<PGlite> {
  const pg = new PGlite()
  await pg.exec(STAND_IN)
  for (const m of before) await pg.exec(m)
  await pg.exec(`insert into public.social_search_areas (id, name, search_terms, version) values ('soccer', 'Football (soccer)', '{footballer}', 3)`)
  await pg.exec(migration)
  return pg
}

async function one<T>(pg: PGlite, sql: string, params: unknown[] = []): Promise<T> {
  return (await pg.query<T>(sql, params)).rows[0]
}

const ROWS = `select type, roles, leagues, priority, enabled, daily_cap, plan_price_usd::float as price, plan_requests, plan_period, sort_order
  from public.social_search_area_data_sources where area_id = 'soccer' order by sort_order`
const version = async (pg: PGlite) => (await one<{ version: number }>(pg, `select version from public.social_search_areas where id = 'soccer'`)).version

Deno.test('save stores the data sources as scalar rows, in array order', async () => {
  const pg = await db()
  assertEquals((await one<{ v: number }>(pg, SAVE, ['soccer', 3, JSON.stringify([API_FOOTBALL, WIKIDATA])])).v, 4)
  assertEquals((await pg.query(ROWS)).rows, [
    { type: 'api-football', roles: ['verify', 'discovery'], leagues: ['Oberliga Baden-Württemberg', '753'], priority: 10, enabled: false,
      daily_cap: 7500, price: 19, plan_requests: 7500, plan_period: 'day', sort_order: 0 },
    { type: 'wikidata', roles: ['lookup'], leagues: [], priority: 0, enabled: true,
      daily_cap: null, price: 0, plan_requests: null, plan_period: 'month', sort_order: 1 },
  ])
  // no jsonb column anywhere on the table
  assertEquals((await one<{ n: number }>(pg,
    `select count(*)::int as n from information_schema.columns where table_name = 'social_search_area_data_sources' and data_type = 'jsonb'`)).n, 0)
})

Deno.test('NULL keeps the stored rows; [] clears them; an array replaces them', async () => {
  const pg = await db()
  await pg.query(SAVE, ['soccer', 3, JSON.stringify([WIKIDATA, API_FOOTBALL])])
  await pg.query(SAVE, ['soccer', 4, null])
  assertEquals((await pg.query<{ type: string }>(ROWS)).rows.map((r) => r.type), ['wikidata', 'api-football'])
  // the GET-343 12-arg shape (no p_data_sources) keeps them too
  await pg.query(`select public.social_search_save_area('soccer', 5, 'Football (soccer)', '{footballer}', '', '[]', '[]', '{}', 'admin', null, null, null)`)
  assertEquals((await pg.query(ROWS)).rows.length, 2)
  await pg.query(SAVE, ['soccer', 6, JSON.stringify([{ ...WIKIDATA, roles: ['verify'] }])])
  assertEquals((await pg.query<{ type: string; roles: string[] }>(ROWS)).rows.map((r) => [r.type, r.roles]), [['wikidata', ['verify']]])
  await pg.query(SAVE, ['soccer', 7, '[]'])
  assertEquals((await pg.query(ROWS)).rows.length, 0)
  assertEquals(await version(pg), 8)
})

Deno.test('a create carries its data sources on its first version', async () => {
  const pg = await db()
  await pg.query(`select public.social_search_save_area('hockey', 0, 'Ice hockey', '{player}', '', '[]', '[]', '{}', 'admin', null, null, null, $1::jsonb)`,
    [JSON.stringify([WIKIDATA])])
  assertEquals((await one<{ n: number }>(pg, `select count(*)::int as n from public.social_search_area_data_sources where area_id = 'hockey'`)).n, 1)
})

Deno.test('the checks reject bad rows, and a rejected save rolls back whole', async () => {
  const pg = await db()
  await pg.query(SAVE, ['soccer', 3, JSON.stringify([WIKIDATA])])
  const bad: [Record<string, unknown>[], string][] = [
    [[{ ...WIKIDATA, type: 'custom-rest' }], 'type_check'],
    [[{ ...WIKIDATA, roles: ['scrape'] }], 'roles_check'],
    [[{ ...WIKIDATA, roles: [] }], 'roles_check'],
    [[WIKIDATA, { ...WIKIDATA, priority: 5 }], 'pkey'],
    [[{ ...WIKIDATA, leagues: Array.from({ length: 51 }, (_, i) => `L${i}`) }], 'leagues_check'],
    [[{ ...WIKIDATA, leagues: ['ok', 'x'.repeat(81)] }], 'leagues_check'],
    [[{ ...WIKIDATA, priority: 101 }], 'priority_check'],
    [[{ ...WIKIDATA, dailyCap: 0 }], 'daily_cap_check'],
    [[{ ...WIKIDATA, planPriceUsd: -1 }], 'plan_price_usd_check'],
    [[{ ...WIKIDATA, planRequests: 0 }], 'plan_requests_check'],
    [[{ ...WIKIDATA, planPeriod: 'week' }], 'plan_period_check'],
  ]
  for (const [rows, constraint] of bad) {
    await assertRejects(() => pg.query(SAVE, ['soccer', 4, JSON.stringify(rows)]), Error, constraint)
  }
  // exactly 80 chars and 50 leagues are fine
  await pg.query(SAVE, ['soccer', 4, JSON.stringify([{ ...API_FOOTBALL, leagues: ['y'.repeat(80), ...Array.from({ length: 49 }, (_, i) => `L${i}`)] }])])
  assertEquals(await version(pg), 5)
  assertEquals((await pg.query<{ type: string }>(ROWS)).rows.map((r) => r.type), ['api-football'])
})

Deno.test('rows go with their area', async () => {
  const pg = await db()
  await pg.query(SAVE, ['soccer', 3, JSON.stringify([WIKIDATA])])
  await pg.exec(`delete from public.social_search_areas where id = 'soccer'`)
  assertEquals((await one<{ n: number }>(pg, `select count(*)::int as n from public.social_search_area_data_sources`)).n, 0)
})

Deno.test('server-only: RLS on, no API grants, function service_role only, one overload', async () => {
  const pg = await db()
  assert((await one<{ r: boolean }>(pg, `select relrowsecurity as r from pg_class where relname = 'social_search_area_data_sources'`)).r)
  assertEquals((await one<{ n: number }>(pg,
    `select count(*)::int as n from information_schema.role_table_grants
      where table_name = 'social_search_area_data_sources' and grantee in ('anon', 'authenticated')`)).n, 0)
  const fn = 'public.social_search_save_area(text, integer, text, text[], text, jsonb, jsonb, jsonb, text, text[], jsonb, jsonb, jsonb)'
  for (const role of ['anon', 'authenticated']) {
    assertEquals((await one<{ ok: boolean }>(pg, `select has_function_privilege('${role}', '${fn}', 'execute') as ok`)).ok, false, role)
  }
  assertEquals((await one<{ ok: boolean }>(pg, `select has_function_privilege('service_role', '${fn}', 'execute') as ok`)).ok, true)
  assertEquals((await one<{ n: number }>(pg, `select count(*)::int as n from pg_proc where proname = 'social_search_save_area'`)).n, 1)
  // the GET-340 9-arg call shape still resolves
  assertEquals((await one<{ v: number }>(pg,
    `select public.social_search_save_area('soccer', 3, 'Football (soccer)', '{footballer}', '', '[]', '[]', '{}', 'admin') as v`)).v, 4)
})

Deno.test('the migration is idempotent', async () => {
  const pg = await db()
  await pg.query(SAVE, ['soccer', 3, JSON.stringify([WIKIDATA])])
  await pg.exec(migration)
  await pg.exec(migration)
  assertEquals((await pg.query(ROWS)).rows.length, 1)
})
