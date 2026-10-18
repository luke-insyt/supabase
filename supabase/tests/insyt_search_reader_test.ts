// GET-340 — the wall between Player search and paid insyt content, checked on a
// real Postgres (PGlite, in-process; no Docker, no network, no secrets).
//
// Runs the two GET-340 migrations against a minimal stand-in of the tables they
// touch, then asserts what the design promises (webflow-app-documentation
// features/social-search-insyts/requirements.md S1, S2-AC1, S7-AC2):
//   - insyt_search_reader can read NO table/view (insyts incl. title, users, eligible);
//   - anon / authenticated can't call match / by_ids (no USAGE, no EXECUTE);
//   - the functions return exactly the free-field allow-list, never a paid marker;
//   - only live/published, not hidden, public insyts with an insyt_id; deduped, newest wins;
//   - player phrase matches first (never the Insyter's name, never a prefix), request
//     terms after; tsquery operators in the input can't break or steer the query;
//   - the SECURITY DEFINER functions the reader may execute are exactly match + by_ids
//     (in this stand-in; the live list on staging is pinned in insyt_search_reader_live_test.ts);
//   - both migrations are idempotent; the area-save function keeps its old call shape;
//   - reviews accept target_kind 'insyt' (±1 only).
//
// Run (from the repo root):  deno test -A supabase/tests/insyt_search_reader_test.ts
// No local Deno?             npx -y deno@2.1.4 test -A supabase/tests/insyt_search_reader_test.ts
import { assert, assertEquals, assertRejects } from 'jsr:@std/assert@1'
import { PGlite } from 'npm:@electric-sql/pglite@0.2.17'

const MIGRATIONS = new URL('../migrations/', import.meta.url)
const readerMigration = await Deno.readTextFile(new URL('20261017210000_get340_insyt_search_reader.sql', MIGRATIONS))
const reviewsMigration = await Deno.readTextFile(new URL('20261018120000_get340_insyt_reviews.sql', MIGRATIONS))

const CREATOR = '11111111-1111-1111-1111-111111111111'
const MARKER = 'GET340_PAID'

// The columns the migrations read, in their staging types (remote_schema + later migrations).
const STAND_IN = `
create role anon; create role authenticated; create role service_role;
create table public.users (id uuid default gen_random_uuid(), auth_user_id uuid unique, profile_image_url varchar, email varchar);
create table public.insyts (
  id uuid default gen_random_uuid() not null, title varchar(150) not null, abstract text not null,
  content_type varchar, sport varchar default 'soccer', storage_path varchar, video_url varchar,
  thumbnail_url varchar, price_eur integer not null, creator_email varchar, insyt_id varchar,
  body_html text, video_storage_path varchar, tags text[], updated_at timestamptz default now(),
  is_hidden boolean default false, status varchar default 'review', published_at timestamptz,
  rating_avg numeric(3,2), rating_count int not null default 0, creator_auth_user_id uuid,
  creator_display_name varchar, visibility text not null default 'public');
create table public.insyt_attachments (id uuid default gen_random_uuid(), insyt_id uuid, storage_path text);
create table public.social_search_areas (id text primary key, name text not null unique, search_terms text[] not null,
  follow_up_instructions text not null default '', sort_order integer not null default 0, version integer not null default 1,
  updated_by text, updated_at timestamptz not null default now(), created_at timestamptz not null default now());
create table public.social_search_area_sources (area_id text, domain text, discovery boolean, lookup boolean, sort_order int);
create table public.social_search_area_questions (area_id text, id text, question text, options text[], sort_order int);
create table public.social_search_area_prompts (area_id text, key text, prompt text);
create table public.social_search_reviews (
  id uuid primary key default gen_random_uuid(), search_id uuid not null,
  target_kind text not null check (target_kind in ('search', 'player', 'fact')),
  target_id text not null, player_name text, rating smallint not null,
  constraint social_search_reviews_rating_scale check (
    (target_kind = 'search' and rating between 1 and 5) or (target_kind <> 'search' and rating in (-1, 1))));
insert into public.social_search_areas (id, name, search_terms) values ('soccer', 'Football (soccer)', '{footballer}');
-- the pre-GET-340 save signature the migration drops and replaces
create function public.social_search_save_area(p_id text, p_base_version integer, p_name text, p_search_terms text[],
  p_follow_up text, p_sources jsonb, p_questions jsonb, p_prompts jsonb, p_by text) returns integer language sql as 'select 1';
-- Supabase's default privileges on public: everything to the API roles
grant all on all tables in schema public to anon, authenticated;
`

const FIXTURES = `
insert into public.users (auth_user_id, profile_image_url, email) values ('${CREATOR}', 'avatars/per.png', 'secret@x.io');
insert into public.insyts (insyt_id, title, abstract, sport, price_eur, status, tags, published_at, creator_auth_user_id,
  creator_display_name, body_html, video_url, video_storage_path, storage_path, creator_email) values
 ('ok-player', 'Ola Hansen: Brann''s next winger', 'Scouting notes', 'Soccer', 900, 'live', '{eliteserien}', now() - interval '1 day', '${CREATOR}', 'Per Hansen',
   '${MARKER}_BODY', '${MARKER}_VIDEO', '${MARKER}_VSP', '${MARKER}_SP', '${MARKER}_EMAIL'),
 ('ok-request', 'The best young wingers in Norway', 'Pace and dribbling', 'soccer', 0, 'published', '{}', now() - interval '2 day', '${CREATOR}', 'Per Hansen', '${MARKER}_BODY', null, null, null, null),
 ('by-insyter-name', 'Set pieces explained', 'Corners', 'Soccer', 500, 'live', '{}', now(), '${CREATOR}', 'Ola Hansen', null, null, null, null, null),
 ('hidden', 'Ola Hansen hidden', 'x', 'Soccer', 500, 'live', '{}', now(), '${CREATOR}', 'P', null, null, null, null, null),
 ('private', 'Ola Hansen private', 'x', 'Soccer', 500, 'live', '{}', now(), '${CREATOR}', 'P', null, null, null, null, null),
 ('draft', 'Ola Hansen draft', 'x', 'Soccer', 500, 'review', '{}', now(), '${CREATOR}', 'P', null, null, null, null, null),
 (null, 'Ola Hansen no id', 'x', 'Soccer', 500, 'live', '{}', now(), '${CREATOR}', 'P', null, null, null, null, null),
 ('other-sport', 'Ola Hansen in handball', 'x', 'Handball', 500, 'live', '{}', now(), '${CREATOR}', 'P', null, null, null, null, null),
 ('dupe', 'Ola Hansen old', 'x', 'Soccer', 500, 'live', '{}', now() - interval '9 day', '${CREATOR}', 'P', null, null, null, null, null),
 ('dupe', 'Ola Hansen new', 'x', 'Soccer', 500, 'live', '{}', now() - interval '3 day', '${CREATOR}', 'P', null, null, null, null, null),
 ('olaf', 'Olaf Hansen at Molde', 'x', 'Soccer', 500, 'live', '{}', now(), '${CREATOR}', 'P', null, null, null, null, null);
update public.insyts set is_hidden = true where insyt_id = 'hidden';
update public.insyts set visibility = 'private' where insyt_id = 'private';
`

const MATCH_KEYS =
  'abstract,content_type,creator_avatar,creator_display_name,creator_id,insyt_id,matched_player,price_eur,published_at,rating_avg,rating_count,sport,tags,title'
const BY_IDS_KEYS =
  'content_type,creator_avatar,creator_display_name,creator_id,insyt_id,price_eur,published_at,rating_avg,rating_count,sport,tags,title'

async function db(): Promise<PGlite> {
  const pg = new PGlite()
  await pg.exec(STAND_IN)
  await pg.exec(readerMigration)
  await pg.exec(reviewsMigration)
  await pg.exec(FIXTURES)
  return pg
}

type Row = Record<string, unknown>
const asRole = async <T extends Row>(pg: PGlite, role: string, sql: string, params: unknown[] = []) => {
  await pg.exec(`set role ${role}`)
  try {
    return (await pg.query<T>(sql, params)).rows
  } finally {
    await pg.exec('reset role')
  }
}
const refused = (pg: PGlite, role: string, sql: string) =>
  assertRejects(() => asRole(pg, role, sql), Error, 'permission denied')

const match = (pg: PGlite, names: string[], terms: string[], sports = ['Soccer'], max = 40) =>
  asRole<Row>(pg, 'insyt_search_reader', 'select * from insyt_search.match($1::text[], $2::text[], $3::text[], $4::int)', [names, terms, sports, max])

Deno.test('S1-AC2: the reader can read no table or view — only the two functions', async () => {
  const pg = await db()
  await refused(pg, 'insyt_search_reader', 'select body_html from public.insyts')
  await refused(pg, 'insyt_search_reader', 'select title from public.insyts')
  await refused(pg, 'insyt_search_reader', 'select * from public.insyt_attachments')
  await refused(pg, 'insyt_search_reader', 'select email from public.users')
  await refused(pg, 'insyt_search_reader', 'select * from insyt_search.eligible')
  await pg.close()
})

Deno.test('S1-AC3: anon and authenticated can call neither function', async () => {
  const pg = await db()
  for (const role of ['anon', 'authenticated']) {
    await refused(pg, role, "select * from insyt_search.match(array['Ola Hansen'], null, array['Soccer'], 40)")
    await refused(pg, role, "select * from insyt_search.by_ids(array['ok-player'])")
  }
  await pg.close()
})

Deno.test('S1-AC4/AC6: exactly the free-field allow-list leaves, never a paid marker', async () => {
  const pg = await db()
  const m = await match(pg, ['Ola Hansen'], ['winger', 'Norway'])
  assert(m.length > 0)
  assertEquals(Object.keys(m[0]).sort().join(','), MATCH_KEYS)
  assert(!JSON.stringify(m).includes(MARKER), 'no body/video/storage/email marker in match')
  const b = await asRole<Row>(pg, 'insyt_search_reader', 'select * from insyt_search.by_ids($1::text[])', [['ok-player', 'ok-request']])
  assertEquals(Object.keys(b[0]).sort().join(','), BY_IDS_KEYS, 'by_ids has no abstract')
  assert(!JSON.stringify(b).includes(MARKER))
  await pg.close()
})

Deno.test('S1-AC5: only live/published, not hidden, public, with an insyt_id; deduped newest-first', async () => {
  const pg = await db()
  const ids = (await match(pg, ['Ola Hansen'], [])).map((r) => r.insyt_id)
  for (const gone of ['hidden', 'private', 'draft', 'other-sport']) assert(!ids.includes(gone), `${gone} must not match`)
  assertEquals(ids.filter((x) => x === 'dupe').length, 1)
  const dupe = (await match(pg, ['Ola Hansen'], [])).find((r) => r.insyt_id === 'dupe')
  assertEquals(dupe?.title, 'Ola Hansen new')
  const b = await asRole<Row>(pg, 'insyt_search_reader', 'select insyt_id from insyt_search.by_ids($1::text[])', [['ok-player', 'hidden', 'private', 'draft', 'nope']])
  assertEquals(b.map((r) => r.insyt_id), ['ok-player'], 'by_ids drops ineligible ids too')
  await pg.close()
})

Deno.test('S2-AC1: exact name phrase (never the Insyter, never a prefix), players first, request after, sport case-insensitive', async () => {
  const pg = await db()
  const m = await match(pg, ['Ola Hansen'], ['winger', 'Norway'])
  const ids = m.map((r) => r.insyt_id)
  assertEquals(m.find((r) => r.insyt_id === 'ok-player')?.matched_player, 'Ola Hansen')
  assertEquals(m.find((r) => r.insyt_id === 'ok-request')?.matched_player, null, "a request match (sport stored as 'soccer')")
  assert(!ids.includes('by-insyter-name'), "the Insyter's name is never searched")
  assert(!ids.includes('olaf'), "'Ola' is not a prefix of 'Olaf'")
  assert(ids.indexOf('ok-request') > ids.indexOf('ok-player'), 'player matches first')
  assertEquals((await match(pg, ['Ola Hansen'], ['winger'], ['Soccer'], 1)).length, 1, 'max caps the rows')
  assertEquals((await match(pg, [], [])).length, 0, 'no names, no terms → nothing')
  assertEquals((await match(pg, ['Ola Hansen'], [], ['Handball'])).map((r) => r.insyt_id), ['other-sport'], 'only the given sports')
  await pg.close()
})

Deno.test('S2-AC1: tsquery operators in names/terms neither error nor widen the match', async () => {
  const pg = await db()
  const m = await match(pg, ['Ola & !Hansen:*', "'); drop table x; --"], ["wing':* | 'x", '(', '!!', 'a'.repeat(200)])
  assert(Array.isArray(m))
  assert(!m.some((r) => r.insyt_id === 'olaf'), 'no prefix match smuggled in')
  await pg.close()
})

Deno.test('S1-AC2: the SECURITY DEFINER functions the reader may execute are exactly match + by_ids (stand-in)', async () => {
  const pg = await db()
  const { rows } = await pg.query<{ f: string }>(
    `select n.nspname || '.' || p.proname as f from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where p.prosecdef and has_function_privilege('insyt_search_reader', p.oid, 'EXECUTE')
        and n.nspname not in ('pg_catalog', 'information_schema') order by 1`,
  )
  assertEquals(rows.map((r) => r.f), ['insyt_search.by_ids', 'insyt_search.match'])
  await pg.close()
})

Deno.test('S7-AC2: area insyt_sports — soccer seeded, the old save call keeps the list, the new one sets it', async () => {
  const pg = await db()
  const sports = async () => (await pg.query<{ s: string[] }>("select insyt_sports as s from public.social_search_areas where id = 'soccer'")).rows[0].s
  assertEquals(await sports(), ['Soccer'])
  await pg.query(`select public.social_search_save_area('soccer', 1, 'Football (soccer)', '{footballer}', '', '[]', '[]', '{}', 'me')`)
  assertEquals(await sports(), ['Soccer'], 'a server from before GET-340 still saves, keeping the list')
  await pg.query(`select public.social_search_save_area('soccer', 2, 'Football (soccer)', '{footballer}', '', '[]', '[]', '{}', 'me', '{Soccer,Futsal}')`)
  assertEquals(await sports(), ['Soccer', 'Futsal'])
  await pg.close()
})

Deno.test("S4-AC2: reviews take target_kind 'insyt', rated ±1 only", async () => {
  const pg = await db()
  const search = crypto.randomUUID()
  await pg.query(`insert into public.social_search_reviews (search_id, target_kind, target_id, player_name, rating) values ($1, 'insyt', 'ok-player', 'Title', 1)`, [search])
  await assertRejects(() => pg.query(`insert into public.social_search_reviews (search_id, target_kind, target_id, rating) values ($1, 'insyt', 'x', 5)`, [search]))
  await assertRejects(() => pg.query(`insert into public.social_search_reviews (search_id, target_kind, target_id, rating) values ($1, 'nope', 'x', 1)`, [search]))
  await pg.close()
})

Deno.test('both migrations are idempotent (staging and prod apply them by hand)', async () => {
  const pg = await db()
  await pg.exec(readerMigration)
  await pg.exec(reviewsMigration)
  await refused(pg, 'insyt_search_reader', 'select title from public.insyts')
  assert((await match(pg, ['Ola Hansen'], [])).length > 0)
  await pg.close()
})
