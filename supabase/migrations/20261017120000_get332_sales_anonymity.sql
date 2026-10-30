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
--      checkout.session.completed on the Stripe account (RN sessions included —
--      staging rows carry the RN-only metadata.buyer_auth_user_id) and copies
--      the session into stripe_blob. The column has to be right whichever of
--      them writes it (requirements "Shared Supabase DB"). Never cleared once
--      set, and shared between the two rows of one checkout.
--   2. creators_read_own_sales gets AND NOT is_anonymous — the creator's
--      PostgREST read of an anonymous sale (buyer_email, stripe_blob) is gone.
--   3. creator_own_sales() — the caller's sales with ONE row per checkout.
--      Both writers' rows now carry creator_email (the RN webhook's used to be
--      blank, which is the only reason its row was never counted), so every
--      revenue number reads through this.
--   4. creator_sales_ledger(p_offset, p_limit) — the paged revenue table for
--      web + RN, buyer nulled when anonymous, with the total count.
--   5. creator_sales_totals() — per-insyt count + amount, anonymous sales
--      included (they are real revenue; web per-insyt cards read it).
--   6. creator_revenue_stats() (20260608120000) re-reads through (3).
--
-- Additive: no column changes; the old web query keeps working, minus the
-- anonymous rows, until the frontend moves to the RPCs.

-- ============================================================================
-- 1. Stamp is_anonymous at insert
-- ============================================================================
-- A sale is anonymous when the insyt is the delivery of an ANONYMOUS inquiry
-- and the buyer is its requester. While the insyt is private only the
-- requester can buy it (RN purchaseGate, GET-328), so a private delivery's
-- sale is anonymous outright. After the public flip (GET-331) anyone may buy
-- it; then the buyer is the requester when the checkout's auth id is theirs
-- (the rule the RN webhook applies, webhooks/purchase-row.ts) or, for a row
-- without one, when the address is theirs.
create or replace function public.purchases_is_anonymous(
  p_insyt_id text,
  p_buyer_email text,
  p_buyer_auth_user_id text default null
)
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
         or q.requester_auth_user_id::text = p_buyer_auth_user_id
         or exists (
           select 1 from auth.users u
            where u.id = q.requester_auth_user_id
              and lower(u.email) = lower(coalesce(p_buyer_email, ''))
         )
       )
  );
$$;

revoke execute on function public.purchases_is_anonymous(text, text, text) from public, anon, authenticated;

create or replace function public.purchases_before_insert_stamp()
  returns trigger
  language plpgsql
  security definer
  set search_path = public
as $$
begin
  new.is_anonymous := coalesce(new.is_anonymous, false)
    or public.purchases_is_anonymous(
         new.insyt_id,
         new.buyer_email,
         -- n8n's rows carry the checkout's metadata in stripe_blob (= event.data).
         new.stripe_blob -> 'object' -> 'metadata' ->> 'buyer_auth_user_id'
       )
    -- The other writer's row for the same checkout already said so.
    or (coalesce(new.stripe_session_id, '') <> '' and exists (
         select 1 from public.purchases t
          where t.stripe_session_id = new.stripe_session_id and t.is_anonymous
       ));
  -- …and the other way round: the twin written first must not stay readable.
  if new.is_anonymous and coalesce(new.stripe_session_id, '') <> '' then
    update public.purchases
       set is_anonymous = true
     where stripe_session_id = new.stripe_session_id
       and not is_anonymous;
  end if;
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
-- deliveries yet), then their twins.
update public.purchases
   set is_anonymous = true
 where not is_anonymous
   and public.purchases_is_anonymous(
         insyt_id, buyer_email, stripe_blob -> 'object' -> 'metadata' ->> 'buyer_auth_user_id');
update public.purchases p
   set is_anonymous = true
 where not p.is_anonymous
   and coalesce(p.stripe_session_id, '') <> ''
   and exists (select 1 from public.purchases t
                where t.stripe_session_id = p.stripe_session_id and t.is_anonymous);

-- ============================================================================
-- 2. The creator's own-sales policy drops anonymous rows
-- ============================================================================
drop policy if exists creators_read_own_sales on public.purchases;
create policy creators_read_own_sales on public.purchases
  for select
  using (((creator_email)::text = (auth.jwt() ->> 'email')) and not is_anonymous);

-- ============================================================================
-- 3. creator_own_sales — the caller's sales, one row per checkout
-- ============================================================================
-- Two writers → up to two rows per Stripe session. Keep the first-written one;
-- a sale is anonymous if either row says so. A row with no session id is its
-- own sale. Internal: only the definer RPCs below call it.
create or replace function public.creator_own_sales()
  returns table (
    id bigint, insyt_id text, buyer_email text, is_anonymous boolean,
    purchased_at timestamptz, amount_paid bigint
  )
  language sql
  stable
  security definer
  set search_path = public
as $$
  select distinct on (s.k)
         s.id, s.insyt_id, s.buyer_email,
         bool_or(s.is_anonymous) over (partition by s.k),
         s.purchased_at, s.amount_paid
    from (
      select p.*, coalesce(nullif(p.stripe_session_id, ''), 'row:' || p.id::text) as k
        from public.purchases p
       where p.creator_email = auth.jwt() ->> 'email'
    ) s
   order by s.k, s.id;
$$;

revoke execute on function public.creator_own_sales() from public, anon, authenticated;

-- ============================================================================
-- 4. creator_sales_ledger — one page of the caller's sales + the total
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
    select * from public.creator_own_sales()
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
-- 5. creator_sales_totals — per-insyt sales count + amount for the caller
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
  select s.insyt_id, count(*)::int, coalesce(sum(s.amount_paid), 0)::bigint
    from public.creator_own_sales() s
   group by s.insyt_id;
$$;

revoke execute on function public.creator_sales_totals() from public, anon;
grant execute on function public.creator_sales_totals() to authenticated;

-- ============================================================================
-- 6. creator_revenue_stats — the Revenue card, one row per checkout
-- ============================================================================
-- Same signature and subscription half as 20260608120000; the one-time half
-- now counts each checkout once (see 3).
create or replace function public.creator_revenue_stats()
  returns table (
    onetime_cents bigint, onetime_30d_cents bigint, onetime_count int,
    sub_cents bigint, sub_30d_cents bigint
  )
  language sql
  stable
  security definer
  set search_path = public
as $$
  with sales as (select * from public.creator_own_sales())
  select
    (select coalesce(sum(amount_paid), 0)::bigint from sales),
    (select coalesce(sum(amount_paid), 0)::bigint from sales
      where purchased_at >= now() - interval '30 days'),
    (select count(*)::int from sales),
    (select coalesce(sum(amount_cents), 0)::bigint from public.subscription_invoices
      where creator_id = auth.uid() and status = 'paid'),
    (select coalesce(sum(amount_cents), 0)::bigint from public.subscription_invoices
      where creator_id = auth.uid() and status = 'paid'
        and paid_at >= now() - interval '30 days');
$$;

grant execute on function public.creator_revenue_stats() to authenticated;
