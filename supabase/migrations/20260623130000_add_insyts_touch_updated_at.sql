-- GET-73: guarantee insyts.updated_at integrity for the last-updated feed sort.
--
-- The feed now orders by insyts.updated_at desc (src/feed.ts) so edited/republished
-- insyts resurface. updated_at already exists and is DEFAULT now() on INSERT, but it
-- only advanced on UPDATE when app code set it explicitly (save_draft, GET-71 edit).
-- This BEFORE UPDATE trigger forces NEW.updated_at = now() on EVERY update regardless
-- of caller, so the sort key is always current (AC-5b). Mirrors the proven pattern on
-- public.insyt_ratings (20260529173913_add_insyt_ratings.sql) and
-- public.creator_subscriptions (20260601120000_add_creator_subscriptions.sql).
--
-- Additive + idempotent: no schema change, no data change. The column DEFAULT now()
-- already guarantees non-null on create (AC-5a).

CREATE OR REPLACE FUNCTION public.touch_insyts_updated_at()
  RETURNS trigger
  LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS touch_insyts_updated_at ON public.insyts;
CREATE TRIGGER touch_insyts_updated_at
  BEFORE UPDATE ON public.insyts
  FOR EACH ROW
  EXECUTE FUNCTION public.touch_insyts_updated_at();
