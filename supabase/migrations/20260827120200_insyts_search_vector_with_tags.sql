-- GET-190 / AC-16: free-text feed search must also match an insyt's tags.
-- A generated column's expression cannot be ALTERed, so the column is dropped and re-added.
-- It stays GENERATED (not trigger-maintained): a BEFORE trigger would run before
-- set_insyt_creator_display_name and silently drop the B-weight creator name from every new row.

CREATE OR REPLACE FUNCTION public.gi_insyt_tags_search_text(p_tags text[])
  RETURNS text LANGUAGE sql IMMUTABLE PARALLEL SAFE
AS $fn$ SELECT lower(coalesce(array_to_string(p_tags, ' '), '')) $fn$;

COMMENT ON FUNCTION public.gi_insyt_tags_search_text(text[]) IS
  'GET-190: folds insyts.tags into searchable text for the generated search_vector. IMMUTABLE is '
  'accurate for a text[] signature (array_to_string is only marked STABLE because for a general '
  'element type the output function can be GUC-sensitive; text has no such dependency). Do NOT '
  'widen this to anyarray, and do NOT use this pattern for unaccent(), whose dictionary can change.';

DROP INDEX IF EXISTS public.insyts_search_vector_idx;
ALTER TABLE public.insyts DROP COLUMN IF EXISTS search_vector;
ALTER TABLE public.insyts
  ADD COLUMN search_vector tsvector
    GENERATED ALWAYS AS (
      setweight(to_tsvector('simple', coalesce(title, '')), 'A') ||
      setweight(to_tsvector('simple', coalesce(creator_display_name, '')), 'B') ||
      setweight(to_tsvector('simple', coalesce(abstract, '')), 'B') ||
      setweight(to_tsvector('simple', coalesce(sport, '')), 'C') ||
      setweight(to_tsvector('simple', coalesce(content_type, '')), 'C') ||
      setweight(to_tsvector('simple', public.gi_insyt_tags_search_text(tags)), 'C')
    ) STORED;

CREATE INDEX insyts_search_vector_idx ON public.insyts USING GIN (search_vector);

-- Dropping the column dropped its COMMENT (20260520120000:40-42) — re-add it.
COMMENT ON COLUMN public.insyts.search_vector IS
  'GIN-indexed tsvector for the /insyts feed search. Weights: A=title, '
  'B=creator_display_name+abstract, C=sport+content_type+tags.';
