-- GET-120 (Perf T5) — feed index matching the live anonymous /insyts query.
--
-- The feed query (src/feed.ts:473-482) is:
--   WHERE status IN ('live','published') AND is_hidden = false ORDER BY updated_at DESC
-- The existing partial index insyts_feed_created_at_idx is DOUBLY mismatched:
--   (a) it indexes created_at DESC, but the query orders by updated_at DESC (GET-73), and
--   (b) its predicate is status = 'live' only, not IN ('live','published').
-- So the planner can't use it and falls back to a seq-scan + sort as the table grows.
--
-- This adds a partial btree that exactly matches the query's always-present filters +
-- sort, so the common (no-facet) feed page is a bounded, backwards index scan instead
-- of scan-everything-then-sort. The sport/content_type facet filters stay as post-scan
-- filters; full-text search still uses insyts_search_vector_idx. Additive; no data change.
--
-- CONCURRENTLY so the build never locks writes on the live table. NOTE: CREATE INDEX
-- CONCURRENTLY must run OUTSIDE a transaction block — this migration therefore contains
-- exactly one statement and must not be wrapped in BEGIN/COMMIT.
--
-- Follow-up (not done here): the now-unused insyts_feed_created_at_idx (created_at DESC,
-- status='live') is a candidate for DROP once nothing else relies on it — left in place
-- for now to keep this change purely additive.
create index concurrently if not exists idx_insyts_feed_updated
  on public.insyts (updated_at desc)
  where status in ('live', 'published') and is_hidden = false;
