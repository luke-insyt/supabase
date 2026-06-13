-- Repoint the v1.0 agreement_versions row at the creator-agreements bucket.
-- The body was uploaded to:
--   creator-agreements/terms/creator-agreement-v1.0.html
-- The /become-insyter page fetches `url` directly, so this is what makes
-- the new styled body visible end-to-end.

UPDATE public.agreement_versions
SET    bucket_path  = 'terms/creator-agreement-v1.0.html',
       content_type = 'text/html',
       url          = 'https://xeqjairmlwnjtmselyvo.supabase.co/storage/v1/object/public/creator-agreements/terms/creator-agreement-v1.0.html'
WHERE  version = 'v1.0';
