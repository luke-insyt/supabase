-- GET-459 — release_due_open_candidates: the open-mode safety net's selection for the RN
-- server's releaseDue() (the release is written on demand, 2026-11-22).
--
-- Design: webflow-app-documentation/features/inquiries/open-mode-feature.md §2.1, §4.1.
-- Plan:   open-mode-implementation.md "R0 — Supabase".
-- Test:   supabase/tests/get459_release_due_open_candidates_test.ts (PGlite, offline).
-- Mirror: getinsyts-native/db/schema.sql (local-dev approximation).
--
-- An open-mode insyt is due once the requester bought it (normally the Stripe webhook
-- releases it at once; this is the net for a webhook release that failed). The selection must
-- START FROM purchases: taking the first 100 private open insyts and then looking for a
-- purchase starves as soon as 100 or more of them are unbought. A PostgREST embed
-- purchases → insyts!inner isn't possible — the migrations declare no foreign key from
-- purchases.insyt_id (20260503161943_remote_schema.sql), and adding one would have to
-- validate legacy web rows — so the join lives here.
--
-- Additive (one new read-only function, nothing else). Every row it returns is due, and a
-- released row drops out (released_at is null), so leftovers past p_limit go in the next run.
-- The release itself stays release_inquiry_insyt (20261121120000_get459_open_mode.sql step 7).
--
-- Rollback: drop function if exists public.release_due_open_candidates(int);

begin;

create or replace function public.release_due_open_candidates(p_limit int default 100)
  returns table (id uuid, insyt_id text)
  language sql stable security invoker set search_path = public
as $$
  select distinct i.id, i.insyt_id::text
    from public.purchases p
    join public.insyts i            on i.insyt_id = p.insyt_id
    join public.inquiry_proposals r on r.id = i.inquiry_proposal_id
    join public.inquiries q         on q.id = r.inquiry_id
   where i.visibility = 'private'
     and i.released_at is null
     and i.release_price_cents = 0
     and i.status in ('live', 'published')
     and q.access_mode = 'open'
   order by i.id
   limit p_limit;
$$;

comment on function public.release_due_open_candidates(int) is
  'GET-459: private, unreleased, published open-mode inquiry insyts that have a purchase — the '
  'RN server''s releaseDue() releases each through release_inquiry_insyt. Read-only; '
  'service_role only.';

-- Supabase grants every new function in public to the API roles by default: take it back.
revoke execute on function public.release_due_open_candidates(int) from public, anon, authenticated;
grant execute on function public.release_due_open_candidates(int) to service_role;

commit;
