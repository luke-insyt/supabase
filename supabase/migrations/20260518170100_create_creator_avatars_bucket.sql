-- Public bucket for creator profile photos shown on /creators/<slug> and
-- the sidebar. Object path convention:
--   <auth_user_id>/avatar-<unix_ms>.<ext>
-- The first folder segment must equal auth.uid() so users can only write
-- inside their own folder. Bucket is public so Webflow CMS can hot-link
-- the resulting URL on the Creators template page.

INSERT INTO storage.buckets (id, name, public)
VALUES ('creator-avatars', 'creator-avatars', true)
ON CONFLICT (id) DO NOTHING;

-- Anyone (including unauthenticated visitors viewing /creators/<slug>) can
-- read avatars. Reads are also implicitly allowed by the bucket being
-- public, but an explicit policy makes the intent obvious.
DROP POLICY IF EXISTS "creator-avatars public read" ON storage.objects;
CREATE POLICY "creator-avatars public read"
  ON storage.objects FOR SELECT
  USING (bucket_id = 'creator-avatars');

DROP POLICY IF EXISTS "creator-avatars owner insert" ON storage.objects;
CREATE POLICY "creator-avatars owner insert"
  ON storage.objects FOR INSERT
  TO authenticated
  WITH CHECK (
    bucket_id = 'creator-avatars'
    AND (storage.foldername(name))[1] = auth.uid()::text
  );

DROP POLICY IF EXISTS "creator-avatars owner update" ON storage.objects;
CREATE POLICY "creator-avatars owner update"
  ON storage.objects FOR UPDATE
  TO authenticated
  USING (
    bucket_id = 'creator-avatars'
    AND (storage.foldername(name))[1] = auth.uid()::text
  )
  WITH CHECK (
    bucket_id = 'creator-avatars'
    AND (storage.foldername(name))[1] = auth.uid()::text
  );

DROP POLICY IF EXISTS "creator-avatars owner delete" ON storage.objects;
CREATE POLICY "creator-avatars owner delete"
  ON storage.objects FOR DELETE
  TO authenticated
  USING (
    bucket_id = 'creator-avatars'
    AND (storage.foldername(name))[1] = auth.uid()::text
  );
