-- GET-277 — `published_at`: the feed's "newest" must mean newest-PUBLISHED.
--
-- `created_at` is DRAFT-creation time. Drafts are real `insyts` rows, so an insyt
-- drafted in March and published today sorts to its March slot and lands buried —
-- a variant of the complaint GET-73 tried to fix. No publish date was ever
-- recorded anywhere, so this adds the column, backfills it, and stamps it going
-- forward. See webflow-app-documentation/features/feed-sorting/design.md §3.7.
--
-- ⚠️ This SQL is not the obvious version. Every guard below is load-bearing and
-- was reproduced as a real defect in a throwaway Postgres before being fixed.
-- Read design.md §3.10.1–3.10.5 before editing it.

-- Record the server version in the deploy log (implementation.md gate 0c): the
-- CLI's cached .temp/postgres-version is unreliable — .temp/project-ref and
-- .temp/linked-project.json name DIFFERENT projects — so this is the only
-- trustworthy record of what we actually ran against.
do $$ begin raise notice 'GET-277 server_version=%', current_setting('server_version'); end $$;

-- 🚨 EXPLICIT TRANSACTION — load-bearing, do NOT remove (§3.10.4).
-- Our deploy path does NOT wrap a migration file in a transaction: migration
-- 20260704173726 runs CREATE INDEX CONCURRENTLY and is applied on staging, which
-- is impossible inside one. Without this BEGIN, two things break:
--   (a) every `set local` below silently does nothing (Postgres only warns), and
--   (b) an abort between the disable and enable in step 3 would leave
--       touch_insyts_updated_at DISABLED on a live table — GET-73 would stop
--       working with nothing to announce it.
-- Same pattern as 20260629203936 and four other migrations in this repo.
begin;

set local lock_timeout     = '3s';    -- bound the WAIT to acquire the lock
set local statement_timeout = '30s';  -- bound any ONE statement (clean ERROR)

-- transaction_timeout bounds the WHOLE transaction (incl. idle), closing the
-- `30s x N statements` window statement_timeout alone leaves open. It is PG17+,
-- and `set local transaction_timeout` is a hard ERROR on PG15. Written as a
-- conditional set_config so the migration adapts instead of depending on the
-- unreliable cached version: when the WHERE is false the function is never
-- CALLED, so an older server never sees the unknown parameter.
-- Verified on real PG 15.14 (0 rows, no error) and PG 17.11 (applies, reverts
-- at commit).
select set_config('transaction_timeout', '60s', true)
 where current_setting('server_version_num')::int >= 170000;

-- 1. the column  (this ALTER is what takes ACCESS EXCLUSIVE — unavoidably)
alter table public.insyts add column if not exists published_at timestamptz;

-- 2. 🚨 THE GRANT. public.insyts has COLUMN-level grants since GET-116, and a
--    new column is NOT covered by the existing list. GET-190 shipped exactly
--    this outage: every query referencing the column failed 42501.
grant select (published_at) on public.insyts to anon, authenticated;

-- 3. the backfill. TWO guards, both reproduced as real defects without them:
--
--    (a) SCOPE TO live/published. An unscoped backfill also stamps every DRAFT
--        with its draft-creation date — and the trigger in step 4 is guarded on
--        `new.published_at is null`, which would then be false FOREVER. Every
--        insyt currently in draft would publish with its draft date and land
--        buried: precisely the bug this ticket exists to fix, applied to the
--        entire existing draft inventory.
--
--    (b) DISABLE GET-73's touch trigger around it. touch_insyts_updated_at is an
--        unconditional `NEW.updated_at = now()` on EVERY update
--        (20260623130000:19), and now() is the TRANSACTION timestamp — so every
--        backfilled row would get the IDENTICAL updated_at. That DESTROYS THE
--        WEB FEED, which orders `updated_at DESC` with no tiebreaker
--        (webflow-code/src/feed.ts:662): the sort key becomes a single constant
--        and the order goes arbitrary and unstable between requests. It also
--        neuters GET-120's index and erases GET-73's feature. The old values are
--        recorded nowhere, so it is IRREVERSIBLE.
--        ⚠️ This ticket does not otherwise touch the web feed at all (AC-27).
--    Exactly ONE named trigger is suppressed — it is the only one that
--    misbehaves (§3.10.1). This adds NO new lock: the ADD COLUMN above already
--    holds ACCESS EXCLUSIVE. The explicit transaction is what guarantees the
--    trigger comes back if anything aborts.
alter table public.insyts disable trigger touch_insyts_updated_at;

update public.insyts
   set published_at = created_at
 where published_at is null
   and status in ('live', 'published');

alter table public.insyts enable trigger touch_insyts_updated_at;

-- 4. stamp the publish transition, for every writer. The status change happens
--    OUTSIDE the RN server (the n8n create pipeline / the web create flow), so
--    this must be a DB trigger — the same reasoning GET-73 used.
--    NOTE on INSERT: OLD is NULL there, and `old.status is distinct from
--    new.status` evaluates TRUE against a NULL record rather than erroring — so
--    a row inserted directly as 'live' IS stamped. Verified on PG 15/16/18.
create or replace function public.stamp_insyts_published_at()
  returns trigger
  language plpgsql
  set search_path = public          -- matches set_insyt_creator_display_name /
as $$                               -- insyts_report_count_sync; avoids the
begin                               -- function_search_path_mutable lint
  if new.published_at is null
     and new.status in ('live','published')
     and (old.status is distinct from new.status) then
    new.published_at = now();
  end if;
  return new;
end; $$;

drop trigger if exists stamp_insyts_published_at on public.insyts;
create trigger stamp_insyts_published_at
  before insert or update on public.insyts
  for each row execute function public.stamp_insyts_published_at();

commit;
