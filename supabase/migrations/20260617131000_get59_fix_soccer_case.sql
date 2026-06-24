-- GET-59 follow-up: normalize any legacy 'soccer'/'football' casing to the
-- canonical 'Soccer'. The main retag migration (20260617130000) only matched the
-- exact label 'Football', but real data also carries lowercase 'soccer' (staging)
-- and could carry other case variants in prod — those would orphan against the
-- case-sensitive feed/insyters filters. Idempotent; safe on staging + prod.

UPDATE public.insyts
   SET sport = 'Soccer'
 WHERE lower(btrim(sport)) IN ('soccer', 'football')
   AND sport <> 'Soccer';

UPDATE public.users
   SET sports = (
     SELECT array_agg(DISTINCT v ORDER BY v)
       FROM (
         SELECT CASE
                  WHEN lower(btrim(s)) IN ('soccer', 'football') THEN 'Soccer'
                  ELSE s
                END AS v
           FROM unnest(sports) AS s
          WHERE s IS NOT NULL AND btrim(s) <> ''
       ) m
   )
 WHERE sports IS NOT NULL
   AND array_length(sports, 1) > 0
   AND EXISTS (
     SELECT 1 FROM unnest(sports) AS s
      WHERE lower(btrim(s)) IN ('soccer', 'football') AND s <> 'Soccer'
   );
