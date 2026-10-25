-- GET-318 follow-up — an Insyter can attach one of their own published insyts
-- to a proposal (an example of their work, or a ready answer). The requester
-- sees it on the proposal and can open it.
--
--   * inquiry_proposals.attached_insyt_id — optional; SET NULL if the insyt is
--     deleted, so the proposal survives;
--   * a trigger guards it on every write path (the submit RPC's insert and the
--     server's edit update): it must be the Insyter's own, public, published,
--     visible insyt. The server checks first for a field-level message; this is
--     the authority;
--   * the version trigger counts it as content the requester judges, so an
--     accept made against the old attachment answers `stale` (S5-AC7);
--   * submit_inquiry_proposal takes it as a new trailing DEFAULT NULL argument.
--     The old 8-arg function is dropped in the same transaction; PostgREST
--     resolves a call that omits the defaulted argument to the new one, so a
--     server deployed before this change keeps working.
--
-- Additive otherwise: no existing column or behavior changes while nothing is
-- attached.
begin;

set local lock_timeout      = '3s';
set local statement_timeout = '30s';

alter table public.inquiry_proposals
  add column if not exists attached_insyt_id uuid references public.insyts (id) on delete set null;

comment on column public.inquiry_proposals.attached_insyt_id is
  'GET-318: an insyt the Insyter attached to the proposal — their own, public and published (guarded by inquiry_proposals_check_attached).';

-- The guard. Only runs when the attachment is set or changed.
create or replace function public.inquiry_proposals_check_attached()
  returns trigger
  language plpgsql
  set search_path = public
as $$
begin
  if new.attached_insyt_id is null then
    return new;
  end if;
  if tg_op = 'UPDATE' and new.attached_insyt_id is not distinct from old.attached_insyt_id then
    return new;
  end if;
  if not exists (
    select 1 from public.insyts i
     where i.id = new.attached_insyt_id
       and i.creator_auth_user_id = new.insyter_auth_user_id
       and i.visibility = 'public'
       and coalesce(i.is_hidden, false) = false
       and i.insyt_id is not null
       and coalesce(i.status, '') <> 'draft'
  ) then
    raise exception 'attached insyt must be one of the Insyter''s own published insyts'
      using errcode = 'check_violation';
  end if;
  return new;
end;
$$;

drop trigger if exists inquiry_proposals_check_attached on public.inquiry_proposals;
create trigger inquiry_proposals_check_attached
  before insert or update of attached_insyt_id on public.inquiry_proposals
  for each row execute function public.inquiry_proposals_check_attached();

-- The version trigger, now including the attachment.
create or replace function public.inquiry_proposals_before_update()
  returns trigger
  language plpgsql
  set search_path = public
as $$
begin
  if (new.abstract, new.outline_html, new.read_time_min, new.price_cents, new.deliver_by, new.attached_insyt_id)
     is distinct from
     (old.abstract, old.outline_html, old.read_time_min, old.price_cents, old.deliver_by, old.attached_insyt_id) then
    new.version := old.version + 1;
  else
    new.version := old.version;
  end if;
  new.updated_at := now();
  return new;
end;
$$;

-- submit_inquiry_proposal: same body as 20261015210000, plus the attachment.
drop function if exists public.submit_inquiry_proposal(uuid, uuid, text, text, integer, integer, date, integer);

create or replace function public.submit_inquiry_proposal(
  p_inquiry_id        uuid,
  p_insyter           uuid,
  p_abstract          text,
  p_outline_html      text,
  p_read_time_min     integer,
  p_price_cents       integer,
  p_deliver_by        date,
  p_daily_cap         integer,
  p_attached_insyt_id uuid default null
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

  -- Still an Insyter, right now (S8-AC3) — locked FOR SHARE so a concurrent
  -- demotion queues behind this submit (or this submit behind it).
  perform 1 from public.users where auth_user_id = p_insyter and is_creator for share;
  if not found then
    return jsonb_build_object('result', 'not_insyter');
  end if;

  select * into inq from public.inquiries where id = p_inquiry_id for update;
  if not found then
    return jsonb_build_object('result', 'not_found');
  end if;
  if inq.requester_auth_user_id = p_insyter then
    return jsonb_build_object('result', 'own');
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
    read_time_min, price_cents, deliver_by, terms_accepted_at, attached_insyt_id
  ) values (
    inq.id, p_insyter, p_abstract, p_outline_html,
    p_read_time_min, p_price_cents, p_deliver_by, now(), p_attached_insyt_id
  )
  returning * into prop;

  return jsonb_build_object('result', 'ok', 'proposal', to_jsonb(prop));
end;
$$;

-- Server-only, like the other inquiry RPCs (stage-1 migration, section 12).
revoke execute on function
  public.submit_inquiry_proposal(uuid, uuid, text, text, integer, integer, date, integer, uuid)
  from public, anon, authenticated, service_role;
grant execute on function
  public.submit_inquiry_proposal(uuid, uuid, text, text, integer, integer, date, integer, uuid)
  to service_role;

commit;
