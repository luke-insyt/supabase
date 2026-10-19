-- GET-330 (GET-318 Inquiries, stage 8) — Creator Agreement v1.1: v1.0 plus the
-- inquiry clauses (fixed price once accepted, exclusivity, the 30-day private
-- window, anonymity of requesters, the unpaid-delivery risk).
--
-- Body:  webflow-app-documentation/terms/creator-agreement-v1.1.html
-- Plan:  webflow-app-documentation/features/inquiries/implementation.md "Stage 8"
-- Pattern: 20260503211914_seed_initial_agreement_version.sql (seed) +
--          20260519180000_repoint_agreement_v1_0_to_bucket.sql (bucket url).
--
-- ⚠️ The legal copy is NOT signed off yet (see the body's header comment).
--
-- What this does: seeds the v1.1 row, NOT current. Nothing changes for anyone
-- until the row is made current (below):
--   * become-insyter (web src/become-insyter.ts, RN become-insyter.tsx) and
--     create-insyt (web src/create-insyt-native.ts, RN create-insyt.tsx) keep
--     comparing users.agreement_version with the CURRENT row, so existing
--     Insyters are not re-prompted;
--   * the RN proposal form's terms tick links whatever row is current
--     (GET /api/agreement/current) — v1.0 until the flip, v1.1 after it.
--
-- Why not current here:
--   1. The body must be in the bucket first — become-insyter fetches `url`, and
--      a current row pointing at a missing object breaks onboarding. This
--      migration never uploads anything.
--   2. Making it current re-prompts EVERY existing Insyter to re-sign on web and
--      RN (both gate on agreement_version = the current version). The default
--      decision for GET-330 is the opposite — existing Insyters do NOT re-accept;
--      ticking the proposal checkbox covers the inquiry clauses — so the flip
--      waits for legal sign-off AND for that decision to be settled (either
--      accept the re-prompt, or teach both clients a "no re-accept" version
--      first).
--
-- The flip, once (1) and (2) are done — one statement, so there is never a
-- moment with two current rows (GET /api/agreement/current reads .maybeSingle()
-- and would 500), and a no-op unless the body is really in the bucket:
--
--   update public.agreement_versions
--      set is_current     = (version = 'v1.1'),
--          effective_date = case when version = 'v1.1' then current_date else effective_date end
--    where (is_current or version = 'v1.1')
--      and exists (select 1 from storage.objects
--                   where bucket_id = 'creator-agreements'
--                     and name = 'terms/creator-agreement-v1.1.html');
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
