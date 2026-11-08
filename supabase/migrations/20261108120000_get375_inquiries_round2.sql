-- GET-375: Inquiries round 2 — data layer (design: webflow-app-documentation
-- features/inquiries/round-2-feature.md §1, plan: round-2-implementation.md P1).
--
-- Additive only, so the current RN server keeps working against it:
--   1. inquiries.price_mode (range | fixed)                         — R2-S2 / D2
--   2. one-proposal-per-Insyter → per-Insyter cap of N active         — R2-S9
--   3. inquiry_proposals.decline_note + owner_seen_at                 — R2-S10 / R2-S11
--   4. inquiry_proposal_comments                                      — R2-S10 / D8
--   5. submit_inquiry_proposal: 'already' → 'insyter_cap'             — R2-S9
--   6. decline_inquiry_proposal gains p_note (default null, so the
--      server's current 2-argument call still resolves)               — R2-S10
-- The "note required on decline" rule lives in the API, not a table check:
-- a check would fire on every UPDATE of a legacy declined row (e.g. the
-- insyter_auth_user_id ON DELETE SET NULL).

begin;

-- 1. Price mode ---------------------------------------------------------------
alter table public.inquiries
  add column if not exists price_mode text not null default 'range'
    constraint inquiries_price_mode_check check (price_mode in ('range', 'fixed'));

alter table public.inquiries
  add constraint inquiries_fixed_price_equal
    check (price_mode <> 'fixed' or price_min_cents = price_max_cents);

comment on column public.inquiries.price_mode is
  'GET-375: range = min–max; fixed = one amount (stored as min = max).';

-- 2. Several proposals per Insyter -------------------------------------------
alter table public.inquiry_proposals
  drop constraint if exists inquiry_proposals_one_per_insyter;

-- The unique constraint's index went with it; keep the lookup fast.
create index if not exists inquiry_proposals_inquiry_insyter_idx
  on public.inquiry_proposals (inquiry_id, insyter_auth_user_id);

-- 3. Decline note + owner "seen" ---------------------------------------------
alter table public.inquiry_proposals
  add column if not exists decline_note text
    constraint inquiry_proposals_decline_note_check
      check (decline_note is null or char_length(btrim(decline_note)) between 1 and 500),
  add column if not exists owner_seen_at timestamptz;

comment on column public.inquiry_proposals.owner_seen_at is
  'GET-375: first time the inquiry owner opened this proposal; "New" = submitted and null.';

-- 4. Proposal comments (two-way, in-app only — D8) ----------------------------
create table if not exists public.inquiry_proposal_comments (
  id                  uuid primary key default gen_random_uuid(),
  proposal_id         uuid not null references public.inquiry_proposals (id) on delete cascade,
  author_auth_user_id uuid references auth.users (id) on delete set null,
  author_role         text not null check (author_role in ('requester', 'insyter')),
  body                text not null check (char_length(btrim(body)) between 1 and 1000),
  created_at          timestamptz not null default now()
);

create index if not exists inquiry_proposal_comments_proposal_idx
  on public.inquiry_proposal_comments (proposal_id, created_at);

-- Server-only, like every other inquiry table: RLS on, no policies.
alter table public.inquiry_proposal_comments enable row level security;

-- 5. submit_inquiry_proposal — latest body (20261025220000), with the
--    one-ever rule replaced by a per-Insyter cap of N active proposals.
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
  v_mine   integer;
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

  -- E1 — open / in progress, not expired, filled < N (S8-AC1/2).
  select count(*) into v_filled
    from public.inquiry_proposals
   where inquiry_id = inq.id and status in ('accepted', 'delivering', 'delivered');
  if inq.status not in ('open', 'in_progress')
     or (inq.open_until is not null and inq.open_until <= now())
     or v_filled >= inq.insyts_wanted then
    return jsonb_build_object('result', 'not_open');
  end if;

  -- R2-S9 — up to N ACTIVE proposals per Insyter (unlimited N → 100, the
  -- range ceiling). Withdrawn / declined / cancelled ones free their slot.
  -- Counted under the inquiry-row lock taken above, so it's race-safe.
  select count(*) into v_mine
    from public.inquiry_proposals
   where inquiry_id = inq.id
     and insyter_auth_user_id = p_insyter
     and status in ('submitted', 'accepted', 'delivering', 'delivered');
  if v_mine >= coalesce(inq.insyts_wanted, 100) then
    return jsonb_build_object('result', 'insyter_cap');
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

-- 6. decline_inquiry_proposal gains an optional note. Drop the 2-argument
--    signature first so there's no overload; the default keeps the current
--    server's (p_proposal_id, p_requester) call working.
drop function if exists public.decline_inquiry_proposal(uuid, uuid);

create function public.decline_inquiry_proposal(
  p_proposal_id uuid,
  p_requester   uuid,
  p_note        text default null
)
  returns jsonb
  language plpgsql
  security definer
  set search_path = public
as $$
declare
  v_inquiry_id uuid;
  inq          public.inquiries%rowtype;
  prop         public.inquiry_proposals%rowtype;
begin
  select inquiry_id into v_inquiry_id from public.inquiry_proposals where id = p_proposal_id;
  if v_inquiry_id is null then
    return jsonb_build_object('result', 'not_found');
  end if;

  select * into inq from public.inquiries where id = v_inquiry_id for update;
  if not found or p_requester is null or inq.requester_auth_user_id is distinct from p_requester then
    return jsonb_build_object('result', 'not_found');
  end if;

  select * into prop from public.inquiry_proposals where id = p_proposal_id for update;

  if prop.status = 'declined' then
    return jsonb_build_object('result', 'ok', 'proposal', to_jsonb(prop));
  end if;
  if prop.status <> 'submitted' then
    return jsonb_build_object('result', 'not_acceptable', 'reason', 'status', 'proposal', to_jsonb(prop));
  end if;

  update public.inquiry_proposals
     set status = 'declined',
         decided_at = now(),
         decline_note = nullif(btrim(coalesce(p_note, '')), '')
   where id = p_proposal_id
  returning * into prop;

  perform public.inquiry_reevaluate(inq.id);
  return jsonb_build_object('result', 'ok', 'proposal', to_jsonb(prop));
end;
$$;

-- Server-only, exactly as before (stage-1 migration §12): a (re)created
-- function is executable by PUBLIC by default, so lock both down again.
revoke execute on function
  public.submit_inquiry_proposal(uuid, uuid, text, text, integer, integer, date, integer, uuid),
  public.decline_inquiry_proposal(uuid, uuid, text)
  from public, anon, authenticated, service_role;
grant execute on function
  public.submit_inquiry_proposal(uuid, uuid, text, text, integer, integer, date, integer, uuid),
  public.decline_inquiry_proposal(uuid, uuid, text)
  to service_role;

commit;
