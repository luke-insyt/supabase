-- Add insyt-thumbnails (singular) bucket alongside the existing insyts-thumbnails.
-- The old bucket is left in place because direct DELETE on storage.objects /
-- storage.buckets is blocked by Supabase (SQLSTATE 42501 -- "Use the Storage
-- API instead"). Cleanup of the old bucket, if desired, must happen via the
-- Storage API / dashboard, not a migration.

INSERT INTO storage.buckets (id, name, public)
VALUES ('insyt-thumbnails', 'insyt-thumbnails', true)
ON CONFLICT (id) DO NOTHING;
