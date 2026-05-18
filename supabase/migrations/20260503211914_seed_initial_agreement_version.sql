INSERT INTO public.agreement_versions (version, title, url, effective_date, is_current)
VALUES (
  'v1.0',
  'Terms of Service',
  'https://insyt-324865-60f6c3612c1842bd4e5d026bee.webflow.io/termsofservice',
  '2026-05-03',
  true
)
ON CONFLICT DO NOTHING;
