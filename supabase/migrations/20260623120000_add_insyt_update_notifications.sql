-- Edit published insyt (GET-71): audit trail of "insyt updated" buyer
-- notifications. When a creator edits an insyt that has already been purchased
-- at least once, the confirm_update action in submit-create-insyt records ONE
-- row here per dispatch (insyt_id + how many distinct buyers were emailed +
-- the creator's optional message), then fires the n8n -> Brevo notification.
--
-- This is purely an additive AUDIT table — no existing column changes. The
-- feed-resurfacing / edit gating all reuse the EXISTING insyts.updated_at and
-- purchases tables (see webflow-app-documentation/features/creator-insyt-editing/).
-- Writes are service-role only (the edge function), matching the rest of the
-- create-insyt surface; there is no client-facing read path, so no RLS policy
-- is granted (RLS on, no policy = service-role only).

create table if not exists public.insyt_update_notifications (
  id            bigint generated always as identity primary key,
  insyt_id      text not null,
  creator_email text,
  buyer_count   integer not null default 0,
  message       text,
  sent_at       timestamptz not null default now()
);

comment on table public.insyt_update_notifications is
  'GET-71: audit of insyt-updated buyer-notification dispatches (one row per confirm_update).';

-- Lookups are "what updates went out for this insyt, most recent first".
create index if not exists insyt_update_notifications_insyt_idx
  on public.insyt_update_notifications (insyt_id, sent_at desc);

alter table public.insyt_update_notifications enable row level security;
