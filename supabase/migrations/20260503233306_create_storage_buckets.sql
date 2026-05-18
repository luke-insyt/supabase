INSERT INTO storage.buckets (id, name, public)
VALUES
  ('insyts-thumbnails', 'insyts-thumbnails', true),
  ('insyt-videos', 'insyt-videos', false)
ON CONFLICT (id) DO NOTHING;
