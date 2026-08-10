-- GET-228 · invite link with a personal note — schema
-- Spec: webflow-app-documentation/features/invite-to-check-out/feature.md §3
--
-- One row per ref. A plain share and a noted invite are the SAME object; the invite
-- fields are simply null on a plain one (S9-AC6). Additive only — nothing here alters
-- or drops an existing object, so the frontend can land before or after this migration.

create table if not exists public.share_refs (
  id              uuid primary key default gen_random_uuid(),
  ref             text not null unique,
  owner_id        uuid not null references auth.users(id) on delete cascade,
  target_kind     text not null check (target_kind in ('insyt','creator')),
  target_id       text not null,       -- insyts.insyt_id for 'insyt', users.auth_user_id for 'creator'
  kind            text not null check (kind in ('plain','noted')),

  -- noted-only; null for kind='plain' (S9-AC6)
  recipient_email text,                -- D9 plaintext; deleted on expiry/revoke/erasure
  note            text check (note is null or char_length(note) <= 280),   -- S1-AC5
  note_shown_at   timestamptz,         -- the ONE-TIME event (S3-AC5) — the note, never the counter
  signed_up_at    timestamptz,         -- S1-AC12 match → D15 `true`
  revoked_at      timestamptz,         -- revoke OR erasure (D15 — erasure must not be singled out)
  revoked_by      uuid,                -- owner or staff auth_user_id (S8-AC6)

  opens_count     integer not null default 0,   -- S9-AC2, independent of note_shown_at
  committed_at    timestamptz,                  -- S9-AC5; null = minted but never shared
  created_at      timestamptz not null default now(),
  expires_at      timestamptz not null default now() + interval '30 days',   -- D7
  disclosure_text_version smallint not null default 1                        -- S7-AC1
);

create index if not exists share_refs_owner_idx  on public.share_refs (owner_id, created_at desc);
-- every ref expires, plain included — a partial index would leave the sweep seq-scanning
create index if not exists share_refs_expiry_idx on public.share_refs (expires_at);
-- the S1-AC12 sign-up matcher's index
create index if not exists share_refs_match_idx  on public.share_refs (lower(recipient_email))
  where recipient_email is not null and signed_up_at is null;

-- Dedupe state for PLAIN refs only. S9-AC4(c) forbids per-open rows for a noted invite —
-- those increment opens_count with no row at all, so we never keep a behavioural log about a
-- named third party. The bucket is an input to dedupe_key (feature.md §5), so (ref_id, dedupe_key)
-- is the complete key; nothing expires here, §8's sweep deletes.
create table if not exists public.share_ref_opens (
  ref_id      uuid not null references public.share_refs(id) on delete cascade,
  dedupe_key  text not null,
  primary key (ref_id, dedupe_key)
);

-- S6-AC5: every staff read of a recipient email, and every revoke, is recorded
create table if not exists public.share_ref_audit (
  id         bigserial primary key,
  ref_id     uuid not null references public.share_refs(id) on delete cascade,
  actor_id   uuid not null,
  action     text not null check (action in ('staff_read','staff_revoke','owner_revoke','erasure')),
  created_at timestamptz not null default now()
);

create index if not exists share_ref_audit_ref_idx on public.share_ref_audit (ref_id, created_at desc);

-- RLS enabled with ZERO policies on all three: every read and write goes through the
-- service-role client on the RN Fastify server (D6/D13), which scopes by owner_id in the
-- query. anon never touches these tables. This is what keeps recipient_email — a third
-- party's address held in plaintext under D9 — from being one policy mistake away from
-- exposure. Same posture as GET-115's payout tables.
alter table public.share_refs      enable row level security;
alter table public.share_ref_opens enable row level security;
alter table public.share_ref_audit enable row level security;
