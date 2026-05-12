-- One-time backfill: populate insyts.thumbnail_url for rows where the n8n
-- workflow uploaded the thumbnail to storage but never wrote the URL onto
-- the row. The fix in the workflow handles new inserts going forward; this
-- migration covers everything created before the workflow change.
--
-- Builds the public URL from the storage_path on the matching
-- insyt_attachments row (kind='thumbnail').
--
-- Project ref hardcoded: this migration is scoped to staging
-- (xeqjairmlwnjtmselyvo). When promoting to production, replace the host
-- below with the production project ref before merging to main, or run
-- the equivalent UPDATE manually against the prod DB.

UPDATE public.insyts AS i
SET thumbnail_url =
  'https://xeqjairmlwnjtmselyvo.supabase.co/storage/v1/object/public/insyt-thumbnails/'
  || a.storage_path
FROM public.insyt_attachments AS a
WHERE a.insyt_id = i.id
  AND a.kind = 'thumbnail'
  AND i.thumbnail_url IS NULL;
