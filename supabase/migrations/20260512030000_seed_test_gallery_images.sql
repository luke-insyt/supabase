-- Test-data seed: add 5 placeholder images (Picsum, varied aspect ratios) to
-- the staging test insyt 4da52d70-e8fa-5da1-94fa-4ca1e2c890b6 so the new
-- hero+strip gallery layout has something to show. Files were uploaded to
-- the insyt-images bucket out-of-band.
--
-- Safe to merge to prod: the WHERE clause matches by insyt_id slug, which
-- only exists on staging. ON CONFLICT keeps this idempotent.
INSERT INTO public.insyt_attachments (insyt_id, kind, bucket, storage_path, filename, mime, position, width, height)
SELECT
  i.id,
  'image',
  'insyt-images',
  '4da52d70-e8fa-5da1-94fa-4ca1e2c890b6/' || t.pos || '-test-image-' || t.pos || '.jpg',
  'Sample image ' || t.pos || ' (' || t.w || '×' || t.h || ')',
  'image/jpeg',
  t.pos,
  t.w,
  t.h
FROM public.insyts i,
  (VALUES
    (1, 1600, 1200),
    (2, 1200, 1600),
    (3, 1600, 900),
    (4, 1000, 1000),
    (5, 1400, 1000)
  ) AS t(pos, w, h)
WHERE i.insyt_id = '4da52d70-e8fa-5da1-94fa-4ca1e2c890b6'
ON CONFLICT (bucket, storage_path) DO NOTHING;
