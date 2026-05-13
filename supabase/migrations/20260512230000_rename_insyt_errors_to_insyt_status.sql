-- Generalize insyt_errors into insyt_status so the frontend can track
-- processing/success states alongside errors. Existing rows keep their
-- data and are backfilled as status='error'.

ALTER TABLE public.insyt_errors RENAME TO insyt_status;

ALTER TABLE public.insyt_status
  RENAME COLUMN error_message TO message;

ALTER TABLE public.insyt_status
  ADD COLUMN status text NOT NULL DEFAULT 'error';

-- Drop the default once existing rows are backfilled; new inserts must
-- pick an explicit status.
ALTER TABLE public.insyt_status
  ALTER COLUMN status DROP DEFAULT;

ALTER TABLE public.insyt_status
  ADD CONSTRAINT insyt_status_status_check
  CHECK (status IN ('processing', 'success', 'error'));

ALTER INDEX IF EXISTS idx_insyt_errors_correlation_id
  RENAME TO idx_insyt_status_correlation_id;

-- Composite index for "latest row per correlation_id" lookups.
CREATE INDEX IF NOT EXISTS idx_insyt_status_correlation_created
  ON public.insyt_status (correlation_id, created_at DESC);

ALTER POLICY "insyt_errors_select_all"
  ON public.insyt_status
  RENAME TO "insyt_status_select_all";
