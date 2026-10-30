-- GET-327 (GET-318 stage 3) — submit a proposal atomically.
--
-- The RN server used to check E1 / audience / own / the 20-per-24h cap and then
-- insert. Nothing re-checked at insert time, so (gatekeeper finding):
--   * parallel submits at count 19 could all pass the cap (S4-AC6);
--   * a submit racing an archive left a `submitted` proposal on an archived
--     inquiry for good — inquiry_reevaluate never ran on insert (S8-AC5);
--   * a submit racing the is_creator demotion trigger left a proposal from
--     someone who is no longer an Insyter (S8-AC3).
-- This function does every check and the insert in ONE transaction:
--   * the inquiry row is locked (`for update`), the same lock archive /
--     accept / reevaluate take, so the inquiry can't change state underneath;
--   * a per-Insyter advisory lock serialises one Insyter's submits, so the
--     24 h count is exact;
--   * the caller's is_creator is re-read inside the transaction.
-- Additive: a new function only. The server's own pre-checks stay (they give
-- field-level messages); this is the authority.
begin;

create or replace function public.submit_inquiry_proposal(
  p_inquiry_id    uuid,
  p_insyter       uuid,
  p_abstract      text,
  p_outline_html  text,
  p_read_time_min integer,
  p_price_cents   integer,
  p_deliver_by    date,
  p_daily_cap     integer
)
  returns jsonb
  language plpgsql
  security definer
  set search_path = public
as $$
declare
  inq      public.inquiries%rowtype;
  prop     public.inquiry_proposals%rowtype;
  v_filled integer;
  v_recent integer;
begin
  if p_insyter is null then
    return jsonb_build_object('result', 'not_found');
  end if;

  select * into inq from public.inquiries where id = p_inquiry_id for update;
  if not found then
    return jsonb_build_object('result', 'not_found');
  end if;
  if inq.requester_auth_user_id = p_insyter then
    return jsonb_build_object('result', 'own');
  end if;

  -- Still an Insyter, right now (S8-AC3).
  if not exists (select 1 from public.users where auth_user_id = p_insyter and is_creator) then
    return jsonb_build_object('result', 'not_insyter');
  end if;

  -- Audience: a targeted inquiry is invisible to non-targets (S3-AC2).
  if inq.audience = 'specific' and not exists (
    select 1 from public.inquiry_targets
     where inquiry_id = inq.id and creator_auth_user_id = p_insyter
  ) then
    return jsonb_build_object('result', 'not_found');
  end if;

  -- One proposal per inquiry, ever (S4-AC2). The unique constraint is the
  -- backstop; answering here keeps the error a clean 409.
  if exists (
    select 1 from public.inquiry_proposals
     where inquiry_id = inq.id and insyter_auth_user_id = p_insyter
  ) then
    return jsonb_build_object('result', 'already');
  end if;

  -- E1 — open / in progress, not expired, filled < N (S8-AC1/2).
  select count(*) into v_filled
    from public.inquiry_proposals
   where inquiry_id = inq.id and status in ('accepted', 'delivering', 'delivered');
  if inq.status not in ('open', 'in_progress')
     or (inq.open_until is not null and inq.open_until <= now())
     or v_filled >= inq.insyts_wanted then
    return jsonb_build_object('result', 'not_open');
  end if;

  -- S4-AC6 — the cap, counted under a per-Insyter lock so parallel submits
  -- queue instead of all reading the same count.
  perform pg_advisory_xact_lock(hashtext('inquiry_proposals:' || p_insyter::text));
  select count(*) into v_recent
    from public.inquiry_proposals
   where insyter_auth_user_id = p_insyter
     and created_at > now() - interval '24 hours';
  if v_recent >= p_daily_cap then
    return jsonb_build_object('result', 'cap');
  end if;

  insert into public.inquiry_proposals (
    inquiry_id, insyter_auth_user_id, abstract, outline_html,
    read_time_min, price_cents, deliver_by, terms_accepted_at
  ) values (
    inq.id, p_insyter, p_abstract, p_outline_html,
    p_read_time_min, p_price_cents, p_deliver_by, now()
  )
  returning * into prop;

  return jsonb_build_object('result', 'ok', 'proposal', to_jsonb(prop));
end;
$$;

-- Server-only, like the other inquiry RPCs (stage-1 migration, section 12).
revoke execute on function
  public.submit_inquiry_proposal(uuid, uuid, text, text, integer, integer, date, integer)
  from public, anon, authenticated, service_role;
grant execute on function
  public.submit_inquiry_proposal(uuid, uuid, text, text, integer, integer, date, integer)
  to service_role;

commit;
