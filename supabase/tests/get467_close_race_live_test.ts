// GET-467 — the close-vs-claim race on the SHIPPED function, with two real Postgres
// connections against STAGING (PGlite has one connection; PostgREST can't hold a transaction).
//
//   1. Connection B: begin; claim proposal X (accepted → delivering); hold the transaction.
//   2. Connection A: select inquiry_close_by_requester(I, R). Steps 1–3 pass (B is uncommitted)
//      and A blocks on X's row lock in the step-4 `accepted` update.
//   3. B commits. A's update re-checks X under READ COMMITTED and skips it; step 5 sees the
//      committed `delivering` row and raises P0467.
//   4. The inquiry and every proposal are unchanged.
//
// Relies on no trigger on inquiry_proposals taking the inquiry lock (true today:
// inquiry_proposals_before_update only bumps version / updated_at).
//
// Skipped unless SUPABASE_DB_URL (the staging Postgres connection string) is set; refuses the
// prod ref. Load it from an env file, never inline it in a command:
//   deno test -A --env-file=<file with SUPABASE_DB_URL> supabase/tests/get467_close_race_live_test.ts
// Self-cleaning: the fixture rows are deleted in `finally`.
import { assertEquals } from 'jsr:@std/assert@1'
import postgres from 'npm:postgres@3.4.4'

const DB_URL = Deno.env.get('SUPABASE_DB_URL') ?? ''
const PROD_REF = 'krapqgxrqprtajatxjzd'
if (DB_URL.includes(PROD_REF)) throw new Error('refusing to run against production')

Deno.test({
  name: 'live: a delivery claimed during the close rolls the close back with P0467',
  ignore: !DB_URL,
  sanitizeOps: false,
  sanitizeResources: false,
  async fn() {
    const a = postgres(DB_URL, { max: 1, prepare: false })
    const b = postgres(DB_URL, { max: 1, prepare: false })
    let inquiryId: string | undefined
    try {
      // Fixture: an in_progress inquiry with one delivered and one accepted proposal, owned by
      // an existing staging team user (requester_auth_user_id references auth.users).
      const [user] = await a`select auth_user_id from public.users where email like '%@getinsyts.com' limit 1`
      if (!user) throw new Error('no @getinsyts.com user on staging to own the fixture')
      const req = user.auth_user_id as string
      const [inq] = await a`
        insert into public.inquiries
          (requester_auth_user_id, title, sport, price_min_cents, price_max_cents, status, insyts_wanted, access_mode)
        values (${req}, 'GET-467 race test', 'soccer', 1000, 1000, 'in_progress', 2, 'timed') returning id`
      inquiryId = inq.id as string
      const [x] = await a`
        insert into public.inquiry_proposals
          (inquiry_id, status, abstract, outline_html, read_time_min, price_cents, deliver_by, terms_accepted_at)
        values (${inquiryId}, 'accepted', 'race', '<p>race</p>', 5, 1000, current_date + 7, now()) returning id`
      await a`
        insert into public.inquiry_proposals
          (inquiry_id, status, abstract, outline_html, read_time_min, price_cents, deliver_by, terms_accepted_at)
        values (${inquiryId}, 'delivered', 'race', '<p>race</p>', 5, 1000, current_date + 7, now())`

      // 1. B claims and holds.
      const reserved = await b.reserve()
      await reserved`begin`
      await reserved`update public.inquiry_proposals set status = 'delivering', delivering_since = now() where id = ${x.id}`

      // 2. A closes; it blocks on X's row lock.
      const closing = a`select public.inquiry_close_by_requester(${inquiryId}, ${req}) as r`.then(
        () => 'ok',
        (e: { code?: string }) => e.code ?? 'error',
      )
      await new Promise((r) => setTimeout(r, 1500))

      // 3. B commits; A must abort with P0467.
      await reserved`commit`
      reserved.release()
      assertEquals(await closing, 'P0467')

      // 4. Nothing changed but B's own claim.
      const [after] = await a`select status, closed_by_requester_at from public.inquiries where id = ${inquiryId}`
      assertEquals(after.status, 'in_progress')
      assertEquals(after.closed_by_requester_at, null)
      const rows = await a`select status from public.inquiry_proposals where inquiry_id = ${inquiryId} order by status`
      assertEquals(rows.map((r) => r.status), ['delivered', 'delivering'])
    } finally {
      if (inquiryId) await a`delete from public.inquiries where id = ${inquiryId}`
      await a.end()
      await b.end()
    }
  },
})
