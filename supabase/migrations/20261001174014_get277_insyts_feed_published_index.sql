-- GET-277 — the feed index for the new default sort.
--
-- Separate file BECAUSE of CONCURRENTLY: CREATE INDEX CONCURRENTLY cannot run
-- inside a transaction block, and the companion migration
-- (..._get277_insyts_published_at.sql) is explicitly wrapped in BEGIN/COMMIT.
-- One logical change, two files — see design.md §3.8.
--
-- ⚠️ `desc nulls last` is load-bearing. The query emits DESC NULLS LAST (the
-- client sets nullsFirst:false because published_at is nullable for drafts), but
-- a PLAIN `(published_at desc, id desc)` btree is NULLS FIRST — the orderings do
-- not match, so the planner IGNORES the index. Reproduced on 200k rows: Seq Scan.
create index concurrently if not exists idx_insyts_feed_published
  on public.insyts (published_at desc nulls last, id desc)
  where status in ('live', 'published') and is_hidden = false;
