-- TECH-DEBT §4.4: the /insyts feed filters match insyts.sport / content_type
-- CASE-SENSITIVELY against the canonical vocabulary (src/lib/insyt-vocab.ts).
-- Legacy rows written before create-insyt-native (or hand-edited in the CMS)
-- can carry non-canonical casing ("tennis") and silently become unfilterable.
--
-- One-time normalization: any value that matches a canonical entry
-- case-insensitively (after trim) is rewritten to the canonical casing.
-- Values that match nothing are left untouched (visible, just unfilterable —
-- surfacing them beats silently rewriting unknown data).

WITH canon(label) AS (
  VALUES
    ('American Football'),('Athletics'),('Badminton'),('Baseball'),('Basketball'),
    ('Beach Volleyball'),('Bodybuilding'),('Boxing'),('Brazilian Jiu-Jitsu'),('BMX'),
    ('Canoeing'),('Cheerleading'),('Chess'),('Climbing'),('Combat Sports'),('Cricket'),
    ('CrossFit'),('Cycling'),('Dance'),('Esports'),('Field Hockey'),('Fitness'),
    ('Flag Football'),('Football'),('Formula Racing'),('Futsal'),('General'),('Golf'),
    ('Gymnastics'),('Handball'),('Ice Hockey'),('Judo'),('Karate'),('Karting'),
    ('Martial Arts'),('MMA'),('MotoGP'),('Mountain Biking'),('Motorsport'),('Padel'),
    ('Powerlifting'),('Rowing'),('Rugby'),('Running'),('Sailing'),('Skateboarding'),
    ('Skiing'),('Snowboarding'),('Softball'),('Squash'),('Surfing'),('Swimming'),
    ('Table Tennis'),('Taekwondo'),('Tennis'),('Trail Running'),('Triathlon'),
    ('Volleyball'),('Water Polo'),('Weightlifting'),('Wrestling'),('Other')
)
UPDATE public.insyts i
   SET sport = c.label
  FROM canon c
 WHERE i.sport IS NOT NULL
   AND lower(trim(i.sport)) = lower(c.label)
   AND i.sport <> c.label;

WITH canon(label) AS (
  VALUES
    ('Analysis'),('Athletes'),('Business'),('Clubs'),('Health'),('Interview'),
    ('Journalism'),('Knowledge'),('Lifestyle'),('Mental'),('Opinion'),('Performance'),
    ('Recovery'),('Scouting'),('Tactics'),('Training')
)
UPDATE public.insyts i
   SET content_type = c.label
  FROM canon c
 WHERE i.content_type IS NOT NULL
   AND lower(trim(i.content_type)) = lower(c.label)
   AND i.content_type <> c.label;
