-- TEST DATA: attach expertise tags to a few staging creators so the Insyter
-- Search expertise filter has real matches to return. The seeded vocabulary
-- (20260526170000_seed_expertise_tags) only adds the tag *options*; until a
-- creator is linked to a tag in creator_expertise, .overlaps('expertise_slugs')
-- matches nobody.
--
-- Maps display_name -> tag label via the canonical slug. Idempotent
-- (ON CONFLICT DO NOTHING). On prod this is a harmless no-op: these test
-- display_names don't exist there, so the join yields zero rows.
INSERT INTO public.creator_expertise (user_id, tag_id)
SELECT u.auth_user_id, t.id
FROM public.users u
JOIN (VALUES
  ('2W Test',                  'Tactical Analysis'),
  ('2W Test',                  'Match Analysis'),
  ('2W Test',                  'Scouting & Recruitment'),
  ('Fully Populated Creator',  'Strength & Conditioning'),
  ('Fully Populated Creator',  'Mindset & Motivation'),
  ('Fully Populated Creator',  'Youth Development'),
  ('Lukas Lampe',              'Performance Data & Analytics'),
  ('Lukas Lampe',              'Game Strategy'),
  ('Center Lampe',             'Technique & Skills'),
  ('Center Lampe',             'Set Pieces'),
  ('Stripe Not Onboarded',     'Nutrition'),
  ('Stripe Not Onboarded',     'Mobility & Recovery')
) AS m(display_name, label) ON m.display_name = u.display_name
JOIN public.expertise_tags t ON t.slug = public.expertise_slugify(m.label)
WHERE u.is_creator = true
ON CONFLICT DO NOTHING;
