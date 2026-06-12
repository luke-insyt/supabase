-- TECH-DEBT §5.4: abandoned create-insyt uploads sit orphaned in storage
-- (<auth_user_id>/<correlation_id>/… in the insyt-* buckets) when a creator
-- uploads files but never submits or saves a draft.
--
-- This lists storage objects in the three insyt upload buckets that are
-- (a) older than p_min_age_days (floor 1 — never sweeps an in-progress
--     authoring session),
-- (b) NOT referenced by insyt_attachments (covers live insyts AND drafts —
--     draft attachments are real rows), and
-- (c) NOT referenced by the legacy insyts.thumbnail_url / insyts.video_url
--     columns (pre-attachments rows, incl. seeded fixtures, reference storage
--     by URL/key only).
--
-- Deletion itself happens through the Storage API (the cleanup-orphan-uploads
-- edge function) — never delete from storage.objects directly, that orphans
-- the underlying S3 objects.

CREATE OR REPLACE FUNCTION public.list_orphan_upload_objects(p_min_age_days int DEFAULT 7)
RETURNS TABLE (bucket text, path text, created_at timestamptz, size_bytes bigint)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, storage
AS $$
  SELECT o.bucket_id AS bucket,
         o.name      AS path,
         o.created_at,
         COALESCE((o.metadata->>'size')::bigint, 0) AS size_bytes
    FROM storage.objects o
   WHERE o.bucket_id IN ('insyt-thumbnails', 'insyt-images', 'insyt-videos')
     AND o.created_at < now() - make_interval(days => GREATEST(p_min_age_days, 1))
     AND o.name NOT LIKE '%.emptyFolderPlaceholder'
     AND NOT EXISTS (
           SELECT 1
             FROM public.insyt_attachments a
            WHERE a.bucket = o.bucket_id
              AND a.storage_path = o.name
         )
     AND NOT EXISTS (
           SELECT 1
             FROM public.insyts i
            WHERE (i.thumbnail_url IS NOT NULL AND position(o.name IN i.thumbnail_url) > 0)
               OR (i.video_url     IS NOT NULL AND position(o.name IN i.video_url) > 0)
         )
   ORDER BY o.created_at
$$;

-- Maintenance-only: the cleanup edge function calls this with the service
-- client. No browser role may enumerate storage contents.
REVOKE ALL ON FUNCTION public.list_orphan_upload_objects(int) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.list_orphan_upload_objects(int) FROM anon;
REVOKE ALL ON FUNCTION public.list_orphan_upload_objects(int) FROM authenticated;
