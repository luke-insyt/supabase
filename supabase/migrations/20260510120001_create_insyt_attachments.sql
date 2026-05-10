CREATE TABLE IF NOT EXISTS public.insyt_attachments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  insyt_id uuid NOT NULL REFERENCES public.insyts(id) ON DELETE CASCADE,
  kind text NOT NULL CHECK (kind IN ('video', 'pdf', 'image', 'thumbnail')),
  bucket text NOT NULL,
  storage_path text NOT NULL,
  filename text,
  mime text,
  size_bytes bigint,
  position int,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS insyt_attachments_insyt_id_idx
  ON public.insyt_attachments (insyt_id);

CREATE UNIQUE INDEX IF NOT EXISTS insyt_attachments_bucket_path_idx
  ON public.insyt_attachments (bucket, storage_path);

ALTER TABLE public.insyt_attachments ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Creators read own attachments"
  ON public.insyt_attachments FOR SELECT
  USING (
    EXISTS (
      SELECT 1
      FROM public.insyts i
      WHERE i.id = insyt_attachments.insyt_id
        AND (i.creator_email)::text = (auth.jwt() ->> 'email'::text)
    )
  );

CREATE POLICY "Public read attachments of published insyts"
  ON public.insyt_attachments FOR SELECT
  USING (
    EXISTS (
      SELECT 1
      FROM public.insyts i
      WHERE i.id = insyt_attachments.insyt_id
        AND (i.status)::text = 'published'::text
    )
  );

CREATE POLICY "Service insert attachments"
  ON public.insyt_attachments FOR INSERT
  WITH CHECK (true);
