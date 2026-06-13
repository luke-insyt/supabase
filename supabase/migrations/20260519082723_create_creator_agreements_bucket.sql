-- Public-read storage bucket holding versioned Creator Agreement bodies
-- consumed by the /become-insyter page. Each version is a separate
-- immutable file (e.g. v1.0.html), referenced from a row in
-- public.agreement_versions. Only the service role uploads new versions
-- (via Supabase Studio or a one-shot script); authenticated and
-- unauthenticated users can only read.

INSERT INTO storage.buckets (id, name, public)
VALUES ('creator-agreements', 'creator-agreements', true)
ON CONFLICT (id) DO NOTHING;

DROP POLICY IF EXISTS "creator-agreements public read" ON storage.objects;
CREATE POLICY "creator-agreements public read"
  ON storage.objects FOR SELECT
  USING (bucket_id = 'creator-agreements');
