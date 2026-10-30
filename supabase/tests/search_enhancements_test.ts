// GET-343 — search_enhancements_v1 migration, checked on a real Postgres
// (PGlite, in-process; no Docker, no network, no secrets).
//
// Runs the real area migrations (GET-335 areas, GET-340 reader + reviews) and
// then 20261018151603_get343_search_enhancements.sql on a minimal stand-in of
// the other tables they touch (social_searches, social_search_reviews, users,
// insyts), and asserts (webflow-app-documentation
// features/social-search/search_enhancements_v1/requirements.md):
//   - SE11: existing duplicate votes collapse to the newest (id tie-break); a
//     second vote on the same target conflicts and upserts in place;
//   - SE9: a create's first save is public (1); an update adds a version and
//     leaves public_version; make_area_public accepts 1..version only;
//   - SE12: gates/targets default to the server's DEFAULT_GATES/DEFAULT_TARGETS,
//     save with null keeps them, a partial object changes only its keys, the
//     checks reject strong < good;
//   - SE14: the soccer benchmark seed copies the six queries in order, and only once;
//   - the functions are service_role only; the migration is idempotent.
//
// Run (from the repo root):  deno test -A supabase/tests/search_enhancements_test.ts
// No local Deno?             npx -y deno@2.1.4 test -A --node-modules-dir=none supabase/tests/search_enhancements_test.ts
//   (--node-modules-dir=none when a parent folder has a package.json/node_modules)
import { assert, assertEquals, assertRejects } from 'jsr:@std/assert@1'
import { PGlite } from 'npm:@electric-sql/pglite@0.2.17'

const MIGRATIONS = new URL('../migrations/', import.meta.url)
const read = (f: string) => Deno.readTextFile(new URL(f, MIGRATIONS))
const areasMigration = await read('20261016114519_social_search_areas.sql')
const readerMigration = await read('20261017220908_get340_insyt_search_reader.sql')
const reviewsMigration = await read('20261018114553_get340_insyt_reviews.sql')
const migration = await read('20261018151603_get343_search_enhancements.sql')

const USER = '11111111-1111-1111-1111-111111111111'
const SEARCH = '22222222-2222-2222-2222-222222222222'
const BENCH_IDS = [
  '62af224c-2454-46bd-862b-0ae0676b4d28',
  '71790dcd-c35b-4bb2-8ba4-21a93b70b402',
  'e9f21b19-ca7d-4b2b-8317-07ecd98f7e86',
  '19ca9818-a3aa-4514-bf85-2e6ed78dd36a',
  'e2e28a6f-208c-435f-9147-d7b881a41142',
  '35899f4c-1238-40c1-a349-eec2c63f5c77',
]

// The columns the migrations read, in their staging types.
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

// Duplicates as on staging (one voter re-rating a player): the newest wins, and
// two rows with the same created_at fall back to the larger id.
const FIXTURES = `
insert into public.social_searches (id, query) values ('${SEARCH}', 'a search');
insert into public.social_searches (id, query, created_at)
  select x.id::uuid, 'benchmark request ' || x.i, now() - (x.i || ' hours')::interval
    from unnest(array['${BENCH_IDS.join("','")}']) with ordinality as x (id, i);
insert into public.social_search_reviews (id, search_id, auth_user_id, target_kind, target_id, rating, reason, created_at) values
  ('00000000-0000-0000-0000-000000000001', '${SEARCH}', '${USER}', 'player', 'p1', -1, 'old',    now() - interval '2 hour'),
  ('00000000-0000-0000-0000-000000000002', '${SEARCH}', '${USER}', 'player', 'p1',  1, 'newest', now() - interval '1 hour'),
  ('00000000-0000-0000-0000-000000000003', '${SEARCH}', '${USER}', 'player', 'p2', -1, 'tie-a',  '2026-10-17 10:00+00'),
  ('00000000-0000-0000-0000-000000000004', '${SEARCH}', '${USER}', 'player', 'p2',  1, 'tie-b',  '2026-10-17 10:00+00'),
  ('00000000-0000-0000-0000-000000000005', '${SEARCH}', null,      'player', 'p1',  1, 'gone-a', now()),
  ('00000000-0000-0000-0000-000000000006', '${SEARCH}', null,      'player', 'p1',  1, 'gone-b', now());
`

const SAVE = `select public.social_search_save_area($1, $2, $3, '{term}', '', '[]', '[]', '{}', 'admin', null, $4::jsonb, $5::jsonb) as v`

async function db(): Promise<PGlite> {
  const pg = new PGlite()
  await pg.exec(STAND_IN)
  await pg.exec(areasMigration)
  await pg.exec(readerMigration)
  await pg.exec(reviewsMigration)
  await pg.exec(`insert into public.social_search_areas (id, name, search_terms, version) values ('soccer', 'Football (soccer)', '{footballer}', 3)`)
  await pg.exec(FIXTURES)
  await pg.exec(migration)
  return pg
}

async function one<T>(pg: PGlite, sql: string, params: unknown[] = []): Promise<T> {
  return (await pg.query<T>(sql, params)).rows[0]
}

Deno.test('SE11-AC3: duplicate votes collapse to the newest (id tie-break); null voters untouched', async () => {
  const pg = await db()
  const rows = (await pg.query<{ target_id: string; reason: string }>(
    `select target_id, reason from public.social_search_reviews where auth_user_id is not null order by target_id`,
  )).rows
  assertEquals(rows, [{ target_id: 'p1', reason: 'newest' }, { target_id: 'p2', reason: 'tie-b' }])
  assertEquals((await one<{ n: number }>(pg, `select count(*)::int as n from public.social_search_reviews where auth_user_id is null`)).n, 2)
  const u = await one<{ ok: boolean }>(pg, `select bool_and(updated_at = created_at) as ok from public.social_search_reviews`)
  assert(u.ok, 'updated_at backfilled from created_at')
})

Deno.test('SE11-AC2: a second vote on the same target conflicts; the upsert replaces it', async () => {
  const pg = await db()
  await assertRejects(
    () => pg.query(`insert into public.social_search_reviews (search_id, auth_user_id, target_kind, target_id, rating) values ($1, $2, 'player', 'p1', -1)`, [SEARCH, USER]),
    Error,
    'social_search_reviews_one_per_target',
  )
  await pg.query(
    `insert into public.social_search_reviews (search_id, auth_user_id, target_kind, target_id, rating, reason)
     values ($1, $2, 'player', 'p1', -1, 'changed')
     on conflict (search_id, auth_user_id, target_kind, target_id)
     do update set rating = excluded.rating, reason = excluded.reason, updated_at = now()`,
    [SEARCH, USER],
  )
  const r = await one<{ n: number; reason: string }>(pg,
    `select count(*)::int as n, max(reason) as reason from public.social_search_reviews where auth_user_id = $1 and target_id = 'p1'`, [USER])
  assertEquals(r, { n: 1, reason: 'changed' })
  // the same target in another kind is a different target
  await pg.query(`insert into public.social_search_reviews (search_id, auth_user_id, target_kind, target_id, rating) values ($1, $2, 'fact', 'p1', 1)`, [SEARCH, USER])
})

Deno.test('SE9-AC7: existing areas are public on their latest version', async () => {
  const pg = await db()
  assertEquals(await one(pg, `select version, public_version from public.social_search_areas where id = 'soccer'`), { version: 3, public_version: 3 })
})

Deno.test('SE9-AC1/AC2: create is public v1; an update adds a version and leaves public_version', async () => {
  const pg = await db()
  assertEquals((await one<{ v: number }>(pg, SAVE, ['hockey', 0, 'Ice hockey', null, null])).v, 1)
  assertEquals(await one(pg, `select version, public_version from public.social_search_areas where id = 'hockey'`), { version: 1, public_version: 1 })
  assertEquals((await one<{ v: number }>(pg, SAVE, ['hockey', 1, 'Ice hockey', null, null])).v, 2)
  assertEquals((await one<{ v: number }>(pg, SAVE, ['soccer', 3, 'Football (soccer)', null, null])).v, 4)
  assertEquals((await pg.query(`select id, version, public_version from public.social_search_areas order by id`)).rows, [
    { id: 'hockey', version: 2, public_version: 1 },
    { id: 'soccer', version: 4, public_version: 3 },
  ])
  // compare-and-set still holds; an existing id can't be created again
  assertEquals((await one<{ v: number | null }>(pg, SAVE, ['hockey', 1, 'Ice hockey', null, null])).v, null)
  assertEquals((await one<{ v: number | null }>(pg, SAVE, ['hockey', 0, 'Ice hockey', null, null])).v, null)
})

Deno.test('SE9-AC6: make_area_public takes 1..version only (rollback allowed)', async () => {
  const pg = await db()
  const mk = (id: string, v: number | null) =>
    one<{ v: number | null }>(pg, `select public.social_search_make_area_public($1, $2) as v`, [id, v])
  assertEquals((await mk('soccer', 1)).v, 1)
  assertEquals((await mk('soccer', 3)).v, 3)
  assertEquals((await mk('soccer', 0)).v, null)
  assertEquals((await mk('soccer', 4)).v, null)
  assertEquals((await mk('soccer', null)).v, null)
  assertEquals((await mk('nope', 1)).v, null)
  assertEquals(await one(pg, `select version, public_version from public.social_search_areas where id = 'soccer'`), { version: 3, public_version: 3 })
  await assertRejects(() => pg.query(`update public.social_search_areas set public_version = 4 where id = 'soccer'`), Error, 'public_version_check')
})

Deno.test('SE12: gates/targets default to the server defaults; null keeps, partial sets only its keys', async () => {
  const pg = await db()
  const COLS = `min_match, min_verified, min_hosts, strong_fit, good_fit, minutes_floor, season_calendar, max_web_queries,
    show_maybe, max_shown, target_freshness_pct::float as tf, target_coverage_pct::float as tc,
    target_league_accuracy_pct::float as tl, target_min_results, target_approval_pct::float as ta`
  const DEFAULTS = {
    min_match: 80, min_verified: 60, min_hosts: 2, strong_fit: 95, good_fit: 88, minutes_floor: 900,
    season_calendar: 'aug-may', max_web_queries: 40, show_maybe: true, max_shown: 20,
    tf: 90, tc: 80, tl: 100, target_min_results: 8, ta: 70,
  }
  assertEquals(await one(pg, `select ${COLS} from public.social_search_areas where id = 'soccer'`), DEFAULTS)
  await pg.query(SAVE, ['soccer', 3, 'Football (soccer)', JSON.stringify({ minutesFloor: 450, seasonCalendar: 'calendar', showMaybe: false }), JSON.stringify({ minResults: 5 })])
  const changed = { ...DEFAULTS, minutes_floor: 450, season_calendar: 'calendar', show_maybe: false, target_min_results: 5 }
  assertEquals(await one(pg, `select ${COLS} from public.social_search_areas where id = 'soccer'`), changed)
  await pg.query(SAVE, ['soccer', 4, 'Football (soccer)', null, null])
  assertEquals(await one(pg, `select ${COLS} from public.social_search_areas where id = 'soccer'`), changed)
  // a create with gates gets them on its first (public) version
  await pg.query(SAVE, ['hockey', 0, 'Ice hockey', JSON.stringify({ minMatch: 70 }), null])
  assertEquals((await one<{ min_match: number }>(pg, `select min_match from public.social_search_areas where id = 'hockey'`)).min_match, 70)
  // a bad value rolls the whole save back (version unchanged)
  await assertRejects(() => pg.query(SAVE, ['soccer', 5, 'Football (soccer)', JSON.stringify({ goodFit: 97 }), null]), Error, 'gates_check')
  await assertRejects(() => pg.query(SAVE, ['soccer', 5, 'Football (soccer)', JSON.stringify({ seasonCalendar: 'jan-jun' }), null]), Error, 'gates_check')
  await assertRejects(() => pg.query(SAVE, ['soccer', 5, 'Football (soccer)', null, JSON.stringify({ approvalPct: 101 })]), Error, 'targets_check')
  assertEquals((await one<{ version: number }>(pg, `select version from public.social_search_areas where id = 'soccer'`)).version, 5)
})

Deno.test('SE14-AC1: soccer benchmark seeded from the six searches, in order, once', async () => {
  const pg = await db()
  const rows = (await pg.query<{ request: string; sort_order: number }>(
    `select request, sort_order from public.social_search_area_benchmarks where area_id = 'soccer' order by sort_order`,
  )).rows
  assertEquals(rows.map((r) => r.request), [1, 2, 3, 4, 5, 6].map((i) => `benchmark request ${i}`))
  assertEquals(rows.map((r) => r.sort_order), [0, 1, 2, 3, 4, 5])
  await pg.exec(migration)
  assertEquals((await one<{ n: number }>(pg, `select count(*)::int as n from public.social_search_area_benchmarks`)).n, 6)
})

Deno.test('SE14: no soccer area / no source rows → the seed inserts nothing', async () => {
  const pg = new PGlite()
  await pg.exec(STAND_IN)
  await pg.exec(areasMigration)
  await pg.exec(readerMigration)
  await pg.exec(reviewsMigration)
  await pg.exec(migration)
  assertEquals((await one<{ n: number }>(pg, `select count(*)::int as n from public.social_search_area_benchmarks`)).n, 0)
})

Deno.test('SE13/SE14: search scorecard + benchmark columns, runs table checks', async () => {
  const pg = await db()
  const run = await one<{ id: string }>(pg,
    `insert into public.social_search_benchmark_runs (area_id, area_version, started_by, requests) values ('soccer', 2, 'admin', 6) returning id`)
  await pg.query(
    `update public.social_searches set area_id = 'soccer', area_version = 2, is_benchmark = true, benchmark_run_id = $1,
       freshness_pct = 87.5, coverage_pct = 100, league_accuracy_pct = null, maybe_count = 3, approval_pct = 66.7 where id = $2`,
    [run.id, SEARCH])
  await assertRejects(() => pg.query(`update public.social_searches set freshness_pct = 100.1 where id = $1`, [SEARCH]))
  await assertRejects(() => pg.query(`update public.social_search_benchmark_runs set done = 7 where id = $1`, [run.id]))
  await assertRejects(() => pg.query(`update public.social_search_benchmark_runs set status = 'queued' where id = $1`, [run.id]))
  assertEquals((await one<{ b: boolean }>(pg, `select is_benchmark as b from public.social_searches where id = $1`, [BENCH_IDS[0]])).b, false)
  await pg.query(`delete from public.social_search_benchmark_runs where id = $1`, [run.id])
  assertEquals((await one<{ r: string | null }>(pg, `select benchmark_run_id as r from public.social_searches where id = $1`, [SEARCH])).r, null)
})

Deno.test('server-only: RLS on, no API grants on new tables, functions service_role only', async () => {
  const pg = await db()
  const rls = (await pg.query<{ relname: string; relrowsecurity: boolean }>(
    `select relname, relrowsecurity from pg_class where relname in ('social_search_area_benchmarks', 'social_search_benchmark_runs') order by relname`,
  )).rows
  assertEquals(rls.map((r) => r.relrowsecurity), [true, true])
  const grants = await one<{ n: number }>(pg,
    `select count(*)::int as n from information_schema.role_table_grants
      where table_name in ('social_search_area_benchmarks', 'social_search_benchmark_runs') and grantee in ('anon', 'authenticated')`)
  assertEquals(grants.n, 0)
  for (const fn of [
    'public.social_search_save_area(text, integer, text, text[], text, jsonb, jsonb, jsonb, text, text[], jsonb, jsonb)',
    'public.social_search_make_area_public(text, integer)',
  ]) {
    for (const role of ['anon', 'authenticated']) {
      assertEquals((await one<{ ok: boolean }>(pg, `select has_function_privilege('${role}', '${fn}', 'execute') as ok`)).ok, false, `${role} ${fn}`)
    }
    assertEquals((await one<{ ok: boolean }>(pg, `select has_function_privilege('service_role', '${fn}', 'execute') as ok`)).ok, true, fn)
  }
  // exactly one save_area overload remains, and the GET-340 9-arg call shape still resolves
  assertEquals((await one<{ n: number }>(pg, `select count(*)::int as n from pg_proc where proname = 'social_search_save_area'`)).n, 1)
  assertEquals((await one<{ v: number }>(pg,
    `select public.social_search_save_area('soccer', 3, 'Football (soccer)', '{footballer}', '', '[]', '[]', '{}', 'admin') as v`)).v, 4)
})

Deno.test('the migration is idempotent', async () => {
  const pg = await db()
  await pg.exec(migration)
  await pg.exec(migration)
  assertEquals((await one<{ n: number }>(pg, `select count(*)::int as n from public.social_search_reviews`)).n, 4)
})
