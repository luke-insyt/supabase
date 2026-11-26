-- GET-486 B4 (S4, feature.md §2.6–§2.7): reports on Insyts ("Report this Insyt") + the admin queue.
--
-- Modelled on inquiry_reports (20261012152621_get318_inquiries.sql), with three differences:
--   * signed-out reporters: an email instead of an account (OQ-7, DSA Art. 16), plus the IP for
--     the per-IP cap (D-4);
--   * a decision on every report (resolution, resolution_reason, resolution_note), and the
--     DSA acknowledgement/decision email stamps (AC4.7);
--   * no FK to users: a deleted reporter is handled by the deletion trigger below (AC4.10), which
--     nulls their id/email/IP, sets reporter_deleted_at and keeps the note (the notice itself).
-- D-5: NO timed redaction of signed-out reporters (no reporter_redacted_at column).
--
-- insyt_id is the SLUG (the /insyts/:id route param, the key purchases use). Server-only table:
-- the RN API writes and reads it with the service role behind its own auth gates.

create table if not exists public.insyt_reports (
  id                     uuid primary key default gen_random_uuid(),
  insyt_id               text not null,
  reporter_auth_user_id  uuid,               -- null for signed-out reporters; no FK (deletion trigger)
  reporter_email         text
                         constraint insyt_reports_reporter_email_len
                         check (reporter_email is null or char_length(reporter_email) <= 200),
  reporter_ip            inet,
  reporter_deleted_at    timestamptz,        -- the deleted-user marker (AC4.10)
  reason                 text not null
                         constraint insyt_reports_reason_check
                         check (reason in ('image_rights', 'copied', 'minor', 'confidential',
                                           'false_or_defamatory', 'offensive', 'other')),
  note                   text
                         constraint insyt_reports_note_len
                         check (note is null or char_length(note) <= 1000),
  created_at             timestamptz not null default now(),
  resolved_at            timestamptz,
  resolved_by            uuid,
  resolution             text
                         constraint insyt_reports_resolution_check
                         check (resolution in ('taken_down', 'no_action')),
  resolution_reason      text
                         constraint insyt_reports_resolution_reason_check
                         check (resolution_reason in ('image_rights', 'copied', 'minor', 'confidential',
                                  'false_or_defamatory', 'offensive', 'other',          -- takedown = rule reason
                                  'not_a_violation', 'insufficient_information', 'refund_matter', 'duplicate')),
  resolution_note        text
                         constraint insyt_reports_resolution_note_len
                         check (resolution_note is null or char_length(resolution_note) <= 500),
  takedown_ref           uuid,               -- GET-487's takedown id when resolution = 'taken_down'
  ack_sent_at            timestamptz,
  decision_sent_at       timestamptz,
  constraint insyt_reports_reporter_present
    check (reporter_auth_user_id is not null or reporter_email is not null or reporter_deleted_at is not null),
  constraint insyt_reports_resolved_pair check ((resolved_at is null) = (resolution is null)),
  constraint insyt_reports_resolution_pair check ((resolution is null) = (resolution_reason is null))
);

comment on table public.insyt_reports is
  'GET-486 S4: reports on Insyts (signed-in or signed-out with an email). Server-only (service role).';

-- "No second open report" (AC4.3), race-free: the insert hits one of these and the API returns the
-- existing open report as a duplicate.
create unique index if not exists insyt_reports_open_user
  on public.insyt_reports (insyt_id, reporter_auth_user_id)
  where resolved_at is null and reporter_auth_user_id is not null;
create unique index if not exists insyt_reports_open_email
  on public.insyt_reports (insyt_id, lower(reporter_email))
  where resolved_at is null and reporter_auth_user_id is null and reporter_email is not null;
-- The queue (open, oldest first) and the caps (per reporter / email / IP in 24 h, breaker per hour).
create index if not exists insyt_reports_open_idx on public.insyt_reports (created_at) where resolved_at is null;
create index if not exists insyt_reports_reporter_idx on public.insyt_reports (reporter_auth_user_id, created_at)
  where reporter_auth_user_id is not null;
create index if not exists insyt_reports_signed_out_idx on public.insyt_reports (created_at)
  where reporter_auth_user_id is null;

alter table public.insyt_reports enable row level security;
-- No policies: no client reads or writes it.
revoke all on table public.insyt_reports from anon, authenticated;
grant all on table public.insyt_reports to service_role;

-- ============================================================================
-- Deletion follow-up (feature.md §2.7, AC3.9 + AC4.10) — D-9 ORDER-PROOF FORM.
-- ============================================================================
-- B2 (insyt_rules_confirmations) and B4 (insyt_reports) both define this function with the SAME
-- full body. Each table's block runs only when that table exists (to_regclass), and plpgsql
-- prepares a statement only when it runs, so a not-yet-created table never breaks a delete.
-- The two migrations can merge in either order; the later one simply re-creates the same body.
-- Each update is guarded so it touches a row once (the confirmations block must never trip its
-- append-only trigger, which would roll back the user delete).
create or replace function public.auth_user_deleted_anonymise_followup()
  returns trigger
  language plpgsql
  security definer
  set search_path = public, pg_temp
as $$
begin
  -- GET-486 S3 (AC3.9): rules confirmations keep auth_user_id, lose IP/UA.
  if to_regclass('public.insyt_rules_confirmations') is not null then
    update public.insyt_rules_confirmations
       set ip = null,
           user_agent = null,
           anonymised_at = now()
     where auth_user_id = old.id
       and anonymised_at is null;
  end if;

  -- GET-486 S4 (AC4.10): a deleted reporter's reports stay, with the deleted-user marker;
  -- id, email and IP are nulled, the note (the content of the notice) stays.
  if to_regclass('public.insyt_reports') is not null then
    update public.insyt_reports
       set reporter_auth_user_id = null,
           reporter_email = null,
           reporter_ip = null,
           reporter_deleted_at = now()
     where reporter_auth_user_id = old.id
       and reporter_deleted_at is null;
  end if;

  return old;
end;
$$;

revoke execute on function public.auth_user_deleted_anonymise_followup() from public, anon, authenticated, service_role;

drop trigger if exists on_auth_user_deleted_anonymise_followup on auth.users;
create trigger on_auth_user_deleted_anonymise_followup
  after delete on auth.users
  for each row execute function public.auth_user_deleted_anonymise_followup();
