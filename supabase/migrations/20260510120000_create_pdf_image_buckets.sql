INSERT INTO storage.buckets (id, name, public)
VALUES
  ('insyt-pdfs', 'insyt-pdfs', false),
  ('insyt-images', 'insyt-images', false)
ON CONFLICT (id) DO NOTHING;
