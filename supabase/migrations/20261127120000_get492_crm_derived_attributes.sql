-- GET-492 · CRM: structured club / league / interest columns derived from admin notes.
-- Ticket: https://linear.app/getinsyt/issue/GET-492
-- Design: webflow-app-documentation/features/ (GET-492/493 derived-attributes feature doc).
--
-- Schema only. There is no population job here: a Cowork scheduled task reads
-- public.admin_user_notes and fills public.crm_derived_attributes later. That job writes
-- NULL rather than guessing. A row with every attribute NULL and confidence NULL means
-- "looked at it, found nothing"; it is kept so computed_at / source_note_at /
-- source_note_count stop the job re-processing the same user until the notes change.
--
-- Staleness (job contract): re-derive when the user's notes now have
--   max(coalesce(edited_at, created_at)) > source_note_at   (new or edited note), OR
--   count(*) <> source_note_count                           (a note was deleted).
-- The count check matters: deleting a note never moves max(...) forward, so without it
-- facts from a deleted note would linger here and in admin_user_crm_v.
--
-- Tier ladder: GET-493 insyt_derived_attributes uses the SAME ladder, CHECK and column
-- comments. Change both together.
--
-- club_league_seasons = GET-348 Social Search provider cache; intentionally not reused.
--
-- Additive and re-runnable. Access is service-role only (Cowork job writes; RN /api/cs/*
-- reads via supabaseAdmin behind requireAdmin). The explicit REVOKEs are load-bearing:
-- Supabase default privileges grant new public objects to anon/authenticated.

create table if not exists public.crm_derived_attributes (
  -- Same key convention as GET-454's admin_user_crm: auth.users(id) = public.users.auth_user_id.
  user_id           uuid primary key references auth.users (id) on delete cascade,
  club_name         text check (char_length(btrim(club_name)) between 1 and 200),
  league_name       text check (char_length(btrim(league_name)) between 1 and 200),
  league_tier       smallint
                      constraint crm_derived_attributes_league_tier_check
                      check (league_tier between 1 and 7),
  country           text check (char_length(btrim(country)) between 2 and 60),
  -- <= 20 labels, no NULL and no blank/whitespace-only element (U+001F joins the elements
  -- for the regex; a CHECK cannot btrim per element without a subquery).
  derived_interests text[] check (cardinality(derived_interests) <= 20
                                  and array_position(derived_interests, null) is null
                                  and (cardinality(derived_interests) = 0
                                       or array_to_string(derived_interests, E'\x1f')
                                          !~ E'(^|\x1f)\\s*(\x1f|$)')),
  confidence        text
                      constraint crm_derived_attributes_confidence_check
                      check (confidence in ('verified', 'inferred')),
  -- Audit: the newest note the job considered.
  source_note_id    uuid references public.admin_user_notes (id) on delete set null,
  -- max(coalesce(edited_at, created_at)) over the notes considered; the job re-derives when
  -- a newer note exists.
  source_note_at    timestamptz,
  -- count(*) of the user's notes at derive time; catches deletions (see header).
  source_note_count integer check (source_note_count >= 0),
  derived_by        text check (char_length(derived_by) <= 100),  -- e.g. 'cowork:crm-derive@v1'
  computed_at       timestamptz not null default now(),
  -- Any derived value needs a confidence; an all-null row ("found nothing") needs none.
  constraint crm_derived_attributes_confidence_required
    check (confidence is not null
           or (club_name is null and league_name is null and league_tier is null
               and country is null and coalesce(cardinality(derived_interests), 0) = 0))
);

comment on table public.crm_derived_attributes is
  'GET-492: club/league/interest facts derived from admin_user_notes by a Cowork scheduled job. '
  'NULL rather than guess. Service-role only (RLS on, no policies, anon/authenticated revoked).';

comment on column public.crm_derived_attributes.league_tier is
  'Level of the league in its own country''s pyramid, 1 = top flight (same meaning as LeagueEntry.tier '
  'in the RN Social Search registry, GET-472). Not comparable across countries: always match on '
  '(country, league_tier). German ladder: 1 = 1. Bundesliga; 2 = 2. Bundesliga; 3 = 3. Liga; '
  '4 = Regionalliga (Bayern/Nord/Nordost/Südwest/West); 5 = Oberliga (all Oberligen incl. Bayernliga, '
  'Hessenliga, Bremen-Liga); 6 = Verbandsliga/Landesliga (6th tier, top level of the state FA; name '
  'varies by state); 7 = Amateurfußball: tier 7 and below (Landesliga, Bezirksliga, Kreisliga, ...) or '
  '"amateur" with no level named (catch-all bottom rung). Outside Germany: the level in that country''s '
  'pyramid with country set (e.g. Regionalliga Ost Austria = 3, Tweede Divisie = 3). NULL = level unknown, '
  'or youth/women''s leagues with no clean rung. Same ladder as insyt_derived_attributes.league_tier '
  '(GET-493); change both together.';

comment on column public.crm_derived_attributes.confidence is
  'verified = the club or league is named explicitly in the source text; inferred = derived '
  '(e.g. tier from a club name, country from a league name). NULL only on an all-null "found nothing" row. '
  'Same vocabulary as insyt_derived_attributes.confidence (GET-493).';

comment on column public.crm_derived_attributes.country is
  'English country name as in the RN Social Search registry (''Germany'', ''Austria'', ''Switzerland'', ''Netherlands'', ...). Written explicitly, including ''Germany''. NULL = unknown, NOT "Germany by default". Required whenever league_tier is set (job contract).';

comment on column public.crm_derived_attributes.derived_interests is
  'Free-text interest labels; reuse user_content_preferences.interests wording where possible. '
  'No blank labels. confidence also covers interests: on a row with interests but no club/league, '
  'verified = the interest is stated explicitly in a note, inferred = read between the lines. '
  'On a mixed row, confidence is the weaker of the club/league and interest confidences.';

comment on column public.crm_derived_attributes.source_note_count is
  'count(*) of admin_user_notes for the user at derive time. Re-derive when the current count differs '
  '(a deleted note never advances source_note_at).';

-- Digest matching: (country, league_tier) together, never tier alone.
create index if not exists crm_derived_attributes_country_tier_idx
  on public.crm_derived_attributes (country, league_tier)
  where league_tier is not null;

alter table public.crm_derived_attributes enable row level security;  -- no policies
revoke all on public.crm_derived_attributes from anon, authenticated;

-- admin_user_crm_v: GET-454 body verbatim; derived_* columns APPENDED at the end only
-- (CREATE OR REPLACE VIEW cannot reorder/rename/retype existing columns; RN cs-logic
-- USERS_COLUMNS lists columns explicitly, so the new ones stay invisible until the UI opts in).
-- The 1:1 PK join cannot multiply rows or touch the correlated-subquery counts.
-- security_invoker is restated: CREATE OR REPLACE drops reloptions that are left out.
create or replace view public.admin_user_crm_v with (security_invoker = true) as
select
  u.auth_user_id, u.email, u.display_name, u.username, u.roles, u.location,
  u.created_at, u.last_logged_in_at,
  case when u.is_creator then 'Insyter' else 'Reader' end            as user_type,
  p.sports as pref_sports, p.content_types as pref_content_types,
  p.interests as pref_interests, p.intent as pref_intent,
  p.interest_note as pref_interest_note,
  coalesce((select count(distinct a.day) from public.user_activity_days a
             where a.user_id = u.auth_user_id
               and a.day >= (now() at time zone 'utc')::date - 29), 0)::int as active_days_30d,
  coalesce(c.organization, nullif(btrim(u.organization), ''))        as organization,
  case when c.organization is not null then 'crm'
       when nullif(btrim(u.organization), '') is not null then 'user' end as organization_source,
  -- Hidden: lets search/filter still find the user's own profile value after a CRM value is
  -- set (S5-AC1/S5-AC3). Never shown, never exported.
  nullif(btrim(u.organization), '')                                  as profile_organization,
  u.creator_terms_accepted_at as agreement_accepted_at, u.agreement_version,
  (select count(*) from public.admin_user_notes n
    where n.user_id = u.auth_user_id)::int                          as notes_count,
  ln.body as latest_note, ln.author_name as latest_note_author, ln.created_at as latest_note_at,
  -- Hidden: filter/search only.
  (select string_agg(n.body, ' ') from public.admin_user_notes n
    where n.user_id = u.auth_user_id)                               as notes_search,
  -- GET-492 (appended):
  d.club_name         as derived_club,
  d.league_name       as derived_league,
  d.league_tier       as derived_league_tier,
  d.country           as derived_country,
  d.derived_interests,
  d.confidence        as derived_confidence,
  d.computed_at       as derived_computed_at
from public.users u
left join public.user_content_preferences p on p.user_id = u.auth_user_id
left join public.admin_user_crm c          on c.user_id = u.auth_user_id
left join public.crm_derived_attributes d  on d.user_id = u.auth_user_id
left join lateral (
  select n.body, n.author_name, n.created_at from public.admin_user_notes n
   where n.user_id = u.auth_user_id
   order by n.created_at desc, n.id desc limit 1
) ln on true;

revoke all on public.admin_user_crm_v from anon, authenticated;
