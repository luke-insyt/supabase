-- Track the canonical bucket path and content type alongside the public
-- url on agreement_versions. The public url is what the page fetches;
-- bucket_path is the immutable storage key we can use to re-sign or
-- migrate later without parsing url strings.

ALTER TABLE public.agreement_versions
  ADD COLUMN IF NOT EXISTS bucket_path  text,
  ADD COLUMN IF NOT EXISTS content_type text;

-- Once the v1.0 body has been uploaded to the bucket as v1.0.html via
-- Supabase Studio, run the following manually (or wrap in a follow-up
-- migration) to repoint the existing row at the bucket:
--
--   UPDATE public.agreement_versions
--   SET    bucket_path  = 'v1.0.html',
--          content_type = 'text/html',
--          url          = 'https://<project-ref>.supabase.co/storage/v1/object/public/creator-agreements/v1.0.html'
--   WHERE  version = 'v1.0';
