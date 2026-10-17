-- GET-332 (GET-318 Inquiries stage 6) · anonymity hardening at purchase.
-- Spec: webflow-app-documentation/features/inquiries/feature.md §3.2 / §3.3,
-- implementation.md "Stage 6". Satisfies S2-AC7 + S6-AC3: the Insyter sees the
-- sale of an anonymous inquiry's delivery in their revenue, but never who
-- bought it.
--
--   1. purchases_is_anonymous() + a BEFORE INSERT trigger stamp
--      purchases.is_anonymous (column added in 20261012152621) and backfill a
--      blank creator_email. A trigger, not only the RN webhook: TWO writers
--      insert purchase rows — the RN Stripe webhook AND the n8n
--      "Purchase Completed" workflow, which listens to every
--      checkout.session.completed on the Stripe account (RN sessions included)
--      and copies the full Stripe session into stripe_blob. The column has to
--      be right whichever of them writes it (requirements "Shared Supabase DB").
--      The webhook may stamp true itself; the trigger only ever adds, never
--      clears.
--   2. creators_read_own_sales gets AND NOT is_anonymous — the creator's
--      PostgREST read of an anonymous sale (buyer_email, stripe_blob) is gone.
--   3. creator_sales_ledger(p_offset, p_limit) — the paged revenue table for
--      web + RN, buyer nulled when anonymous, with the total count.
--   4. creator_sales_totals() — per-insyt count + amount, anonymous sales
--      included (they are real revenue; web per-insyt cards read it).
--
-- Additive: no column changes; the old web query keeps working, minus the
-- anonymous rows, until the frontend moves to the RPCs.

-- ============================================================================
-- 1. Stamp is_anonymous at insert
-- ============================================================================
-- A sale is anonymous when the insyt is the delivery of an ANONYMOUS inquiry
-- and the buyer is its requester. While the insyt is private only the
-- requester can buy it (RN purchaseGate, GET-328), so a private delivery's
-- sale is anonymous outright — this also covers a requester who typed another
-- address at Stripe checkout. After the public flip (GET-331) anyone may buy
-- it; then only the requester's own address marks it.
create or replace function public.purchases_is_anonymous(p_insyt_id text, p_buyer_email text)
  returns boolean
  language sql
  stable
  security definer
  set search_path = public
as $$
  select exists (
    select 1
      from public.insyts i
      join public.inquiry_proposals p on p.id = i.inquiry_proposal_id
      join public.inquiries q on q.id = p.inquiry_id
     where i.insyt_id = p_insyt_id
       and q.is_anonymous
       and (
         i.visibility = 'private'
         or exists (
           select 1 from auth.users u
            where u.id = q.requester_auth_user_id
              and lower(u.email) = lower(coalesce(p_buyer_email, ''))
         )
       )
  );
$$;

revoke execute on function public.purchases_is_anonymous(text, text) from public, anon, authenticated;

create or replace function public.purchases_before_insert_stamp()
  returns trigger
  language plpgsql
  security definer
  set search_path = public
as $$
begin
  new.is_anonymous := coalesce(new.is_anonymous, false)
                      or public.purchases_is_anonymous(new.insyt_id, new.buyer_email);
  -- Revenue is keyed on creator_email; a row without it is invisible to its
  -- creator (the RN webhook used to leave it blank).
  if coalesce(new.creator_email, '') = '' then
    new.creator_email := (
      select i.creator_email from public.insyts i
       where i.insyt_id = new.insyt_id and coalesce(i.creator_email, '') <> ''
       limit 1
    );
  end if;
  return new;
end;
$$;

revoke execute on function public.purchases_before_insert_stamp() from public, anon, authenticated, service_role;

drop trigger if exists purchases_before_insert_stamp on public.purchases;
create trigger purchases_before_insert_stamp
  before insert on public.purchases
  for each row execute function public.purchases_before_insert_stamp();

-- Rows written before this migration (staging fixtures; prod has no inquiry
-- deliveries yet).
update public.purchases
   set is_anonymous = true
 where not is_anonymous
   and public.purchases_is_anonymous(insyt_id, buyer_email);

-- ============================================================================
-- 2. The creator's own-sales policy drops anonymous rows
-- ============================================================================
drop policy if exists creators_read_own_sales on public.purchases;
create policy creators_read_own_sales on public.purchases
  for select
  using (((creator_email)::text = (auth.jwt() ->> 'email')) and not is_anonymous);

-- ============================================================================
-- 3. creator_sales_ledger — one page of the caller's sales + the total
-- ============================================================================
-- Drop-in for the web's paged `.range()` + count:'exact' read
-- (webflow-code src/my-insyts.ts loadOneTimePage) and RN getRevenue. Returns
-- { total, rows: [{ insyt_id, insyt_title, is_private, buyer_email,
-- is_anonymous, purchased_at, amount_paid }] }; buyer_email is null when
-- anonymous. jsonb, so a page past the end still carries the total. The title
-- comes from here because a private insyt is invisible to its own author's
-- PostgREST read (restrictive policy, GET-328) — and is_private tells the web
-- not to link it. Page size is clamped to 1..100.
create or replace function public.creator_sales_ledger(p_offset int default 0, p_limit int default 10)
  returns jsonb
  language sql
  stable
  security definer
  set search_path = public
as $$
  with mine as (
    select p.id, p.insyt_id, p.buyer_email, p.is_anonymous, p.purchased_at, p.amount_paid
      from public.purchases p
     where p.creator_email = auth.jwt() ->> 'email'
  ),
  page as (
    select m.*
      from mine m
     order by m.purchased_at desc nulls last, m.id desc
    offset greatest(coalesce(p_offset, 0), 0)
     limit least(greatest(coalesce(p_limit, 10), 1), 100)
  )
  select jsonb_build_object(
    'total', (select count(*) from mine),
    'rows', coalesce((
      select jsonb_agg(jsonb_build_object(
               'insyt_id', pg.insyt_id,
               'insyt_title', i.title,
               'is_private', coalesce(i.visibility = 'private', false),
               'buyer_email', case when pg.is_anonymous then null else pg.buyer_email end,
               'is_anonymous', pg.is_anonymous,
               'purchased_at', pg.purchased_at,
               'amount_paid', pg.amount_paid
             ) order by pg.purchased_at desc nulls last, pg.id desc)
        from page pg
        left join lateral (
          select x.title, x.visibility from public.insyts x
           where x.insyt_id = pg.insyt_id
           limit 1
        ) i on true
    ), '[]'::jsonb)
  );
$$;

revoke execute on function public.creator_sales_ledger(int, int) from public, anon;
grant execute on function public.creator_sales_ledger(int, int) to authenticated;

-- ============================================================================
-- 4. creator_sales_totals — per-insyt sales count + amount for the caller
-- ============================================================================
-- Web per-insyt cards (src/my-insyts.ts loadInsytsData) read purchases under
-- creators_read_own_sales, which now omits anonymous sales; this keeps them in
-- the numbers without exposing a row.
create or replace function public.creator_sales_totals()
  returns table (insyt_id text, sales_count int, amount_cents bigint)
  language sql
  stable
  security definer
  set search_path = public
as $$
  select p.insyt_id::text, count(*)::int, coalesce(sum(p.amount_paid), 0)::bigint
    from public.purchases p
   where p.creator_email = auth.jwt() ->> 'email'
   group by p.insyt_id;
$$;

revoke execute on function public.creator_sales_totals() from public, anon;
grant execute on function public.creator_sales_totals() to authenticated;
