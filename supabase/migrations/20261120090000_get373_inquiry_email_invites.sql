-- GET-373 — Inquiries: invite people by email.
-- Spec: webflow-app-documentation/features/inquiry-email-invites/{requirements,feature,implementation}.md
--
-- Additive only:
--   1. table public.inquiry_email_invites (server-only, like inquiry_targets)
--   2. inquiry_targets_cap() now counts targets + pending email invites (DD2)
--   3. RPC add_inquiry_email_invites   — locked check-then-insert (total, daily cap, dupes)
--   4. RPC claim_inquiry_email_invite  — locked invited→joined flip + target insert
-- All three functions take the same inquiry-row lock, so the "≤ 10 invitees" invariant
-- can't be raced by concurrent adds, target edits or claims. The per-requester daily cap is
-- serialised separately with a transaction advisory lock keyed on the requester.
--
-- 🚨 EXPLICIT TRANSACTION (same rule as get318): our deploy path doesn't wrap a file, and a
-- half-applied file would leave the definer RPCs callable before the EXECUTE revoke at the end.

begin;
set local lock_timeout = '3s';
set local statement_timeout = '30s';

-- ============================================================================
-- 1. inquiry_email_invites
-- ============================================================================
create table public.inquiry_email_invites (
  id                     uuid primary key default gen_random_uuid(),
  inquiry_id             uuid not null references public.inquiries (id) on delete cascade,
  -- S5-AC5: deleting the requester's account takes their invites with it.
  requester_auth_user_id uuid not null references auth.users (id) on delete cascade,
  -- Stored trimmed + lower-cased; null once erased by the retention sweep.
  email                  text,
  status                 text not null default 'invited'
                           check (status in ('invited', 'joined', 'revoked', 'expired')),
  -- Stamped BEFORE the send, so a staging-held send still counts as emailed (S2-AC4).
  emailed_at             timestamptz,
  claimed_by             uuid references auth.users (id) on delete set null,
  claimed_at             timestamptz,
  revoked_at             timestamptz,
  expired_at             timestamptz,
  -- inquiries has no closed-at column and its updated_at moves on every write, so the
  -- sweep stamps the first time it sees the inquiry terminal; that starts the 30-day clock.
  inquiry_closed_at      timestamptz,
  erased_at              timestamptz,
  created_at             timestamptz not null default now(),
  -- Same shape the server's normalizeInviteEmail enforces: one @, no whitespace or commas.
  constraint inquiry_email_invites_email_shape
    check (email is null or (email = lower(email) and email ~ '^[^@\s,]+@[^@\s,]+$'))
);

-- One live invite per address per inquiry; a revoked/expired address can be invited again.
create unique index inquiry_email_invites_live_uq
  on public.inquiry_email_invites (inquiry_id, email)
  where status in ('invited', 'joined');

-- Claim + sweep lookups by address.
create index inquiry_email_invites_match_idx
  on public.inquiry_email_invites (email)
  where status = 'invited';

-- The per-requester rolling 24 h cap.
create index inquiry_email_invites_requester_idx
  on public.inquiry_email_invites (requester_auth_user_id, created_at);

-- Server-only: third-party addresses must be unreachable from a browser key (S1-AC6).
alter table public.inquiry_email_invites enable row level security;
revoke all on public.inquiry_email_invites from anon, authenticated;

-- ============================================================================
-- 2. inquiry_targets_cap: targets + pending email invites ≤ 10 (DD2)
--    A claim flips its invite to 'joined' BEFORE inserting the target, so a claim
--    swaps one counted row for another and is never refused here.
-- ============================================================================
create or replace function public.inquiry_targets_cap()
  returns trigger
  language plpgsql
  security definer
  set search_path = public
as $$
declare
  n integer;
begin
  perform 1 from public.inquiries where id = new.inquiry_id for update;
  select (select count(*)
            from public.inquiry_targets
           where inquiry_id = new.inquiry_id
             and creator_auth_user_id is distinct from new.creator_auth_user_id)
       + (select count(*)
            from public.inquiry_email_invites
           where inquiry_id = new.inquiry_id
             and status = 'invited')
    into n;
  if n >= 10 then
    raise exception 'invitee_total'
      using errcode = 'check_violation',
            detail  = 'an inquiry can have at most 10 invitees (picked Insyters + pending email invites)';
  end if;
  return new;
end;
$$;

-- ============================================================================
-- 3. add_inquiry_email_invites
--    Returns {ok:true, rows:[...]} or
--    {refused:'not_found'|'audience'|'empty'|'malformed'|'self'|'dupes'|'total'|'cap', ...}.
--    The caller (RN server) has already normalised the addresses; this re-normalises defensively.
-- ============================================================================
create or replace function public.add_inquiry_email_invites(
  p_inquiry   uuid,
  p_requester uuid,
  p_emails    text[],
  p_now       timestamptz default now()
)
  returns jsonb
  language plpgsql
  security definer
  set search_path = public
as $$
declare
  v_audience text;
  v_owner    uuid;
  v_self     text;
  v_emails   text[];
  v_dupes    text[];
  v_targets  integer;
  v_invited  integer;
  v_daily    integer;
  v_oldest   timestamptz;
  v_rows     jsonb;
begin
  -- Serialise this requester's adds across ALL their inquiries, so parallel requests on
  -- different inquiries can't each see the same 24 h count (S1-AC5). Taken before the
  -- inquiry lock; no other path takes this key, so there is no lock-order cycle.
  perform pg_advisory_xact_lock(hashtextextended('get373_invite_cap:' || coalesce(p_requester::text, ''), 0));

  select audience, requester_auth_user_id
    into v_audience, v_owner
    from public.inquiries
   where id = p_inquiry
     for update;
  if not found or v_owner is distinct from p_requester then
    return jsonb_build_object('refused', 'not_found');
  end if;
  if v_audience <> 'specific' then
    return jsonb_build_object('refused', 'audience');
  end if;

  select array_agg(distinct lower(btrim(e, E' \t\r\n')))
    into v_emails
    from unnest(p_emails) as e
   where btrim(coalesce(e, ''), E' \t\r\n') <> '';
  if v_emails is null then
    return jsonb_build_object('refused', 'empty');
  end if;
  if exists (select 1 from unnest(v_emails) as e where e !~ '^[^@\s,]+@[^@\s,]+$') then
    return jsonb_build_object('refused', 'malformed');
  end if;

  select lower(btrim(email)) into v_self from auth.users where id = p_requester;
  if v_self is not null and v_self = any (v_emails) then
    return jsonb_build_object('refused', 'self');
  end if;

  select array_agg(email)
    into v_dupes
    from public.inquiry_email_invites
   where inquiry_id = p_inquiry
     and status in ('invited', 'joined')
     and email = any (v_emails);
  if v_dupes is not null then
    return jsonb_build_object('refused', 'dupes', 'dupes', to_jsonb(v_dupes));
  end if;

  select count(*) into v_targets from public.inquiry_targets where inquiry_id = p_inquiry;
  select count(*) into v_invited
    from public.inquiry_email_invites
   where inquiry_id = p_inquiry and status = 'invited';
  if v_targets + v_invited + cardinality(v_emails) > 10 then
    return jsonb_build_object('refused', 'total');
  end if;

  -- Rolling 24 h budget per requester, across all their inquiries (D4).
  select count(*), min(created_at)
    into v_daily, v_oldest
    from public.inquiry_email_invites
   where requester_auth_user_id = p_requester
     and created_at > p_now - interval '24 hours';
  if v_daily + cardinality(v_emails) > 20 then
    return jsonb_build_object('refused', 'cap', 'cap_oldest_at', v_oldest);
  end if;

  with ins as (
    insert into public.inquiry_email_invites (inquiry_id, requester_auth_user_id, email, created_at)
    select p_inquiry, p_requester, e, p_now from unnest(v_emails) as e
    returning id, email, status, created_at
  )
  select coalesce(jsonb_agg(to_jsonb(ins)), '[]'::jsonb) into v_rows from ins;

  return jsonb_build_object('ok', true, 'rows', v_rows);
end;
$$;

-- ============================================================================
-- 4. claim_inquiry_email_invite
--    The RN server has already proved the caller's CONFIRMED auth email matches and that
--    the caller is an Insyter; this does the atomic part under the inquiry lock.
-- ============================================================================
create or replace function public.claim_inquiry_email_invite(
  p_invite uuid,
  p_user   uuid
)
  returns jsonb
  language plpgsql
  security definer
  set search_path = public
as $$
declare
  v_inquiry   uuid;
  v_owner     uuid;
  v_status    text;
  v_moderated timestamptz;
  v_flipped   integer;
begin
  if p_user is null then
    return jsonb_build_object('claimed', false);
  end if;

  select i.inquiry_id into v_inquiry
    from public.inquiry_email_invites i
   where i.id = p_invite;
  if not found then
    return jsonb_build_object('claimed', false);
  end if;

  select requester_auth_user_id, status, moderated_at
    into v_owner, v_status, v_moderated
    from public.inquiries
   where id = v_inquiry
     for update;
  -- S4-AC5: never the requester. S4-AC1: a closed inquiry's invites are expired, not
  -- claimable, even in the window before the sweep stamps them.
  if v_owner is not distinct from p_user
     or v_status in ('completed', 'archived')
     or v_moderated is not null then
    return jsonb_build_object('claimed', false);
  end if;

  update public.inquiry_email_invites
     set status = 'joined', claimed_by = p_user, claimed_at = now()
   where id = p_invite and status = 'invited';
  get diagnostics v_flipped = row_count;
  if v_flipped = 0 then
    return jsonb_build_object('claimed', false);
  end if;

  -- Already a picked target → no second row (S4-AC4).
  insert into public.inquiry_targets (inquiry_id, creator_auth_user_id)
  values (v_inquiry, p_user)
  on conflict do nothing;

  return jsonb_build_object('claimed', true, 'inquiry_id', v_inquiry);
end;
$$;

-- ============================================================================
-- 5. EXECUTE: service_role only (the RN server). Same pattern as get318 §14.
-- ============================================================================
revoke execute on function
  public.inquiry_targets_cap(),
  public.add_inquiry_email_invites(uuid, uuid, text[], timestamptz),
  public.claim_inquiry_email_invite(uuid, uuid)
  from public, anon, authenticated;

grant execute on function
  public.add_inquiry_email_invites(uuid, uuid, text[], timestamptz),
  public.claim_inquiry_email_invite(uuid, uuid)
  to service_role;

commit;
