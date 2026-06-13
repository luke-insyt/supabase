-- One-off backfill for the single image attachment that existed before the
-- width/height columns were added (see migration 20260512010000). Future image
-- uploads populate these via the n8n "Capture dimensions" node; the frontend
-- falls back to a thumb-derived ratio for any rows still missing.
UPDATE public.insyt_attachments
SET width = 2678, height = 1476
WHERE id = '4431499c-1b5f-4804-af12-1394a1fdf451'
  AND width IS NULL
  AND height IS NULL;
