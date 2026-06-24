-- GET-59 — PROD ONLY, one-off data wipe. Start the expertise vocabulary clean.
--
-- ⚠️ Run this on the PRODUCTION Supabase project ONLY (per the ticket — do NOT
-- run on staging). It is deliberately NOT a migration: migrations apply to every
-- environment, and we want staging's expertise data left intact.
--
-- Scope: deletes the DATA only. The FEATURE stays fully intact —
--   * tables public.expertise_tags + public.creator_expertise (kept, just emptied)
--   * RLS policies, the set_creator_expertise RPC, expertise_slugify()
--   * the become-insyter + creator-profile expertise widgets and the /insyters
--     expertise filter (all keep working; the vocabulary just starts empty and
--     re-populates organically as creators add tags again).
--
-- creator_search.expertise / expertise_slugs are computed by the VIEW from
-- creator_expertise, so emptying these two tables clears them everywhere — no
-- denormalized copy to reset.
--
-- Idempotent: safe to run if the tables are already empty (the ticket notes prod
-- may already have no expertise tags).
--
-- How to run: Supabase Dashboard (PROD project) → SQL Editor → paste → Run.
-- (Or psql against the prod connection string.)

BEGIN;

-- Links first (FK creator_expertise.tag_id -> expertise_tags.id), though the FK
-- is ON DELETE CASCADE so order is not strictly required.
DELETE FROM public.creator_expertise;
DELETE FROM public.expertise_tags;

COMMIT;

-- Verify (expect 0 / 0):
-- SELECT (SELECT count(*) FROM public.expertise_tags)    AS tags,
--        (SELECT count(*) FROM public.creator_expertise) AS links;
