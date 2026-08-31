-- GET-190 follow-up — restore the SELECT grant on insyts.search_vector.
--
-- SYMPTOM (Lukas, 2026-08-31): typing anything in the /insyts free-text search
-- returned "Something went wrong." on the Webflow feed and an error on the RN
-- feed. Every free-text search was dead, not just the new-tag case he reported.
--
-- CAUSE: GET-116 (20260704124405) ran
--     revoke select (body_html, video_url) on public.insyts from anon, authenticated;
-- A column-level REVOKE converts the table-wide SELECT grant into a per-column
-- grant for every OTHER column. From that point on, a column ADDED to insyts has
-- no grant at all. 20260827120200 had to DROP and re-ADD search_vector (a
-- generated column's expression cannot be ALTERed), so the re-added column came
-- back ungranted and any query REFERENCING it — even one that does not select it,
-- like `search_vector=fts(simple).foo:*` — fails with
--     42501 permission denied for table insyts
-- which the feed surfaces as its generic error state.
--
-- FIX: grant SELECT on that one column back to the two API roles. This restores
-- exactly what the column had before 20260827120200 dropped it; body_html and
-- video_url stay revoked, so the GET-116 paywall is untouched.
--
-- Idempotent (GRANT is), additive, and safe to run ahead of any frontend deploy.

grant select (search_vector) on public.insyts to anon, authenticated;

comment on column public.insyts.search_vector is
  'GIN-indexed tsvector for the /insyts feed search. Weights: A=title, '
  'B=creator_display_name+abstract, C=sport+content_type+tags. '
  'GET-190 follow-up: insyts carries COLUMN-level grants (since GET-116 revoked '
  'body_html/video_url), so any migration that adds or re-adds a column here MUST '
  'also grant select on it to anon, authenticated — otherwise every query that '
  'references the column fails with 42501.';
