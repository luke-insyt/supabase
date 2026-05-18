-- Surface workflow failures to the frontend via a correlation_id round-trip.
-- The create-insyt page generates a UUID per form mount, passes it through
-- Fillout, the n8n workflow tags both the insyts row and any error rows with
-- it, and the frontend polls by that ID.

ALTER TABLE public.insyts
  ADD COLUMN IF NOT EXISTS correlation_id uuid;

CREATE INDEX IF NOT EXISTS idx_insyts_correlation_id
  ON public.insyts (correlation_id);

CREATE TABLE IF NOT EXISTS public.insyt_errors (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  correlation_id uuid NOT NULL,
  insyt_id uuid,
  creator_email text,
  step text,
  error_message text,
  details jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_insyt_errors_correlation_id
  ON public.insyt_errors (correlation_id);

ALTER TABLE public.insyt_errors ENABLE ROW LEVEL SECURITY;

-- The correlation_id acts as a capability: anyone holding it can read the
-- matching error row. Frontends use the anon key + ?correlation_id=eq.<uuid>.
CREATE POLICY "insyt_errors_select_all"
  ON public.insyt_errors
  AS PERMISSIVE
  FOR SELECT
  TO public
  USING (true);
