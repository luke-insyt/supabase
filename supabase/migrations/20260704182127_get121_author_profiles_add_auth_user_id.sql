-- GET-121 (SF2) step 1/2 — transitional: add auth_user_id to author_profiles.
--
-- The author_profiles view exposes users.email to anon (GET /rest/v1/author_profiles
-- ?select=email — GDPR/spam PII leak). The fix drops email, but the two frontend
-- callers currently filter by email, so this must land FIRST (additive) to let the
-- frontend re-route onto auth_user_id before email is removed (step 2 drops it).
--
-- CREATE OR REPLACE keeps the existing columns in order and appends auth_user_id, so
-- both the old (email) and new (auth_user_id) frontend work during the transition.
-- The view keeps its existing grants. Additive; no data change.
create or replace view public.author_profiles as
  select email, display_name, bio, auth_user_id
  from public.users;
