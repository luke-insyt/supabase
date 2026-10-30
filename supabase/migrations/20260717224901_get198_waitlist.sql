-- GET-198: landing-page waiting list (soft-launch `home-2-copy`).
--
-- A single gated waiting list + preference capture for pre-signup leads: one
-- row per email, written ONLY by the service-role `submit-waitlist` edge fn
-- (the page is untrusted/public — no client ever writes here directly). roles
-- is a subset of {creator,buyer}; sports uses the canonical SPORTS vocab;
-- content_prefs the bespoke WAITLIST_CONTENT_PREFS survey labels (§2.1). interest
-- is a sanitized free-text scalar (<=280). See waitlist-landing-features.md §5.2.
--
-- Privacy (AC6): RLS ON + ZERO policies => anon AND authenticated are fully
-- denied SELECT/INSERT/UPDATE/DELETE; only the edge fn's service-role client
-- (which bypasses RLS) writes. Leads are PII and must stay private.
--
-- Upsert semantics (AC4): the edge fn does insert ... on conflict (email) do
-- update, overwriting roles/sports/content_prefs/interest/source with the
-- latest full answer, preserving created_at and setting updated_at = now().
-- (updated_at is set explicitly in the fn's update branch — a column default
-- now() fires on INSERT only.)
--
-- Additive + backwards-compatible; fully idempotent (create-if-not-exists +
-- enable-rls is safe to re-run). Repo house style (cf. GET-191
-- user_content_preferences).

create table if not exists public.waitlist (
  id            uuid primary key default gen_random_uuid(),
  email         text unique not null,          -- upsert / dedupe key
  roles         text[] not null default '{}',  -- subset of {creator,buyer}
  sports        text[] not null default '{}',  -- canonical SPORTS values
  content_prefs text[] not null default '{}',  -- WAITLIST_CONTENT_PREFS labels (§2.1)
  interest      text,                          -- free-text, <=280, sanitized server-side
  source        text not null default 'home-2-copy',  -- which landing surface
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

-- AC6: RLS ON with NO policies => every client role (anon + authenticated) is
-- denied all access; only the service-role edge fn writes. Safe to re-run.
alter table public.waitlist enable row level security;
