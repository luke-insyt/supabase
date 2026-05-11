-- Replace insyts-thumbnails with insyt-thumbnails (singular naming).
-- Destructive: deletes all objects in the old bucket and any attachment rows
-- pointing at it. Acceptable because only test data lived there at the time
-- of writing.

-- 1. Drop the storage policy that references the old bucket
DROP POLICY IF EXISTS "public_read_thumbnails" ON storage.objects;

-- 2. Delete all objects (required before the bucket can be dropped)
DELETE FROM storage.objects WHERE bucket_id = 'insyts-thumbnails';

-- 3. Drop the old bucket
DELETE FROM storage.buckets WHERE id = 'insyts-thumbnails';

-- 4. Delete now-orphaned attachment rows (their files are gone)
DELETE FROM public.insyt_attachments WHERE bucket = 'insyts-thumbnails';

-- 5. Create the new bucket (public, same settings as old)
INSERT INTO storage.buckets (id, name, public)
VALUES ('insyt-thumbnails', 'insyt-thumbnails', true)
ON CONFLICT (id) DO NOTHING;

-- 6. Public-read storage policy on the new bucket
CREATE POLICY "public_read_thumbnails"
  ON storage.objects
  AS PERMISSIVE
  FOR SELECT
  TO public
  USING (bucket_id = 'insyt-thumbnails'::text);
