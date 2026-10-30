-- GET-117 (SF5) — block client self-privilege-escalation on public.users.
--
-- The two UPDATE policies on public.users are USING-only (no WITH CHECK, no
-- column scope) and anon/authenticated hold GRANT ALL, so a user can currently
-- write ANY column on their own row — including is_creator=true (self-promote to
-- creator), stripe_* ids, or the signed-agreement columns. RLS cannot express a
-- column-level restriction; a BEFORE UPDATE trigger can.
--
-- Service-role callers (accept-agreement, sync-creator-to-webflow, stripe/n8n)
-- legitimately set these columns, so the trigger EXEMPTS the decoded service_role
-- claim (never a key match). A non-service caller changing any protected column is
-- rejected. The ~17 profile columns the frontend legitimately writes
-- (display_name, bio, headline, username, location, website, hide_*, sports,
-- content_types, sponsor_links, profile_image_url, cover_image_url, updated_at, …)
-- are NOT in the protected set, so /account + creator-profile saves are unaffected.
--
-- NOTE: report_count is deliberately NOT guarded — it is maintained by a
-- SECURITY DEFINER sync (refresh_creator_report_count) that may run under an
-- authenticated caller's request context, so guarding it could break moderation.
--
-- Backwards-compatible + additive; no data change.

create or replace function public.guard_users_privileged_cols()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if coalesce(
       nullif(current_setting('request.jwt.claims', true), '')::json ->> 'role',
       ''
     ) = 'service_role' then
    return new;
  end if;

  if new.is_creator                   is distinct from old.is_creator
     or new.creator_activated_at      is distinct from old.creator_activated_at
     or new.creator_terms_accepted_at is distinct from old.creator_terms_accepted_at
     or new.webflow_creator_id        is distinct from old.webflow_creator_id
     or new.signature_name            is distinct from old.signature_name
     or new.agreement_version         is distinct from old.agreement_version
     or new.signature_ip              is distinct from old.signature_ip
     or new.stripe_customer_id        is distinct from old.stripe_customer_id
     or new.stripe_connect_id         is distinct from old.stripe_connect_id
     or new.stripe_connect_onboarded  is distinct from old.stripe_connect_onboarded
     or new.stripe_subscription_price_id is distinct from old.stripe_subscription_price_id
  then
    raise exception 'Update to a protected column on public.users is not allowed'
      using errcode = '42501';
  end if;

  return new;
end;
$$;

drop trigger if exists guard_users_privileged_cols on public.users;
create trigger guard_users_privileged_cols
  before update on public.users
  for each row execute function public.guard_users_privileged_cols();
