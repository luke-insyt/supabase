-- ============================================================================
-- GET-59 — APPLY TO PROD (run ONCE in the PROD Supabase SQL Editor).
-- Project: krapqgxrqprtajatxjzd (production).
--
-- This is the consolidated, idempotent prod data application for GET-59:
--   (1) retag content types (16/9 old -> unified 7) + sport rename Football->Soccer
--   (2) normalize legacy lowercase 'soccer'/'football' casing -> 'Soccer'
--   (3) PROD-ONLY: wipe expertise_tags + creator_expertise DATA (keep the feature)
--
-- Mirrors the two committed migrations
--   migrations/20260617130000_get59_retag_taxonomy.sql
--   migrations/20260617131000_get59_fix_soccer_case.sql
-- run directly here because `supabase db push` would apply the ENTIRE
-- staging<->prod migration gap, not just GET-59. All statements are idempotent,
-- so re-running is harmless. Wrapped in one transaction.
-- ============================================================================

BEGIN;

-- ── (1a) content-type mapping (covers BOTH old vocabularies + new pass-through)
CREATE OR REPLACE FUNCTION public.gi_get59_map_content_type(p text)
  RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
    WHEN p IS NULL OR btrim(p) = '' THEN p
    WHEN p IN ('Business & Leadership','Culture & Lifestyle','Health & Wellbeing',
               'Performance & Coaching','Scouting & Recruitment','Tactics & Analysis',
               'Other') THEN p
    WHEN p IN ('Scouting','Scouting Report','Player Report') THEN 'Scouting & Recruitment'
    WHEN p IN ('Performance','Training','Drill Library','Training Session') THEN 'Performance & Coaching'
    WHEN p IN ('Health','Recovery','Mental') THEN 'Health & Wellbeing'
    WHEN p IN ('Analysis','Tactics','Match Analysis','Opponent Analysis',
               'Set Piece Analysis','Tactical Breakdown','Season Review') THEN 'Tactics & Analysis'
    WHEN p IN ('Business','Clubs') THEN 'Business & Leadership'
    WHEN p IN ('Lifestyle','Athletes','Interview','Journalism','Opinion') THEN 'Culture & Lifestyle'
    ELSE 'Other'  -- 'Knowledge' + anything unrecognized
  END
$$;

-- ── (1b) insyts (scalar columns)
UPDATE public.insyts
   SET content_type = public.gi_get59_map_content_type(content_type)
 WHERE content_type IS NOT NULL AND btrim(content_type) <> ''
   AND public.gi_get59_map_content_type(content_type) <> content_type;

UPDATE public.insyts SET sport = 'Soccer' WHERE sport = 'Football';

-- ── (1c) users (text[] columns) — remap each element, de-dupe, sort
UPDATE public.users
   SET content_types = (
     SELECT array_agg(DISTINCT v ORDER BY v) FROM (
       SELECT public.gi_get59_map_content_type(ct) AS v
         FROM unnest(content_types) AS ct WHERE ct IS NOT NULL AND btrim(ct) <> ''
     ) m
   )
 WHERE content_types IS NOT NULL AND array_length(content_types, 1) > 0;

UPDATE public.users
   SET sports = (
     SELECT array_agg(DISTINCT v ORDER BY v) FROM (
       SELECT CASE s
                WHEN 'Football'      THEN 'Soccer'
                WHEN 'Track & Field' THEN 'Athletics'
                WHEN 'Generic'       THEN 'General'
                ELSE s
              END AS v
         FROM unnest(sports) AS s WHERE s IS NOT NULL AND btrim(s) <> ''
     ) m
   )
 WHERE sports IS NOT NULL AND array_length(sports, 1) > 0;

DROP FUNCTION public.gi_get59_map_content_type(text);

-- ── (2) normalize legacy soccer/football casing -> 'Soccer'
UPDATE public.insyts
   SET sport = 'Soccer'
 WHERE lower(btrim(sport)) IN ('soccer','football') AND sport <> 'Soccer';

UPDATE public.users
   SET sports = (
     SELECT array_agg(DISTINCT v ORDER BY v) FROM (
       SELECT CASE WHEN lower(btrim(s)) IN ('soccer','football') THEN 'Soccer' ELSE s END AS v
         FROM unnest(sports) AS s WHERE s IS NOT NULL AND btrim(s) <> ''
     ) m
   )
 WHERE sports IS NOT NULL AND array_length(sports, 1) > 0
   AND EXISTS (SELECT 1 FROM unnest(sports) AS s
                WHERE lower(btrim(s)) IN ('soccer','football') AND s <> 'Soccer');

-- ── (3) PROD-ONLY expertise data wipe (keeps tables/feature/UI/RPC intact)
DELETE FROM public.creator_expertise;
DELETE FROM public.expertise_tags;

COMMIT;

-- Verify:
-- SELECT DISTINCT content_type FROM public.insyts ORDER BY 1;       -- expect the 7 (+null)
-- SELECT DISTINCT sport FROM public.insyts WHERE lower(sport)='soccer'; -- expect only 'Soccer'
-- SELECT count(*) FROM public.expertise_tags;                        -- expect 0
