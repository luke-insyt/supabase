-- GET-370: inquiry UI review follow-ups (product decisions on the ticket, 2026-11-01).
--
-- 1. "Insyts wanted" becomes an OPTIONAL min–max range, no longer capped at 10.
--    insyts_wanted stays the CAPACITY (= the range's max): null now means
--    unlimited — the inquiry keeps taking proposals until it is closed or
--    expires. insyts_wanted_min is informational only (the requester's hope);
--    nothing gates on it. Ceiling 100 is a sanity bound, not a product cap.
--
--    The capacity RPCs need no rewrite: every gate compares `filled >= insyts_wanted`
--    (inquiry_reevaluate, accept_inquiry_proposal, submit_inquiry_proposal), and a
--    comparison with null is never true, so a null capacity is never full and
--    never auto-completes — exactly "unlimited".
--
-- 2. Proposals no longer ask for a read time or a deliver-by date. Both columns
--    stay (existing rows keep their values) but become nullable. A proposal with
--    no deliver_by has no deadline to be overdue against, so the requester may
--    cancel it once accepted: cancel_inquiry_proposal's `deliver_by >= current_date`
--    guard is null for such rows and lets the cancel through. The RN server's
--    canCancelOverdue mirrors that.
--
-- Additive and backwards-compatible: the current server keeps sending a number
-- and both proposal fields, which still satisfy every constraint.

alter table public.inquiries
  alter column insyts_wanted drop not null,
  alter column insyts_wanted drop default;

alter table public.inquiries drop constraint if exists inquiries_insyts_wanted_check;
alter table public.inquiries
  add constraint inquiries_insyts_wanted_check
    check (insyts_wanted is null or insyts_wanted between 1 and 100);

alter table public.inquiries
  add column if not exists insyts_wanted_min integer
    constraint inquiries_insyts_wanted_min_check
      check (insyts_wanted_min is null or insyts_wanted_min between 1 and 100);

alter table public.inquiries
  add constraint inquiries_insyts_wanted_range
    check (insyts_wanted_min is null or insyts_wanted is null or insyts_wanted_min <= insyts_wanted);

comment on column public.inquiries.insyts_wanted is
  'Capacity = the max of the requester''s range: filled slots never exceed it. Null = unlimited (GET-370).';
comment on column public.inquiries.insyts_wanted_min is
  'Informational min of the requester''s range; nothing gates on it. Null = no minimum (GET-370).';

alter table public.inquiry_proposals
  alter column read_time_min drop not null,
  alter column deliver_by drop not null;
