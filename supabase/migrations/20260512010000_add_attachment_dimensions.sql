ALTER TABLE public.insyt_attachments
  ADD COLUMN IF NOT EXISTS width integer,
  ADD COLUMN IF NOT EXISTS height integer;

COMMENT ON COLUMN public.insyt_attachments.width IS
  'Intrinsic pixel width for image-kind attachments. Null for non-images and for image rows uploaded before this column existed.';
COMMENT ON COLUMN public.insyt_attachments.height IS
  'Intrinsic pixel height for image-kind attachments. Null for non-images and for image rows uploaded before this column existed.';
