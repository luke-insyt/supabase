-- Seed a standardized starter expertise vocabulary so the tag autocomplete (on
-- become-insyter + the Edit Profile modal) and the Insyter Search filter have a
-- baseline set from day one. Idempotent — slug-deduped via expertise_slugify, so
-- re-running is a no-op. Creators still auto-add custom tags beyond this list.
INSERT INTO public.expertise_tags (label, slug)
VALUES
  ('Tactical Analysis',             public.expertise_slugify('Tactical Analysis')),
  ('Strength & Conditioning',       public.expertise_slugify('Strength & Conditioning')),
  ('Nutrition',                     public.expertise_slugify('Nutrition')),
  ('Sports Psychology',             public.expertise_slugify('Sports Psychology')),
  ('Injury Prevention & Rehab',     public.expertise_slugify('Injury Prevention & Rehab')),
  ('Match Analysis',                public.expertise_slugify('Match Analysis')),
  ('Scouting & Recruitment',        public.expertise_slugify('Scouting & Recruitment')),
  ('Youth Development',             public.expertise_slugify('Youth Development')),
  ('Goalkeeping',                   public.expertise_slugify('Goalkeeping')),
  ('Set Pieces',                    public.expertise_slugify('Set Pieces')),
  ('Performance Data & Analytics',  public.expertise_slugify('Performance Data & Analytics')),
  ('Endurance & Conditioning',      public.expertise_slugify('Endurance & Conditioning')),
  ('Mobility & Recovery',           public.expertise_slugify('Mobility & Recovery')),
  ('Mindset & Motivation',          public.expertise_slugify('Mindset & Motivation')),
  ('Technique & Skills',            public.expertise_slugify('Technique & Skills')),
  ('Game Strategy',                 public.expertise_slugify('Game Strategy'))
ON CONFLICT (slug) DO NOTHING;
