-- Rename insyts-thumbnails -> insyt-thumbnails for naming consistency with
-- insyt-videos / insyt-pdfs / insyt-images. Idempotent: safe to re-run and
-- safe on environments that have never had the old bucket.

-- 1. Create the new bucket (public, same as the old one)
INSERT INTO storage.buckets (id, name, public)
VALUES ('insyt-thumbnails', 'insyt-thumbnails', true)
ON CONFLICT (id) DO NOTHING;

-- 2. Move any objects from the old bucket into the new bucket
UPDATE storage.objects
SET bucket_id = 'insyt-thumbnails'
WHERE bucket_id = 'insyts-thumbnails';

-- 3. Update insyt_attachments rows that point at the old bucket
UPDATE public.insyt_attachments
SET bucket = 'insyt-thumbnails'
WHERE bucket = 'insyts-thumbnails';

-- 4. Recreate the public-read storage policy on the new bucket name
DROP POLICY IF EXISTS "public_read_thumbnails" ON storage.objects;
CREATE POLICY "public_read_thumbnails"
  ON storage.objects
  AS PERMISSIVE
  FOR SELECT
  TO public
  USING (bucket_id = 'insyt-thumbnails'::text);

-- 5. Drop the old (now empty) bucket
DELETE FROM storage.buckets WHERE id = 'insyts-thumbnails';
