-- GET-494 · CRM: role / organization / agent columns on crm_derived_attributes.
-- Ticket: https://linear.app/getinsyt/issue/GET-494
-- Follow-up to GET-492 (20261127120000_get492_crm_derived_attributes.sql), which is the base.
--
-- Why: club_name alone cannot tell a club's Head of Scouting from a player agent, and an
-- agency (e.g. 'GROW Talents') is not a club (e.g. 'Eintracht Braunschweig'). The CRM needs
-- the person's job title, their non-club employer, and an explicit agent flag to target
-- outreach and digests.
--
-- Schema only, no population job. The Cowork scheduled task fills these later and writes
-- NULL rather than guessing. Job note: it must read ALL admin_user_notes for the user, not
-- just admin_user_crm_v.latest_note: club and role are often split across separate notes
-- (e.g. one note names the club, a later one says "now Head of Scouting").
--
-- Additive and re-runnable: ADD COLUMN IF NOT EXISTS, constraints dropped-if-exists then
-- re-added, CREATE OR REPLACE VIEW. A second apply changes nothing (it re-validates the CHECKs
-- under a brief ACCESS EXCLUSIVE lock, harmless on this small table). Access stays service-role only
-- (no anon/authenticated grants; the REVOKEs are restated because Supabase default
-- privileges grant to anon/authenticated).

alter table public.crm_derived_attributes
  add column if not exists role              text,
  add column if not exists organization_name text,
  add column if not exists is_agent          boolean;

-- Text checks in the same style as club_name (btrim length 1..200). Named explicitly so the
-- drop/re-add below is stable across applies.
alter table public.crm_derived_attributes
  drop constraint if exists crm_derived_attributes_role_check;
alter table public.crm_derived_attributes
  add constraint crm_derived_attributes_role_check
  check (char_length(btrim(role)) between 1 and 200);

alter table public.crm_derived_attributes
  drop constraint if exists crm_derived_attributes_organization_name_check;
alter table public.crm_derived_attributes
  add constraint crm_derived_attributes_organization_name_check
  check (char_length(btrim(organization_name)) between 1 and 200);

-- organization_name holds a NON-club employer only: enforce that it never repeats club_name
-- (case/whitespace-insensitive), so a job bug cannot write the club into both columns.
alter table public.crm_derived_attributes
  drop constraint if exists crm_derived_attributes_organization_not_club;
alter table public.crm_derived_attributes
  add constraint crm_derived_attributes_organization_not_club
  check (organization_name is null or club_name is null
         or lower(btrim(organization_name)) <> lower(btrim(club_name)));

-- Extend "any derived value needs a confidence; an all-null row needs none" to the new
-- columns. Without this a row with only a role (or only is_agent) and no confidence passes.
-- Existing rows: the old rule already forced confidence on any row with a value, and the new
-- columns are NULL on every pre-existing row, so every existing row satisfies the new rule.
alter table public.crm_derived_attributes
  drop constraint if exists crm_derived_attributes_confidence_required;
alter table public.crm_derived_attributes
  add constraint crm_derived_attributes_confidence_required
  check (confidence is not null
         or (club_name is null and league_name is null and league_tier is null
             and country is null and coalesce(cardinality(derived_interests), 0) = 0
             and role is null and organization_name is null and is_agent is null));

comment on table public.crm_derived_attributes is
  'GET-492/GET-494: club/league/interest facts plus role, organization_name (non-club employer) '
  'and is_agent, derived from admin_user_notes by a Cowork scheduled job. '
  'NULL rather than guess. Service-role only (RLS on, no policies, anon/authenticated revoked).';

comment on column public.crm_derived_attributes.role is
  'GET-494: free-text job title as stated in the notes (e.g. ''Scout'', ''Head of Scouting'', '
  '''Sporting Director'', ''Player Agent''). Not normalised to a vocabulary. NULL = unknown.';

comment on column public.crm_derived_attributes.organization_name is
  'GET-494: non-club employer or agency (e.g. ''GROW Talents''), distinct from club_name '
  '(e.g. ''Eintracht Braunschweig''). Never a duplicate of club_name: a club employer goes in '
  'club_name only (enforced by crm_derived_attributes_organization_not_club). NULL = none stated / unknown.';

comment on column public.crm_derived_attributes.is_agent is
  'GET-494: true for player agents / agencies; false only when the notes clearly say otherwise '
  '(e.g. club staff, independent scout); NULL = unknown.';

comment on column public.crm_derived_attributes.confidence is
  'verified = the club or league is named explicitly in the source text; inferred = derived '
  '(e.g. tier from a club name, country from a league name). NULL only on an all-null "found nothing" row. '
  'Same vocabulary as insyt_derived_attributes.confidence (GET-493). '
  'GET-494: also covers role, organization_name and is_agent (verified = stated explicitly in a note, '
  'inferred = read between the lines); on a mixed row, confidence is the weakest of the values set.';

revoke all on public.crm_derived_attributes from anon, authenticated;

-- admin_user_crm_v: GET-492 body verbatim; GET-494 columns APPENDED at the very end only
-- (CREATE OR REPLACE VIEW cannot reorder/rename/retype existing columns). The 1:1 PK join is
-- unchanged. security_invoker is restated: CREATE OR REPLACE drops reloptions left out.
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
  d.computed_at       as derived_computed_at,
  -- GET-494 (appended):
  d.role              as derived_role,
  d.organization_name as derived_organization,
  d.is_agent          as derived_is_agent
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
