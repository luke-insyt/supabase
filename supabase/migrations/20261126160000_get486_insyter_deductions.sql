-- GET-486 B3 (S5, feature.md §2.5): the Insyter deductions & holds ledger + payout netting.
--
-- One row per amount GetInsyt deducts from, or holds back from, an Insyter's royalty
-- (Insyter Agreement §5/§11): refund, chargeback, claim, hold, hold_released, correction.
-- Admins record rows now (POST /api/cs/deductions); GET-487 later writes source='stripe' rows
-- through the SAME RPC (feature.md §3.4).
--
--   * Immutable (AC5.4): no delete, no truncate, and the only update is settling a deduction
--     into a payout (settled_payout_id + settled_at, null → value, once). Triggers fire for the
--     service role too. A correction is a new, reversing row.
--   * No FK to users / auth.users (AC5.8): rows are kept unchanged when an account is deleted and
--     never block or cascade that delete. So this table is NOT part of the deletion follow-up
--     trigger (D-9; B2/B4 own that trigger).
--   * No client access: RLS on with no policies, every API grant revoked. The service role can
--     only SELECT; every write goes through the SECURITY DEFINER RPCs below.
--   * Status is derived, never stored (insyter_deductions_for).
--   * create_payout_with_settlement writes the payout, its items and the settlement of the
--     selected deductions in ONE transaction, so a payout never exists half-settled (AC5.5).

-- ============================================================================
-- 1. Table + indexes
-- ============================================================================
create table if not exists public.insyter_deductions (
  id                       uuid primary key default gen_random_uuid(),
  creator_auth_user_id     uuid not null,          -- no FK on purpose (AC5.8)
  kind                     text not null
                           constraint insyter_deductions_kind_check check (kind in
                             ('refund', 'chargeback', 'claim', 'hold', 'hold_released', 'correction')),
  amount_cents             bigint not null
                           constraint insyter_deductions_amount_check check (amount_cents > 0),
  currency                 text not null default 'eur'
                           constraint insyter_deductions_currency_check check (currency = 'eur'),
  insyt_id                 text,                   -- insyts.insyt_id (text key, like purchases.insyt_id)
  purchase_id              bigint references public.purchases (id),
  subscription_invoice_id  uuid,                   -- subscription_invoices.id
  sale_gross_cents         bigint,                 -- reference only (AC5.1a)
  reason                   text not null
                           constraint insyter_deductions_reason_check
                           check (char_length(btrim(reason)) between 1 and 500),
  rule_ref                 text                    -- required for 'claim' (AC5.2)
                           constraint insyter_deductions_rule_ref_len check (char_length(rule_ref) <= 200),
  related_id               uuid references public.insyter_deductions (id),
  source                   text not null default 'admin'
                           constraint insyter_deductions_source_check check (source in ('admin', 'stripe')),
  stripe_ref               text,                   -- GET-487: refund / dispute id
  settled_payout_id        bigint references public.creator_payouts (id),
  settled_at               timestamptz,
  created_by               uuid,                   -- admin auth id; null for source='stripe'
  created_at               timestamptz not null default now(),
  constraint insyter_deductions_claim_rule check (kind <> 'claim' or rule_ref is not null),
  constraint insyter_deductions_related check ((kind in ('hold_released', 'correction')) = (related_id is not null)),
  constraint insyter_deductions_stripe_ref check (source <> 'stripe' or stripe_ref is not null),
  constraint insyter_deductions_settled_pair check ((settled_payout_id is null) = (settled_at is null))
);

comment on table public.insyter_deductions is
  'GET-486 S5: immutable ledger of deductions and holds against an Insyter''s royalty. Written only '
  'through record_insyter_deduction / create_payout_with_settlement (service role). No FK to users: '
  'kept unchanged on account deletion (AC5.8).';

-- One release per hold (AC5.3).
create unique index if not exists insyter_deductions_one_release
  on public.insyter_deductions (related_id) where kind = 'hold_released';
-- GET-487's webhook is idempotent on the Stripe object.
create unique index if not exists insyter_deductions_stripe_once
  on public.insyter_deductions (stripe_ref, kind) where stripe_ref is not null;
-- Admin + GET-487 can't double-count one sale.
create unique index if not exists insyter_deductions_one_per_sale
  on public.insyter_deductions (purchase_id, kind)
  where kind in ('refund', 'chargeback') and purchase_id is not null;
create index if not exists insyter_deductions_creator_idx
  on public.insyter_deductions (creator_auth_user_id, created_at desc);
create index if not exists insyter_deductions_related_idx
  on public.insyter_deductions (related_id) where related_id is not null;

alter table public.insyter_deductions enable row level security;

-- Supabase's default privileges grant ALL on a new public table to every API role.
revoke all on public.insyter_deductions from public, anon, authenticated, service_role;
grant select on public.insyter_deductions to service_role;

-- ============================================================================
-- 2. Immutability (AC5.4)
-- ============================================================================
create or replace function public.insyter_deductions_immutable()
  returns trigger
  language plpgsql
  set search_path = public, pg_temp
as $$
begin
  if tg_op in ('DELETE', 'TRUNCATE') then
    raise exception 'insyter_deductions is immutable: rows can never be deleted (GET-486 AC5.4)'
      using errcode = 'P0001';
  end if;
  -- UPDATE: only the settle-once transition of a settle-able kind. Holds never settle (AC5.5).
  if old.settled_payout_id is null
     and new.settled_payout_id is not null
     and new.settled_at is not null
     and old.kind in ('refund', 'chargeback', 'claim', 'correction')
     and (to_jsonb(new) - 'settled_payout_id' - 'settled_at')
         = (to_jsonb(old) - 'settled_payout_id' - 'settled_at') then
    return new;
  end if;
  raise exception 'insyter_deductions is immutable: the only allowed update is settling an open deduction once (GET-486 AC5.4)'
    using errcode = 'P0001';
end;
$$;

revoke execute on function public.insyter_deductions_immutable() from public, anon, authenticated, service_role;

drop trigger if exists insyter_deductions_immutable_update on public.insyter_deductions;
create trigger insyter_deductions_immutable_update
  before update on public.insyter_deductions
  for each row execute function public.insyter_deductions_immutable();

drop trigger if exists insyter_deductions_no_delete on public.insyter_deductions;
create trigger insyter_deductions_no_delete
  before delete on public.insyter_deductions
  for each row execute function public.insyter_deductions_immutable();

drop trigger if exists insyter_deductions_no_truncate on public.insyter_deductions;
create trigger insyter_deductions_no_truncate
  before truncate on public.insyter_deductions
  for each statement execute function public.insyter_deductions_immutable();

-- ============================================================================
-- 3. record_insyter_deduction — the one write path (admin now, GET-487 'stripe' later)
-- ============================================================================
-- Errors (SQLSTATE P0001, message = the code the server maps):
--   creator_not_found · admin_required · amount_invalid · reason_invalid · rule_ref_required ·
--   one_sale_only · not_owner · insyt_mismatch · related_invalid · related_not_allowed ·
--   release_amount_mismatch · already_released · correction_exceeds · already_recorded
create or replace function public.record_insyter_deduction(
  p_admin      uuid,
  p_creator    uuid,
  p_kind       text,
  p_amount     bigint,
  p_insyt      text,
  p_purchase   bigint,
  p_invoice    uuid,
  p_reason     text,
  p_rule_ref   text,
  p_related    uuid,
  p_source     text default 'admin',
  p_stripe_ref text default null
)
  returns uuid
  language plpgsql
  volatile
  security definer
  set search_path = public, pg_temp
as $$
declare
  v_source   text := coalesce(p_source, 'admin');
  v_reason   text := btrim(coalesce(p_reason, ''));
  v_rule     text := nullif(btrim(coalesce(p_rule_ref, '')), '');
  v_insyt    text := nullif(btrim(coalesce(p_insyt, '')), '');
  v_purchase bigint := p_purchase;
  v_invoice  uuid := p_invoice;
  v_gross    bigint;
  v_p_insyt  text;
  v_target   public.insyter_deductions%rowtype;
  v_used     bigint;
  v_id       uuid;
begin
  if p_creator is null or not exists (select 1 from public.users u where u.auth_user_id = p_creator) then
    raise exception 'creator_not_found' using errcode = 'P0001';
  end if;
  if v_source = 'admin' and p_admin is null then
    raise exception 'admin_required' using errcode = 'P0001';
  end if;
  if p_amount is null or p_amount <= 0 then
    raise exception 'amount_invalid' using errcode = 'P0001';
  end if;
  if char_length(v_reason) not between 1 and 500 then
    raise exception 'reason_invalid' using errcode = 'P0001';
  end if;
  if p_kind = 'claim' and v_rule is null then
    raise exception 'rule_ref_required' using errcode = 'P0001';
  end if;
  if v_purchase is not null and v_invoice is not null then
    raise exception 'one_sale_only' using errcode = 'P0001';
  end if;

  -- Release / correction: the related row decides most of the rest.
  if p_kind in ('hold_released', 'correction') then
    if p_related is null then
      raise exception 'related_invalid' using errcode = 'P0001';
    end if;
    -- Lock the target so two concurrent releases / corrections serialise on it.
    select * into v_target from public.insyter_deductions d where d.id = p_related for update;
    if not found or v_target.creator_auth_user_id <> p_creator then
      raise exception 'related_invalid' using errcode = 'P0001';
    end if;
    if p_kind = 'hold_released' then
      if v_target.kind <> 'hold' then
        raise exception 'related_invalid' using errcode = 'P0001';
      end if;
      if exists (select 1 from public.insyter_deductions r
                  where r.related_id = v_target.id and r.kind = 'hold_released') then
        raise exception 'already_released' using errcode = 'P0001';
      end if;
      if p_amount <> v_target.amount_cents then
        raise exception 'release_amount_mismatch' using errcode = 'P0001';
      end if;
    else
      if v_target.kind not in ('refund', 'chargeback', 'claim') then
        raise exception 'related_invalid' using errcode = 'P0001';
      end if;
      select coalesce(sum(c.amount_cents), 0) into v_used
        from public.insyter_deductions c
       where c.related_id = v_target.id and c.kind = 'correction';
      if p_amount > v_target.amount_cents - v_used then
        raise exception 'correction_exceeds' using errcode = 'P0001';
      end if;
    end if;
    -- The release / correction points at the same Insyt and sale as its target.
    if v_insyt is null and v_purchase is null and v_invoice is null then
      v_insyt := v_target.insyt_id;
      v_purchase := v_target.purchase_id;
      v_invoice := v_target.subscription_invoice_id;
    end if;
  elsif p_related is not null then
    raise exception 'related_not_allowed' using errcode = 'P0001';
  end if;

  -- Ownership: a sale or Insyt must belong to this creator (never trusted from the caller).
  if v_purchase is not null then
    select p.insyt_id, p.amount_paid into v_p_insyt, v_gross
      from public.purchases p where p.id = v_purchase;
    if not found or v_p_insyt is null or not exists (
      select 1 from public.insyts i
       where i.insyt_id = v_p_insyt and i.creator_auth_user_id = p_creator) then
      raise exception 'not_owner' using errcode = 'P0001';
    end if;
    if v_insyt is not null and v_insyt <> v_p_insyt then
      raise exception 'insyt_mismatch' using errcode = 'P0001';
    end if;
    v_insyt := v_p_insyt;
  elsif v_invoice is not null then
    select si.amount_cents into v_gross
      from public.subscription_invoices si
     where si.id = v_invoice and si.creator_id = p_creator;
    if not found then
      raise exception 'not_owner' using errcode = 'P0001';
    end if;
  end if;
  if v_insyt is not null and not exists (
    select 1 from public.insyts i where i.insyt_id = v_insyt and i.creator_auth_user_id = p_creator) then
    raise exception 'not_owner' using errcode = 'P0001';
  end if;

  begin
    insert into public.insyter_deductions (
      creator_auth_user_id, kind, amount_cents, insyt_id, purchase_id, subscription_invoice_id,
      sale_gross_cents, reason, rule_ref, related_id, source, stripe_ref, created_by)
    values (
      p_creator, p_kind, p_amount, v_insyt, v_purchase, v_invoice,
      v_gross, v_reason, v_rule, p_related, v_source, nullif(btrim(coalesce(p_stripe_ref, '')), ''),
      p_admin)
    returning id into v_id;
  exception when unique_violation then
    -- one_per_sale (refund/chargeback twice for one sale), stripe_once (webhook replay), or a
    -- release racing another release of the same hold.
    if p_kind = 'hold_released' then
      raise exception 'already_released' using errcode = 'P0001';
    end if;
    raise exception 'already_recorded' using errcode = 'P0001';
  end;
  return v_id;
end;
$$;

-- ============================================================================
-- 4. insyter_deductions_for — the read (Insyter page + admin), status derived
-- ============================================================================
create or replace function public.insyter_deductions_for(
  p_creator uuid,
  p_limit   integer default 100,
  p_offset  integer default 0
)
  returns table (
    id                      uuid,
    created_at              timestamptz,
    kind                    text,
    amount_cents            bigint,
    currency                text,
    sale_gross_cents        bigint,
    insyt_id                text,
    insyt_title             text,
    purchase_id             bigint,
    subscription_invoice_id uuid,
    related_id              uuid,
    status                  text,
    settled_payout_id       bigint,
    settled_payout_date     timestamptz,
    reason                  text,
    rule_ref                text,
    source                  text,
    total                   bigint
  )
  language sql
  stable
  security definer
  set search_path = public, pg_temp
as $$
  select d.id, d.created_at, d.kind, d.amount_cents, d.currency, d.sale_gross_cents,
         d.insyt_id, t.title::text, d.purchase_id, d.subscription_invoice_id, d.related_id,
         case
           when d.kind = 'hold' then
             case when exists (select 1 from public.insyter_deductions r
                                where r.related_id = d.id and r.kind = 'hold_released')
                  then 'released' else 'held' end
           when d.kind = 'hold_released' then 'released'
           when d.settled_payout_id is not null then 'settled'
           else 'open'
         end,
         d.settled_payout_id, po.paid_at, d.reason, d.rule_ref, d.source,
         count(*) over ()
    from public.insyter_deductions d
    left join public.creator_payouts po on po.id = d.settled_payout_id
    left join lateral (
      select i.title from public.insyts i where i.insyt_id = d.insyt_id order by i.created_at limit 1
    ) t on true
   where d.creator_auth_user_id = p_creator
   order by d.created_at desc, d.id
   limit greatest(coalesce(p_limit, 100), 0)
  offset greatest(coalesce(p_offset, 0), 0);
$$;

-- ============================================================================
-- 5. create_payout_with_settlement — payout + items + settlement in one transaction (AC5.5)
-- ============================================================================
-- p_items: [{source, purchase_id, stripe_payment_id, amount_cents, currency}] — the server has
-- already checked each line belongs to the creator and is uncovered; the unique indexes on
-- creator_payout_items stay the backstop (23505 → the server's 409).
-- Errors: deduction_not_settleable (P0001) when any id isn't an open refund / chargeback / claim /
-- correction of THIS creator. Holds never settle.
create or replace function public.create_payout_with_settlement(
  p_creator       uuid,
  p_amount        bigint,
  p_receipt       text,
  p_paid_by       text,
  p_items         jsonb,
  p_deduction_ids uuid[]
)
  returns bigint
  language plpgsql
  volatile
  security definer
  set search_path = public, pg_temp
as $$
declare
  v_payout bigint;
  v_ids    uuid[] := coalesce(array(select distinct x from unnest(p_deduction_ids) x where x is not null), '{}');
  v_ok     integer;
begin
  insert into public.creator_payouts (creator_auth_user_id, amount_cents, receipt_number, paid_by_email)
  values (p_creator, p_amount, p_receipt, p_paid_by)
  returning id into v_payout;

  insert into public.creator_payout_items (payout_id, source, purchase_id, stripe_payment_id, amount_cents, currency)
  select v_payout, it.source, it.purchase_id, it.stripe_payment_id, it.amount_cents, coalesce(it.currency, 'eur')
    from jsonb_to_recordset(coalesce(p_items, '[]'::jsonb))
      as it(source text, purchase_id bigint, stripe_payment_id text, amount_cents bigint, currency text);

  if cardinality(v_ids) > 0 then
    -- Lock first, so a concurrent payout can't settle the same row in between.
    select count(*) into v_ok
      from (select 1 from public.insyter_deductions d
             where d.id = any (v_ids)
               and d.creator_auth_user_id = p_creator
               and d.settled_payout_id is null
               and d.kind in ('refund', 'chargeback', 'claim', 'correction')
             for update) s;
    if v_ok <> cardinality(v_ids) then
      raise exception 'deduction_not_settleable' using errcode = 'P0001';
    end if;
    update public.insyter_deductions
       set settled_payout_id = v_payout, settled_at = now()
     where id = any (v_ids);
  end if;
  return v_payout;
end;
$$;

-- ============================================================================
-- 6. Grants — service_role only
-- ============================================================================
revoke all on function
  public.record_insyter_deduction(uuid, uuid, text, bigint, text, bigint, uuid, text, text, uuid, text, text),
  public.insyter_deductions_for(uuid, integer, integer),
  public.create_payout_with_settlement(uuid, bigint, text, text, jsonb, uuid[])
  from public, anon, authenticated;
grant execute on function
  public.record_insyter_deduction(uuid, uuid, text, bigint, text, bigint, uuid, text, text, uuid, text, text),
  public.insyter_deductions_for(uuid, integer, integer),
  public.create_payout_with_settlement(uuid, bigint, text, text, jsonb, uuid[])
  to service_role;
