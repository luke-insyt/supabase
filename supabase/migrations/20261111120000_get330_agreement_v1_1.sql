-- GET-330 (GET-318 Inquiries, stage 8) — Creator Agreement v1.1: v1.0 plus the
-- inquiry clauses (fixed price once accepted, exclusivity, the 30-day private
-- window, anonymity of requesters, the unpaid-delivery risk).
--
-- Body:  webflow-app-documentation/terms/creator-agreement-v1.1.html
-- Plan:  webflow-app-documentation/features/inquiries/implementation.md "Stage 8"
-- Pattern: 20260503211914_seed_initial_agreement_version.sql (seed) +
--          20260519180000_repoint_agreement_v1_0_to_bucket.sql (bucket url).
--
-- Legal copy: cleared to ship to staging (Theo, 2026-11-11, GET-365).
-- Re-dated 2026-11-11 to sort after the newest staging migration (was
-- 20261017130000 in supabase#12, 20261019150000 in supabase#19).
--
-- What this does: seeds the v1.1 row, NOT current. Nothing changes for anyone
-- until the row is made current.
--
-- Making v1.1 current means EVERY existing Insyter re-signs (decision: Theo,
-- 2026-10-22; GET-357). That flip is NOT a migration, so it can never ride to
-- prod by accident: it is the one-off prod-ops/agreement-make-current.sql that
-- GET-357 adds, run per project after the body is uploaded to the bucket
-- (become-insyter fetches `url`, and a current row pointing at a missing object
-- breaks onboarding; this migration never uploads anything).
--
-- Idempotent (on conflict do nothing) and additive: no existing row changes.

begin;

-- The url is derived from the v1.0 row, so it lands in the same bucket and
-- folder as v1.0 in whichever project this runs (the repoint migration wrote
-- an absolute storage url) — no project ref is written here.
insert into public.agreement_versions
  (version, title, url, effective_date, is_current, changelog, bucket_path, content_type)
select 'v1.1',
       v10.title,
       replace(v10.url, 'creator-agreement-v1.0.html', 'creator-agreement-v1.1.html'),
       -- provisional; the flip above stamps the real effective date
       current_date,
       false,
       'v1.1 (GET-330): new section 8 "Inquiries" — fixed price once a proposal is '
       'accepted, exclusivity (private forever), the 30-day private window for '
       'non-exclusive inquiries, anonymity of requesters, pay on delivery / '
       'unpaid-delivery risk, cancellation and moderation. Sections 8–11 '
       'renumbered 9–12; no other change.',
       'terms/creator-agreement-v1.1.html',
       'text/html'
  from public.agreement_versions v10
 where v10.version = 'v1.0'
   and v10.url like '%/creator-agreement-v1.0.html'
on conflict (version) do nothing;

do $$
begin
  if not exists (select 1 from public.agreement_versions where version = 'v1.1') then
    raise warning 'GET-330: agreement v1.1 NOT seeded — no v1.0 row with a bucket url '
                  '(…/creator-agreement-v1.0.html) to derive it from. Seed it by hand.';
  end if;
end;
$$;

commit;
