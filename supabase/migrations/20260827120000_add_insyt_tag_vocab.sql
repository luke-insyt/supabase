-- GET-190: shared vocabulary for insyt tags. insyts.tags stays the storage of record
-- (requirements D-1); this table is advisory — it powers autocomplete + the /insyts filter.
-- Mirrors expertise_tags (20260526163000) with three deliberate differences: no client INSERT
-- policy (AC-21), a folding slug rule (D-12), and a generated search_text column so a plain
-- client ilike can match the folded form without the browser ever slugging (D-4).

CREATE EXTENSION IF NOT EXISTS pg_trgm WITH SCHEMA extensions;

-- ── Slug helper ──────────────────────────────────────────────────────────────
-- MUST stay IMMUTABLE forever: the unique index, `slug` and `search_text` all depend on it,
-- so changing this body later needs a reindex + column rebuild.
-- Two traps encoded here on purpose:
--   1. translate() cannot expand 1 char into 2 — translate(x,'ß','ss') maps ß→s and DROPS the
--      second s. Every 1→2 fold therefore uses replace().
--   2. unaccent() is STABLE (it reads a text-search dictionary), so it can back neither a unique
--      index nor a generated column; marking a wrapper IMMUTABLE would risk index corruption if
--      the dictionary ever changed. Hence the explicit fold table below.
-- The from/to strings of translate() are 26 characters each. Keep them equal length.
CREATE OR REPLACE FUNCTION public.insyt_tag_slugify(p text)
  RETURNS text LANGUAGE sql IMMUTABLE PARALLEL SAFE
AS $fn$
  SELECT translate(
           replace(replace(replace(replace(replace(replace(replace(
             lower(regexp_replace(btrim(coalesce(p, '')), '\s+', ' ', 'g')),
             'ß', 'ss'), 'ä', 'ae'), 'ö', 'oe'), 'ü', 'ue'),
             'æ', 'ae'), 'ø', 'oe'), 'œ', 'oe'),
           'áàâãåéèêëíìîïóòôõúùûñçýÿšž',
           'aaaaaeeeeiiiioooouuuncyysz'
         )
$fn$;

COMMENT ON FUNCTION public.insyt_tag_slugify(text) IS
  'GET-190 normalization for insyt_tag_vocab: lower + collapse whitespace + German umlaut/ß '
  'expansion + diacritic folding. IMMUTABLE — backs a unique index and two generated columns. '
  'Deliberately NOT applied to expertise_tags (its rows are keyed by expertise_slugify).';

-- ── Vocabulary ───────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.insyt_tag_vocab (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  label       text NOT NULL,
  slug        text NOT NULL
                GENERATED ALWAYS AS (public.insyt_tag_slugify(label)) STORED,
  search_text text NOT NULL
                GENERATED ALWAYS AS (label || ' ' || public.insyt_tag_slugify(label)) STORED,
  created_by  uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  created_at  timestamptz NOT NULL DEFAULT now()
);

COMMENT ON COLUMN public.insyt_tag_vocab.search_text IS
  'label + folded slug in one column so the browser can ilike-match BOTH the display form and '
  'the folded form in a single read, without ever slugging client-side (requirements D-4). '
  'A generated column may not reference another, so this recomputes insyt_tag_slugify(label).';

CREATE UNIQUE INDEX IF NOT EXISTS insyt_tag_vocab_slug_key  ON public.insyt_tag_vocab (slug);
CREATE INDEX        IF NOT EXISTS insyt_tag_vocab_label_idx ON public.insyt_tag_vocab (label);
-- Note: a trigram GIN index cannot serve ilike '%xx%' for a 2-char query (fewer than 3
-- trigrams) — exactly AC-10's entry point. It starts helping at 3 chars; 2 chars is a seq scan
-- over a table with tens of rows. Kept because the vocabulary grows.
CREATE INDEX IF NOT EXISTS insyt_tag_vocab_trgm_idx ON public.insyt_tag_vocab
  USING GIN (search_text extensions.gin_trgm_ops);

ALTER TABLE public.insyt_tag_vocab ENABLE ROW LEVEL SECURITY;
-- Read is public (the /insyts filter is public). There is deliberately NO INSERT/UPDATE/DELETE
-- policy: browsers must never write the vocabulary (AC-21). Writes ride the insyt-save path via
-- resolve_insyt_tags() on the service key, which bypasses RLS.
DROP POLICY IF EXISTS "insyt_tag_vocab read" ON public.insyt_tag_vocab;
CREATE POLICY "insyt_tag_vocab read" ON public.insyt_tag_vocab
  FOR SELECT TO anon, authenticated USING (true);

-- ── Resolve-on-write RPC ─────────────────────────────────────────────────────
-- Returns canonical labels IN INPUT ORDER. Order matters: submit-create-insyt's isNoOpEdit
-- compares tags with an order-sensitive JSON.stringify (index.ts:521), so a resolver that
-- re-ordered would make every re-save look like a change and re-fire the n8n republish +
-- buyer notifications.
-- p_created_by: the edge fn / RN server passes the authoring user. auth.uid() is NULL under the
-- service key, so without this parameter created_by could never be populated and the column
-- requirements §8 asks for would be permanently dead.
CREATE OR REPLACE FUNCTION public.resolve_insyt_tags(p_labels text[], p_created_by uuid DEFAULT NULL)
  RETURNS text[] LANGUAGE plpgsql SET search_path = public
AS $fn$
DECLARE v_label text; v_slug text; v_canon text; v_out text[] := '{}'; v_seen text[] := '{}';
BEGIN
  IF coalesce(array_length(p_labels, 1), 0) > 8 THEN
    RAISE EXCEPTION 'too many tags (max 8)';
  END IF;
  FOREACH v_label IN ARRAY coalesce(p_labels, '{}') LOOP
    v_label := regexp_replace(btrim(v_label), '\s+', ' ', 'g');
    CONTINUE WHEN v_label = '';
    IF length(v_label) > 40 THEN
      RAISE EXCEPTION 'tag too long (max 40): %', v_label;
    END IF;
    -- , " \ { } corrupt either the comma-joined filter URL (feed-filters.ts:35) or the unquoted
    -- PostgREST array literal supabase-js builds for .overlaps (tags=ov.{a,b}).
    IF v_label ~ '[,"{}\\]' THEN
      RAISE EXCEPTION 'tag contains a reserved character (, " \ { }): %', v_label;
    END IF;
    v_slug := public.insyt_tag_slugify(v_label);
    CONTINUE WHEN v_slug = ANY (v_seen);
    v_seen := array_append(v_seen, v_slug);
    -- DO UPDATE, not DO NOTHING: with DO NOTHING a concurrent uncommitted insert of the same slug
    -- makes both the INSERT and a follow-up SELECT return nothing, and a NULL would be appended
    -- into insyts.tags — the storage of record.
    INSERT INTO public.insyt_tag_vocab (label, created_by)
      VALUES (v_label, p_created_by)
      ON CONFLICT (slug) DO UPDATE SET label = public.insyt_tag_vocab.label
      RETURNING label INTO v_canon;
    IF v_canon IS NULL THEN
      RAISE EXCEPTION 'could not resolve tag: %', v_label;
    END IF;
    v_out := array_append(v_out, v_canon);
  END LOOP;
  RETURN v_out;
END;
$fn$;

-- Supabase's project-wide ALTER DEFAULT PRIVILEGES (20260503161943_remote_schema.sql:537-538)
-- GRANTs ALL ON FUNCTIONS in schema public to anon + authenticated at creation time. Those are
-- EXPLICIT grants, so REVOKE ... FROM PUBLIC does not remove them — revoke by name.
-- service_role's EXECUTE already comes from :539's default privilege, so only the REVOKE is
-- load-bearing here; the GRANT is kept as an explicit statement of intent.
REVOKE ALL ON FUNCTION public.resolve_insyt_tags(text[], uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.resolve_insyt_tags(text[], uuid) TO service_role;
