ALTER TABLE public.insyts
ADD COLUMN IF NOT EXISTS body_html text;

ALTER TABLE public.insyts
ADD COLUMN IF NOT EXISTS video_storage_path varchar;
