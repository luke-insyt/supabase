-- GET-360 follow-up (gatekeeper finding): an end user could call
-- touch_user_activity with p_source 'app' from the browser and land in the app
-- WAU. Only the RN API server (service role) records 'app'; any end-user call
-- is web by definition, so the source is forced rather than trusted.
create or replace function public.touch_user_activity(
  p_source text,
  p_user_id uuid default null
)
  returns void
  language plpgsql
  security definer
  set search_path = public
as $$
declare
  v_service boolean := auth.role() = 'service_role';
  v_user uuid := case when v_service then p_user_id else auth.uid() end;
  v_source text := case when v_service then p_source else 'web' end;
begin
  if v_user is null then
    return;
  end if;
  if v_source not in ('web', 'app') then
    raise exception 'invalid source %', v_source using errcode = '22023';
  end if;

  insert into public.user_activity_days (user_id, day, source)
  values (v_user, (now() at time zone 'utc')::date, v_source)
  on conflict do nothing;

  update public.users
     set last_logged_in_at = now()
   where auth_user_id = v_user;
end;
$$;

revoke all on function public.touch_user_activity(text, uuid) from public, anon;
grant execute on function public.touch_user_activity(text, uuid) to authenticated, service_role;
