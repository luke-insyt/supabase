ALTER TABLE public.insyts
  ADD COLUMN IF NOT EXISTS read_time_min integer;

COMMENT ON COLUMN public.insyts.read_time_min IS
  'Estimated read time in minutes, computed from word count of abstract + body_html at upload time (200 wpm, ceiling, min 1).';
