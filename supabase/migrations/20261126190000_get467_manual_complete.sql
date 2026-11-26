-- GET-467 — Inquiries: "Mark as complete" (the requester closes an inquiry by hand).
-- Design: webflow-app-documentation/features/inquiries/manual-complete-feature.md §2.
--
--   1. inquiries.closed_by_requester_at — tells a manual close from automatic completion.
--      Null on every existing row; only inquiry_close_by_requester writes it.
--   2. inquiry_delivery_bought(p_insyt, p_requester) — has the requester bought this delivered
--      insyt? Stricter than the email match alone: a purchase made while the insyt was still
--      private counts whatever email Stripe recorded (only the requester can buy a private
--      inquiry insyt), so an email change can never get a bought insyt cancelled and released.
--   3. inquiry_close_by_requester(p_inquiry_id, p_requester) — the close, in one transaction:
--      status → completed; submitted / accepted proposals → cancelled (inquiry_closed);
--      delivered-and-not-bought → cancelled (inquiry_closed_delivered). A final re-check rolls
--      the whole close back (P0467) when a delivery claim committed meanwhile.
--
-- Both functions are SECURITY DEFINER and service_role only (the RN server), like
-- release_inquiry_insyt. Additive: the current server never reads the new column or calls the
-- new functions, so this can be applied ahead of the server deploy.

begin;
set local lock_timeout      = '3s';
set local statement_timeout = '30s';

-- ============================================================================
-- 1. inquiries.closed_by_requester_at
-- ============================================================================
alter table public.inquiries add column if not exists closed_by_requester_at timestamptz;

comment on column public.inquiries.closed_by_requester_at is
  'GET-467: when the requester marked the inquiry as complete by hand (inquiry_close_by_requester). '
  'Null for automatic completion and every other state.';

-- ============================================================================
-- 2. inquiry_delivery_bought — the one "bought" rule (design §2.3).
--    purchases.insyt_id holds the public slug (= insyts.insyt_id).
--    (a) a purchase made while the insyt was private (before released_at), or
--    (b) a purchase under the requester's current email (the existing rule; covers a timed
--        insyt bought after it went public).
-- ============================================================================
create or replace function public.inquiry_delivery_bought(p_insyt uuid, p_requester uuid)
  returns boolean
  language sql
  stable
  security definer
  set search_path = public
as $$
  select exists (
    select 1
      from public.insyts s
      join public.purchases pu on pu.insyt_id = s.insyt_id::text
     where s.id = p_insyt
       and s.insyt_id is not null
       and (
         pu.created_at < coalesce(s.released_at, 'infinity'::timestamptz)
         or lower(pu.buyer_email) = (
              select lower(u.email) from public.users u where u.auth_user_id = p_requester limit 1)
       )
  );
$$;

comment on function public.inquiry_delivery_bought(uuid, uuid) is
  'GET-467: true when the requester bought this delivered inquiry insyt: any purchase made while '
  'it was private, or one under the requester''s email. service_role only.';

revoke execute on function public.inquiry_delivery_bought(uuid, uuid) from public, anon, authenticated;
grant execute on function public.inquiry_delivery_bought(uuid, uuid) to service_role;

-- ============================================================================
-- 3. inquiry_close_by_requester — the close (design §2.2).
--
--    Lock order matches the delivery trigger (insyts_mark_proposal_delivered →
--    inquiry_reevaluate takes proposal, then inquiry): we lock only the inquiry and never take
--    FOR UPDATE on proposals, so a live publish can't deadlock against a close.
--
--    Race: claimDelivery is a plain accepted → delivering UPDATE that never takes the inquiry
--    lock. A claim that commits between the refusal check and the updates is skipped by the
--    `accepted` update under READ COMMITTED and would later deliver onto a closed inquiry. The
--    final `exists (… delivering)` is a new statement, sees that commit, and aborts the whole
--    close with P0467; the server maps it to "A delivery is being published. Try again shortly."
-- ============================================================================
create or replace function public.inquiry_close_by_requester(p_inquiry_id uuid, p_requester uuid)
  returns jsonb
  language plpgsql
  security definer
  set search_path = public
as $$
declare
  v_inq        public.inquiries%rowtype;
  v_delivered  integer;
  v_open       jsonb;
  v_unbought   jsonb;
  v_bought     integer;
begin
  -- 1. Owner check under the inquiry lock.
  select * into v_inq from public.inquiries where id = p_inquiry_id for update;
  if not found or v_inq.requester_auth_user_id is distinct from p_requester then
    return jsonb_build_object('result', 'not_found');
  end if;

  -- 2. Already completed (by hand or automatically): nothing changes.
  if v_inq.status = 'completed' then
    return jsonb_build_object('result', 'already');
  end if;

  -- 3. Refusals.
  if v_inq.status not in ('open', 'in_progress', 'unpublished') or v_inq.moderated_at is not null then
    return jsonb_build_object('result', 'refused', 'reason', 'status');
  end if;

  select count(*) filter (where status = 'delivered')
    into v_delivered
    from public.inquiry_proposals
   where inquiry_id = p_inquiry_id;

  if v_delivered = 0 then
    return jsonb_build_object('result', 'refused', 'reason', 'nothing_delivered');
  end if;

  if exists (select 1 from public.inquiry_proposals
              where inquiry_id = p_inquiry_id and status = 'delivering') then
    return jsonb_build_object('result', 'delivering');
  end if;

  -- 4. The close.
  update public.inquiries
     set status = 'completed', closed_by_requester_at = now()
   where id = p_inquiry_id;

  with c as (
    update public.inquiry_proposals p
       set status = 'cancelled', cancel_reason = 'inquiry_closed'
      from public.inquiry_proposals o
     where p.id = o.id
       and p.inquiry_id = p_inquiry_id
       and p.status in ('submitted', 'accepted')
    returning p.id, p.insyter_auth_user_id, o.status as was, p.insyt_id
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'proposal_id', c.id, 'insyter_auth_user_id', c.insyter_auth_user_id,
           'was', c.was, 'insyt_id', c.insyt_id)), '[]'::jsonb)
    into v_open
    from c;

  with c as (
    update public.inquiry_proposals p
       set status = 'cancelled', cancel_reason = 'inquiry_closed_delivered'
     where p.inquiry_id = p_inquiry_id
       and p.status = 'delivered'
       and not public.inquiry_delivery_bought(p.insyt_id, p_requester)
    returning p.id, p.insyter_auth_user_id, p.insyt_id
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'proposal_id', c.id, 'insyter_auth_user_id', c.insyter_auth_user_id,
           'was', 'delivered', 'insyt_id', c.insyt_id)), '[]'::jsonb)
    into v_unbought
    from c;

  v_bought := v_delivered - jsonb_array_length(v_unbought);

  -- 5. Race re-check: a delivery claimed meanwhile undoes the whole close.
  if exists (select 1 from public.inquiry_proposals
              where inquiry_id = p_inquiry_id and status = 'delivering') then
    raise exception 'GET-467: a delivery is being published on inquiry %', p_inquiry_id
      using errcode = 'P0467';
  end if;

  -- 6. What changed, so the server's releases and emails use exactly these rows.
  return jsonb_build_object(
    'result',    'ok',
    'delivered', v_delivered,
    'bought',    v_bought,
    'cancelled', v_open || v_unbought,
    'wanted',    v_inq.insyts_wanted);
end;
$$;

comment on function public.inquiry_close_by_requester(uuid, uuid) is
  'GET-467: the requester marks the inquiry as complete. One transaction: status completed + '
  'closed_by_requester_at; submitted/accepted → cancelled (inquiry_closed); delivered and not '
  'bought → cancelled (inquiry_closed_delivered). Raises P0467 when a delivery was claimed '
  'meanwhile. service_role only.';

revoke execute on function public.inquiry_close_by_requester(uuid, uuid) from public, anon, authenticated;
grant execute on function public.inquiry_close_by_requester(uuid, uuid) to service_role;

commit;
