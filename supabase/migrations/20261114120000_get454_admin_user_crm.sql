-- GET-454 · Admin Users CRM (RN admin stats → Users table).
-- Design: webflow-app-documentation/features/admin-users-crm/feature.md §3.
--
-- Additive only: two admin-only tables + one read view. Nothing existing is altered.
-- Access is service-role only (the RN server's /api/cs/* routes, gated by requireAdmin).
-- The explicit REVOKEs are load-bearing: Supabase default privileges grant new public
-- objects to anon/authenticated, and RLS alone does not cover the view.

-- Sales/marketing notes: one row per note.
create table public.admin_user_notes (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references auth.users (id) on delete cascade,
  author_id   uuid references auth.users (id) on delete set null,
  -- Snapshot at write time, so the note still shows a name after the author loses admin.
  author_name text not null,
  -- Backstop only: btrim strips spaces, not newlines. The server trims with zod and stores
  -- the trimmed value.
  body        text not null check (char_length(btrim(body)) between 1 and 2000),
  created_at  timestamptz not null default now(),
  edited_at   timestamptz
);
create index admin_user_notes_user_created
  on public.admin_user_notes (user_id, created_at desc);

-- Admin-only organization. Never touches users.organization (the user's own profile value).
create table public.admin_user_crm (
  user_id      uuid primary key references auth.users (id) on delete cascade,
  organization text not null check (char_length(btrim(organization)) between 1 and 200),
  updated_by   uuid references auth.users (id) on delete set null,
  updated_at   timestamptz not null default now()
);

alter table public.admin_user_notes enable row level security;
alter table public.admin_user_crm   enable row level security;
revoke all on public.admin_user_notes, public.admin_user_crm from anon, authenticated;

-- One row per users row (including rows with a null auth_user_id, so the table count matches
-- the all-time headline). Counts and the notes text are correlated subqueries, never
-- joins + GROUP BY: joining notes and activity days would multiply the counts.
create view public.admin_user_crm_v with (security_invoker = true) as
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
    where n.user_id = u.auth_user_id)                               as notes_search
from public.users u
left join public.user_content_preferences p on p.user_id = u.auth_user_id
left join public.admin_user_crm c          on c.user_id = u.auth_user_id
left join lateral (
  select n.body, n.author_name, n.created_at from public.admin_user_notes n
   where n.user_id = u.auth_user_id
   order by n.created_at desc, n.id desc limit 1
) ln on true;

revoke all on public.admin_user_crm_v from anon, authenticated;
