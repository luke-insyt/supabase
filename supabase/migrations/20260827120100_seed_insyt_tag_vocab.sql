-- GET-190 / requirements D-9: starter vocabulary supplied by Lukas. Idempotent (slug is the
-- conflict key and is generated), so re-running is safe. `slug` is NOT supplied — it is generated.
-- Listed A→Z for readability only; AC-10's default page comes from .order('label') in the client.
INSERT INTO public.insyt_tag_vocab (label)
SELECT v FROM unnest(ARRAY[
  'Amateurfußball',
  'Bayernliga',
  'Emerging Talents',
  'Oberliga BW',
  'Oberliga Rheinland-Pfalz',
  'Regionalliga',
  'Verbandsliga Nordbaden',
  'Youth Development'
]) AS v
ON CONFLICT (slug) DO NOTHING;
