-- GET-59: unify + retag the sport / content-type taxonomy for insyts AND insyters.
--
-- Frontend change (webflow-code src/lib/insyt-vocab.ts + insyt-taxonomy.ts) makes
-- both surfaces share ONE vocabulary:
--   * Sports: rename 'Football' -> 'Soccer'; Soccer/Volleyball/Basketball pinned
--     to the top of the dropdown (no data impact beyond the Football rename).
--   * Content types: collapse the two old divergent lists (insyt-side 16 + the
--     creator-side 9) into the new 7: Scouting & Recruitment, Performance &
--     Coaching, Health & Wellbeing, Tactics & Analysis, Business & Leadership,
--     Culture & Lifestyle, Other.
--
-- This migration remaps the STORED values so nothing orphans (the feed/insyters
-- filters match labels case-sensitively):
--   insyts.content_type (scalar) · insyts.sport (scalar)
--   users.content_types[] (array) · users.sports[] (array)
--
-- Idempotent: already-new values pass through unchanged, so it is safe to re-run.
-- NOTE: creator sports/content_types are mirrored to Webflow CMS by
-- sync-creator-to-webflow; that mirror is refreshed on the creator's next save
-- (or a manual re-sync) — the app itself reads these columns from Supabase.

-- ── Content-type mapping (covers BOTH old vocabularies + new pass-through) ──
CREATE OR REPLACE FUNCTION public.gi_get59_map_content_type(p text)
  RETURNS text
  LANGUAGE sql
  IMMUTABLE
AS $$
  SELECT CASE
    WHEN p IS NULL OR btrim(p) = '' THEN p
    -- already the new vocabulary
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
    -- 'Knowledge' + anything unrecognized
    ELSE 'Other'
  END
$$;

-- ── insyts (scalar columns) ──
UPDATE public.insyts
   SET content_type = public.gi_get59_map_content_type(content_type)
 WHERE content_type IS NOT NULL
   AND btrim(content_type) <> ''
   AND public.gi_get59_map_content_type(content_type) <> content_type;

UPDATE public.insyts
   SET sport = 'Soccer'
 WHERE sport = 'Football';

-- ── users (text[] columns) — remap each element, de-dupe, sort ──
UPDATE public.users
   SET content_types = (
     SELECT array_agg(DISTINCT v ORDER BY v)
       FROM (
         SELECT public.gi_get59_map_content_type(ct) AS v
           FROM unnest(content_types) AS ct
          WHERE ct IS NOT NULL AND btrim(ct) <> ''
       ) m
   )
 WHERE content_types IS NOT NULL AND array_length(content_types, 1) > 0;

UPDATE public.users
   SET sports = (
     SELECT array_agg(DISTINCT v ORDER BY v)
       FROM (
         SELECT CASE s
                  WHEN 'Football'      THEN 'Soccer'
                  WHEN 'Track & Field' THEN 'Athletics'
                  WHEN 'Generic'       THEN 'General'
                  ELSE s
                END AS v
           FROM unnest(sports) AS s
          WHERE s IS NOT NULL AND btrim(s) <> ''
       ) m
   )
 WHERE sports IS NOT NULL AND array_length(sports, 1) > 0;

DROP FUNCTION public.gi_get59_map_content_type(text);
