-- GET-493: Insyts — automatic league/country tagging (schema only).
-- https://linear.app/getinsyt/issue/GET-493
--
-- What: a sibling table public.insyt_derived_attributes, one row per insyt, holding
-- the club / league / league tier / country that an insyt's title + abstract (+ tags)
-- talk about. It exists for digest-style matching of recipients to insyts
-- (recipient side = public.crm_derived_attributes, GET-492).
--
-- Who writes it: a Cowork scheduled task (service role), added later — this migration
-- ships no population job. The job writes NULL rather than guessing when the text does
-- not name a league or club. A row with every attribute NULL and confidence NULL means
-- "looked at it, found nothing"; the job still writes it WITH source_content_rev and
-- source_updated_at, so the staleness check stops it re-processing the same insyt until
-- the insyt changes. (source_fields may be '{}' on such a row, and is harmless if '{}'
-- even when confidence is set.)
--
-- league_tier is only meaningful with a country: the job must not write a league_tier
-- without also writing country (NULL country is "unknown", never "Germany"). This is a
-- job contract, not a CHECK, so the twin crm_derived_attributes (GET-492) stays in step;
-- if a CHECK (league_tier is null or country is not null) is added, add it to both.
--
-- Why a sibling table and NOT new columns on public.insyts:
--   - No app/server code reads or filters insyts by league/country/tier (the feed
--     filters on insyts.tags); the only consumer is a service-role matching job.
--   - Writing derived columns on insyts would fire the GET-73 touch trigger
--     (updated_at = now() on every UPDATE): a nightly tagging run would reorder the
--     feed (sorted by updated_at) and mark insyts as "edited" for update notifications.
--   - insyts is read by anon/authenticated through column grants; a separate table with
--     RLS on + revoke all is safe by default.
--   - Staleness is tracked here (source_content_rev / source_updated_at) without
--     touching insyts. The job re-derives when
--       insyts.content_rev > source_content_rev OR insyts.updated_at > source_updated_at
--     (content_rev does NOT bump on tag-only edits — GET-486 — so updated_at is needed too).
--   If the app ever needs to filter by league, add a read path (view/RPC) or promote
--   these to columns later (mind the GET-73 trigger then).
--
-- Shared ladder with crm_derived_attributes (GET-492): same league_tier CHECK (1..7),
-- same confidence vocabulary, same column comments. Change both together.
-- Matching must compare (country, league_tier) together, never league_tier alone.
-- Human reference: webflow-app-documentation/features/ (GET-492/493 feature doc).
--
-- public.club_league_seasons (GET-348 Social Search provider cache) is intentionally
-- not touched or reused.
--
-- Additive and re-runnable. Does not alter public.insyts.

create table if not exists public.insyt_derived_attributes (
  insyt_id      uuid primary key references public.insyts (id) on delete cascade,
  club_name     text check (char_length(btrim(club_name)) between 1 and 200),
  league_name   text check (char_length(btrim(league_name)) between 1 and 200),
  league_tier   smallint constraint insyt_derived_attributes_league_tier_check check (league_tier between 1 and 7),
  country       text check (char_length(btrim(country)) between 2 and 60),
  confidence    text constraint insyt_derived_attributes_confidence_check check (confidence in ('verified', 'inferred')),
  -- audit: which insyt text it came from
  source_fields text[] not null default '{}' check (source_fields <@ array['title', 'abstract', 'tags']::text[]),
  source_content_rev integer,       -- insyts.content_rev at derive time (GET-486: bumped on title/abstract/body edits, NOT on tag edits)
  source_updated_at  timestamptz,   -- insyts.updated_at at derive time (also catches tag-only edits)
  derived_by    text check (char_length(derived_by) <= 100),
  computed_at   timestamptz not null default now(),
  constraint insyt_derived_attributes_confidence_required
    check (confidence is not null or (club_name is null and league_name is null and league_tier is null and country is null))
);

create index if not exists insyt_derived_attributes_country_tier_idx
  on public.insyt_derived_attributes (country, league_tier)
  where league_tier is not null;

-- Server-only: RLS on with no policies, no anon/authenticated grants.
alter table public.insyt_derived_attributes enable row level security;
revoke all on public.insyt_derived_attributes from anon, authenticated;

comment on table public.insyt_derived_attributes is
  'GET-493: league/club/country derived from an insyt''s title/abstract/tags by a service-role scheduled job, for digest-style recipient matching. One row per insyt; NULL when not named. Shared ladder with crm_derived_attributes (GET-492). Server-only.';

comment on column public.insyt_derived_attributes.league_tier is
  'Level of the league in its own country''s pyramid, 1 = top flight (same meaning as LeagueEntry.tier '
  'in the RN Social Search registry, GET-472). Not comparable across countries: always match on '
  '(country, league_tier). German ladder: 1 = 1. Bundesliga; 2 = 2. Bundesliga; 3 = 3. Liga; '
  '4 = Regionalliga (Bayern/Nord/Nordost/Südwest/West); 5 = Oberliga (all Oberligen incl. Bayernliga, '
  'Hessenliga, Bremen-Liga); 6 = Verbandsliga/Landesliga (6th tier, top level of the state FA; name '
  'varies by state); 7 = Amateurfußball: tier 7 and below (Landesliga, Bezirksliga, Kreisliga, ...) or '
  '"amateur" with no level named (catch-all bottom rung). Outside Germany: the level in that country''s '
  'pyramid with country set (e.g. Regionalliga Ost Austria = 3, Tweede Divisie = 3). NULL = level unknown, '
  'or youth/women''s leagues with no clean rung. Same ladder as crm_derived_attributes.league_tier '
  '(GET-492); change both together.';

comment on column public.insyt_derived_attributes.country is
  'English country name as in the RN Social Search registry (''Germany'', ''Austria'', ''Switzerland'', ''Netherlands'', ...). Written explicitly, including ''Germany''. NULL = unknown, NOT "Germany by default". Required whenever league_tier is set (job contract).';

comment on column public.insyt_derived_attributes.confidence is
  'verified = the club or league is named explicitly in the source text; inferred = derived '
  '(e.g. tier from a club name, country from a league name). NULL only on an all-null "found nothing" row. '
  'Same vocabulary as crm_derived_attributes.confidence (GET-492).';

comment on column public.insyt_derived_attributes.source_fields is
  'Which insyt fields the values were derived from (subset of title, abstract, tags).';

comment on column public.insyt_derived_attributes.source_content_rev is
  'insyts.content_rev at derive time. content_rev is not bumped on tag-only edits (GET-486), so staleness also checks source_updated_at.';

comment on column public.insyt_derived_attributes.source_updated_at is
  'insyts.updated_at at derive time. Re-derive when insyts.content_rev > source_content_rev OR insyts.updated_at > source_updated_at.';
