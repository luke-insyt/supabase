-- Cover banner image for the creator profile hero. Mirrors the avatar
-- storage pattern: a public bucket keyed by auth.uid() with per-folder
-- write-owner RLS, and a free-form url/path column on users.

ALTER TABLE public.users
  ADD COLUMN IF NOT EXISTS cover_image_url text;

INSERT INTO storage.buckets (id, name, public)
VALUES ('creator-covers', 'creator-covers', true)
ON CONFLICT (id) DO NOTHING;

DROP POLICY IF EXISTS "creator-covers public read" ON storage.objects;
CREATE POLICY "creator-covers public read"
  ON storage.objects FOR SELECT
  USING (bucket_id = 'creator-covers');

DROP POLICY IF EXISTS "creator-covers owner insert" ON storage.objects;
CREATE POLICY "creator-covers owner insert"
  ON storage.objects FOR INSERT
  TO authenticated
  WITH CHECK (
    bucket_id = 'creator-covers'
    AND (storage.foldername(name))[1] = auth.uid()::text
  );

DROP POLICY IF EXISTS "creator-covers owner update" ON storage.objects;
CREATE POLICY "creator-covers owner update"
  ON storage.objects FOR UPDATE
  TO authenticated
  USING (
    bucket_id = 'creator-covers'
    AND (storage.foldername(name))[1] = auth.uid()::text
  )
  WITH CHECK (
    bucket_id = 'creator-covers'
    AND (storage.foldername(name))[1] = auth.uid()::text
  );

DROP POLICY IF EXISTS "creator-covers owner delete" ON storage.objects;
CREATE POLICY "creator-covers owner delete"
  ON storage.objects FOR DELETE
  TO authenticated
  USING (
    bucket_id = 'creator-covers'
    AND (storage.foldername(name))[1] = auth.uid()::text
  );
