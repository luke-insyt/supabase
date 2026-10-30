// GET-340 — the same wall, checked LIVE on a real project as the real reader role,
// through the Supavisor pooler. Skipped unless INSYT_SEARCH_DB_URL is set (it holds
// the reader's password: load it from an env file, never inline it in a command).
// Staging only; never point it at prod.
//
//   deno test -A --env-file=<path to getinsyts-native/server/.env> supabase/tests/insyt_search_reader_live_test.ts
//
// Re-run after any migration that touches insyts, users, storage or insyt_search, and
// before a release: PINNED below is the reviewed list of SECURITY DEFINER functions the
// reader can execute (via PUBLIC). A new one fails this test until someone has checked it
// returns nothing paid/internal and added it here
// (webflow-app-documentation features/social-search-insyts/implementation.md §4).
import { assert, assertEquals, assertRejects } from 'jsr:@std/assert@1'
import pg from 'npm:pg@8.13.1'

const URL_ = Deno.env.get('INSYT_SEARCH_DB_URL')
const ignore = !URL_
const PROD_REF = 'krapqgxrqprtajatxjzd'

const PINNED = [
  'insyt_search.by_ids',
  'insyt_search.match',
  // public, executable by PUBLIC (so by anon too); reviewed 2026-10-18 — nothing paid/internal,
  // caller-scoped ones key on auth.uid() (null for the reader); trigger functions excluded below.
  'public.creator_content_stats',
  'public.creator_revenue_stats',
  'public.creator_subscription_offer',
  'public.creator_subscription_offers',
  'public.creator_subscription_revenue',
  'public.creator_subscription_stats',
  'public.get_trending_insyts',
  'public.my_consumer_stats',
  'public.my_viewed_insyts',
  'public.refresh_creator_report_count',
  'public.refresh_follow_counts',
  'public.refresh_insyt_rating',
  'public.refresh_subscriber_count',
  'public.set_creator_expertise',
]

const MATCH_KEYS =
  'abstract,content_type,creator_avatar,creator_display_name,creator_id,insyt_id,matched_player,price_eur,published_at,rating_avg,rating_count,sport,tags,title'
const BY_IDS_KEYS =
  'content_type,creator_avatar,creator_display_name,creator_id,insyt_id,price_eur,published_at,rating_avg,rating_count,sport,tags,title'

async function withPool<T>(fn: (p: pg.Pool) => Promise<T>): Promise<T> {
  assert(!URL_!.includes(PROD_REF), 'staging only — this test must never run against prod')
  const pool = new pg.Pool({ connectionString: URL_, max: 1, connectionTimeoutMillis: 8000 })
  try {
    return await fn(pool)
  } finally {
    await pool.end()
  }
}

Deno.test({ name: 'live: connected as insyt_search_reader; every table, the view and storage refused', ignore, async fn() {
  await withPool(async (p) => {
    assertEquals((await p.query('select current_user as u')).rows[0].u, 'insyt_search_reader')
    for (const sql of [
      'select body_html from public.insyts limit 1',
      'select title from public.insyts limit 1',
      'select * from public.insyt_attachments limit 1',
      'select email from public.users limit 1',
      'select * from insyt_search.eligible limit 1',
      'select name from storage.objects limit 1',
    ]) await assertRejects(() => p.query(sql), Error, 'permission denied', sql)
  })
} })

Deno.test({ name: 'live: match / by_ids return exactly the allow-list, never a paid marker', ignore, async fn() {
  await withPool(async (p) => {
    // the get340-test fixtures (implementation.md §6) carry GET340_PAID_* in every paid field
    const m = (await p.query('select * from insyt_search.match($1::text[], $2::text[], $3::text[], 40)', [
      ['Jorrel Hato', 'Clinton Jephta'], ['winger', 'centre-back', 'Scandinavia'], ['Soccer'],
    ])).rows
    assert(m.length > 0, 'expected matches (are the get340-test fixtures on this project?)')
    assertEquals(Object.keys(m[0]).sort().join(','), MATCH_KEYS)
    assert(!JSON.stringify(m).includes('GET340_PAID'))
    const b = (await p.query('select * from insyt_search.by_ids($1::text[])', [m.slice(0, 5).map((r: { insyt_id: string }) => r.insyt_id)])).rows
    assertEquals(Object.keys(b[0]).sort().join(','), BY_IDS_KEYS)
    assert(!JSON.stringify(b).includes('GET340_PAID'))
  })
} })

Deno.test({ name: 'live: the SECURITY DEFINER functions the reader can execute are exactly the reviewed list', ignore, async fn() {
  await withPool(async (p) => {
    const { rows } = await p.query(
      `select n.nspname || '.' || p.proname as f from pg_proc p join pg_namespace n on n.oid = p.pronamespace
        where p.prosecdef and has_function_privilege('insyt_search_reader', p.oid, 'EXECUTE')
          and n.nspname not in ('pg_catalog', 'information_schema')
          and pg_get_function_result(p.oid) <> 'trigger' order by 1`,
    )
    const live = rows.map((r: { f: string }) => r.f)
    const unreviewed = live.filter((f: string) => !PINNED.includes(f))
    assertEquals(unreviewed, [], 'new definer function(s) the reader can execute — review, then pin')
    assert(live.includes('insyt_search.match') && live.includes('insyt_search.by_ids'))
  })
} })
