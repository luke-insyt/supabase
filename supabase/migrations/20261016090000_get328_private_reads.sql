-- GET-328 (GET-318 stage 4) — private insyts: the definer readers + delivery.
--
-- Stage 1 (20261012152621) added insyts.visibility / private_until /
-- inquiry_proposal_id and the RESTRICTIVE `visibility = 'public'` policy for
-- anon/authenticated. SECURITY DEFINER functions bypass that policy, so the two
-- that list insyts to users must filter private rows themselves (feature §3.2,
-- implementation stage 4):
--   * get_trending_insyts — the "Trending Insyts" rail (web + RN);
--   * my_viewed_insyts    — the consumer "Viewed insyts" grid.
-- (creator_content_stats is author-scoped counts only — an author's own
-- private insyts may count there.)
--
-- And the delivery handover (feature §3.5 step 3): when the final insyts row
-- carrying inquiry_proposal_id lands, the proposal becomes `delivered`.
--
-- Additive / replace-only; no-ops while no insyt is private.
begin;

-- 1. Trending rail: public only.
create or replace function public.get_trending_insyts(p_limit int default 5)
  returns table (
    insyt_id              text,
    title                 text,
    creator_display_name  text,
    creator_auth_user_id  text,
    thumbnail_url         text,
    view_count            integer,
    recent_views          bigint
  )
  language sql
  stable
  security definer
  set search_path = public
as $$
  select i.insyt_id::text,
         i.title::text,
         i.creator_display_name::text,
         i.creator_auth_user_id::text,
         i.thumbnail_url::text,
         coalesce(i.view_count, 0),
         count(v.user_id) as recent_views
  from public.insyts i
  left join public.insyt_views v
    on v.insyt_id = i.id
   and v.last_viewed_at >= now() - interval '7 days'
  where i.status in ('live', 'published')
    and i.is_hidden = false
    and i.visibility = 'public'
  group by i.id
  order by count(v.user_id) desc, coalesce(i.view_count, 0) desc, i.created_at desc
  limit greatest(coalesce(p_limit, 5), 0);
$$;

-- 2. Viewed grid: public only — even the requester's own private delivery
--    stays out of a listing (it lives in My purchases on RN, S7-AC1).
create or replace function public.my_viewed_insyts(
    p_limit int default 24, p_offset int default 0)
  returns table (
    insyt_id             text,
    title                text,
    creator_display_name text,
    thumbnail_url        text,
    price_eur            int,
    last_viewed_at       timestamptz
  )
  language sql
  stable
  security definer
  set search_path = public
as $$
  select i.insyt_id::text,
         i.title::text,
         i.creator_display_name::text,
         i.thumbnail_url::text,
         coalesce(i.price_eur, 0),
         v.last_viewed_at
  from public.insyt_views v
  join public.insyts i on i.id = v.insyt_id
  where v.user_id = auth.uid()
    and i.visibility = 'public'
  order by v.last_viewed_at desc
  limit greatest(coalesce(p_limit, 24), 0)
  offset greatest(coalesce(p_offset, 0), 0);
$$;

-- 3. Delivery handover (S6-AC2). The unique partial index on
--    insyts.inquiry_proposal_id already makes a second insyt per proposal
--    impossible; this marks the proposal delivered the moment its insyt is
--    PUBLISHED (status live/published), whatever wrote it (the n8n pipeline,
--    a later update, a lost callback), then re-evaluates the inquiry
--    (completed at N delivered, D1′). A draft carrying the id (the Insyter's
--    work in progress, S6-AC1) does not count.
--    `accepted` is accepted too: a lost claim must not strand a delivered
--    insyt. Any other status (cancelled / declined / withdrawn) is left alone.
create or replace function public.insyts_mark_proposal_delivered()
  returns trigger
  language plpgsql
  security definer
  set search_path = public
as $$
declare
  v_inquiry_id uuid;
begin
  if new.inquiry_proposal_id is null or new.status not in ('live', 'published') then
    return new;
  end if;
  if tg_op = 'UPDATE'
     and old.inquiry_proposal_id is not distinct from new.inquiry_proposal_id
     and old.status in ('live', 'published') then
    return new;
  end if;

  update public.inquiry_proposals
     set status           = 'delivered',
         insyt_id         = new.id,
         error            = null,
         delivering_since = null
   where id = new.inquiry_proposal_id
     and status in ('delivering', 'accepted')
  returning inquiry_id into v_inquiry_id;

  if v_inquiry_id is not null then
    perform public.inquiry_reevaluate(v_inquiry_id);
  end if;
  return new;
end;
$$;

revoke execute on function public.insyts_mark_proposal_delivered() from public, anon, authenticated, service_role;

drop trigger if exists insyts_mark_proposal_delivered on public.insyts;
create trigger insyts_mark_proposal_delivered
  after insert or update of inquiry_proposal_id, status on public.insyts
  for each row execute function public.insyts_mark_proposal_delivered();

commit;
