-- GET-325 (GET-318 stage 1) — Inquiries: foundation schema.
--
-- Design: webflow-app-documentation/features/inquiries/feature.md §3.1–§3.4
-- (tables, changed tables, RPCs, inquiry_reevaluate with the D1′ rule).
-- Plan:   webflow-app-documentation/features/inquiries/implementation.md "Stage 1".
-- Mirror: getinsyts-native/db/schema.sql (local-dev approximation).
--
-- What this adds
--   * 5 server-only tables (RLS on, NO client policies, no anon/authenticated
--     grants): inquiries, inquiry_targets, inquiry_proposals, inquiry_reports,
--     inquiry_views. Every read/write goes through the RN API server.
--   * insyts.visibility / private_until / inquiry_proposal_id (+ one insyt per
--     proposal, ever) and a RESTRICTIVE select policy that hides private insyts
--     from every anon/authenticated PostgREST caller — including their author
--     and requester on web (decision 3, S7-AC1).
--   * insyt_ratings: a trigger refusing ratings on private insyts (all writers are
--     service-role, which bypasses RLS but not triggers — decision 5, S7-AC3) and
--     the select policy narrowed to the rater's own row (decision 20, S2-AC7).
--   * purchases.is_anonymous (stamped at purchase time — used from stage 6).
--   * inquiry_proposals.version, bumped on every content edit (decision 18).
--   * users triggers: Insyter demotion and account deletion cancel the user's
--     pending work and re-evaluate the affected inquiries (S8-AC3, S8-AC4).
--   * RPCs accept_/decline_/cancel_inquiry_proposal + inquiry_reevaluate —
--     SECURITY DEFINER, callable by service_role only.
--
-- NOT here (later stages): the insyts delivery trigger (§3.5, stage 4), the
-- trending/viewed RPC filters (stage 4), creators_read_own_sales AND NOT
-- is_anonymous + the sales ledger (stage 6), terms v1.1 (stage 8).
--
-- Additive only: nothing existing is dropped except insyt_ratings_select_all,
-- which is replaced by an own-row policy (no reader depends on other users'
-- rows: web reads only its own row at src/insyt-detail.ts:557, the RN server
-- reads ratings with the service role, aggregates are denormalised onto insyts).
-- Every new behavior is a no-op while no insyt is private and no inquiry exists.
--
-- ⚠️ NEVER `TRUNCATE public.inquiries / inquiry_proposals … CASCADE` (e.g. to
-- reset staging fixtures): insyts.inquiry_proposal_id references
-- inquiry_proposals, so the CASCADE truncates public.insyts — every insyt.
-- Delete the rows you mean instead (the e2e fixtures do).

-- 🚨 EXPLICIT TRANSACTION — our deploy path does NOT wrap a migration file in
-- one (see 20261001174013_get277_insyts_published_at.sql). Without it a failure
-- half-way would leave insyts with the new columns but without the restrictive
-- policy, and the `set local`s below would silently do nothing.
begin;

set local lock_timeout      = '3s';   -- bound the wait for ACCESS EXCLUSIVE on insyts
set local statement_timeout = '30s';

-- ============================================================================
-- 1. inquiries — one row per request for an insyt that doesn't exist yet.
--    Drafts are server-side rows (S1-AC5), so the brief fields are optional
--    until the inquiry leaves `draft` (inquiries_publishable).
-- ============================================================================
create table public.inquiries (
  id                     uuid primary key default gen_random_uuid(),
  -- SET NULL, not CASCADE: an account deletion archives + wipes the inquiry
  -- (§3.2 brief wipe) but keeps the row, so the Insyters' proposals and any
  -- delivered private insyt keep their history.
  requester_auth_user_id uuid references auth.users (id) on delete set null,
  status                 text not null default 'draft'
                         check (status in ('draft', 'open', 'in_progress', 'completed', 'unpublished', 'archived')),
  title                  text not null default '' check (char_length(title) <= 120),
  -- 50 000 = MAX_HTML_CHARS in getinsyts-native server/src/lib/sanitize-html.ts
  -- (the server rejects over-cap input before it gets here; this is the backstop).
  description_html       text not null default '' check (char_length(description_html) <= 50000),
  sport                  text,
  content_type           text,
  expertise_slugs        text[] not null default '{}',
  tags                   text[] not null default '{}' check (cardinality(tags) <= 8),
  audience               text not null default 'all_insyters' check (audience in ('all_insyters', 'specific')),
  is_anonymous           boolean not null default false,
  open_until             timestamptz,              -- null = open indefinitely; expiry is derived, never stored
  is_exclusive           boolean not null default false,
  insyts_wanted          integer not null default 1 check (insyts_wanted between 1 and 10),
  -- whole euros, min €1 (S1-AC1)
  price_min_cents        integer check (price_min_cents >= 100 and price_min_cents % 100 = 0),
  price_max_cents        integer check (price_max_cents >= 100 and price_max_cents % 100 = 0),
  moderated_at           timestamptz,              -- set = admin takedown ("moderated")
  moderated_by           uuid,                     -- staff auth_user_id; audit only, deliberately no FK
  published_at           timestamptz,              -- FIRST time it left draft (3-new-per-day cap, S1-AC6)
  created_at             timestamptz not null default now(),
  updated_at             timestamptz not null default now(),
  constraint inquiries_price_range
    check (price_min_cents is null or price_max_cents is null or price_min_cents <= price_max_cents),
  -- A published brief is complete. Archived is exempt: the account-deletion
  -- wipe archives drafts too, and that must never fail an account deletion.
  constraint inquiries_publishable
    check (status in ('draft', 'archived')
           or (char_length(btrim(title)) > 0
               and sport is not null
               and price_min_cents is not null
               and price_max_cents is not null)),
  -- Once published, never a draft again (unpublish is its own state).
  constraint inquiries_no_return_to_draft
    check (published_at is null or status <> 'draft'),
  -- A moderated inquiry stays down whatever writes it: only unpublished (as
  -- moderated) or archived. Backs "re-publish (unless moderated)" (S5-AC5) and
  -- D1′ "a moderated inquiry stays unpublished" for every writer, not just the API.
  constraint inquiries_moderated_stays_down
    check (moderated_at is null or status in ('unpublished', 'archived'))
);

comment on table public.inquiries is
  'GET-318 Inquiries. Server-only (RLS on, no client policies). Status is derived '
  'by inquiry_reevaluate() after every outcome-changing write (feature.md §3.4).';

-- Manage view + the 5-live cap (requester_auth_user_id, status).
create index inquiries_requester_idx on public.inquiries (requester_auth_user_id, created_at desc);
-- 3-new-per-day cap: published_at within 24h per requester.
create index inquiries_requester_published_idx on public.inquiries (requester_auth_user_id, published_at)
  where published_at is not null;
-- Find (E1): live inquiries, newest first.
create index inquiries_live_idx on public.inquiries (published_at desc)
  where status in ('open', 'in_progress');

-- ============================================================================
-- 2. inquiry_targets — audience = specific: the 1–10 Insyters who may see it.
-- ============================================================================
create table public.inquiry_targets (
  inquiry_id           uuid not null references public.inquiries (id) on delete cascade,
  creator_auth_user_id uuid not null references auth.users (id) on delete cascade,
  created_at           timestamptz not null default now(),
  primary key (inquiry_id, creator_auth_user_id)
);

-- "Targeted at me" lookups for Find + the badge.
create index inquiry_targets_creator_idx on public.inquiry_targets (creator_auth_user_id);

-- ============================================================================
-- 3. inquiry_proposals — an Insyter's priced offer. One per (inquiry, Insyter),
--    EVER, whatever its outcome (D4).
-- ============================================================================
create table public.inquiry_proposals (
  id                   uuid primary key default gen_random_uuid(),
  inquiry_id           uuid not null references public.inquiries (id) on delete cascade,
  -- SET NULL keeps the history; the users BEFORE DELETE trigger (§8) cancels
  -- the pending ones first, and the insyter-gone trigger (§7) backs it up.
  insyter_auth_user_id uuid references auth.users (id) on delete set null,
  status               text not null default 'submitted'
                       check (status in ('submitted', 'accepted', 'declined', 'withdrawn', 'delivering', 'delivered', 'cancelled')),
  abstract             text not null check (char_length(abstract) between 1 and 500),
  outline_html         text not null check (char_length(outline_html) between 1 and 50000),   -- = MAX_HTML_CHARS
  read_time_min        integer not null check (read_time_min > 0),
  price_cents          integer not null check (price_cents >= 100 and price_cents % 100 = 0),
  deliver_by           date not null,
  insyt_id             uuid references public.insyts (id) on delete set null,   -- set on delivery (stage 4)
  terms_accepted_at    timestamptz not null,                                     -- inquiry-terms checkbox (S4-AC1)
  -- Bumped by inquiry_proposals_before_update whenever the content the
  -- requester judges changes; accept carries the version it saw (S5-AC7).
  -- An integer, not updated_at: ms (JS) vs µs (Postgres) precision (decision 18).
  version              integer not null default 1,
  decided_at           timestamptz,               -- accept / decline
  delivering_since     timestamptz,               -- stage 4 delivery claim
  error                text,                      -- last delivery failure, shown to the Insyter (S6-AC2)
  cancel_reason        text,                      -- why it became `cancelled` (see inquiry_cancel_* below)
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now(),
  constraint inquiry_proposals_one_per_insyter unique (inquiry_id, insyter_auth_user_id)
);

comment on table public.inquiry_proposals is
  'GET-318 proposals. Server-only. accept/decline/cancel only via the SECURITY DEFINER '
  'RPCs (atomic, filled slots never exceed insyts_wanted).';

create index inquiry_proposals_inquiry_idx on public.inquiry_proposals (inquiry_id, status);
-- My proposals + the 20-per-24h cap (S4-AC6).
create index inquiry_proposals_insyter_idx on public.inquiry_proposals (insyter_auth_user_id, created_at desc);

-- ============================================================================
-- 4. inquiry_reports — "report this inquiry" (S2-AC6, stage 8 builds the queue).
-- ============================================================================
create table public.inquiry_reports (
  id                    uuid primary key default gen_random_uuid(),
  inquiry_id            uuid not null references public.inquiries (id) on delete cascade,
  reporter_auth_user_id uuid references auth.users (id) on delete set null,
  reason                text not null check (char_length(btrim(reason)) > 0),
  note                  text check (note is null or char_length(note) <= 1000),
  resolved_at           timestamptz,
  resolved_by           uuid,                     -- staff auth_user_id; audit only, no FK
  created_at            timestamptz not null default now()
);

create index inquiry_reports_inquiry_idx on public.inquiry_reports (inquiry_id, created_at desc);
create index inquiry_reports_open_idx on public.inquiry_reports (created_at desc) where resolved_at is null;

-- ============================================================================
-- 5. inquiry_views — "opened by this Insyter" for the nav badge (S2-AC8).
-- ============================================================================
create table public.inquiry_views (
  inquiry_id           uuid not null references public.inquiries (id) on delete cascade,
  insyter_auth_user_id uuid not null references auth.users (id) on delete cascade,
  seen_at              timestamptz not null default now(),
  primary key (inquiry_id, insyter_auth_user_id)
);

create index inquiry_views_insyter_idx on public.inquiry_views (insyter_auth_user_id);

-- Server-only: RLS on with ZERO policies, and no table privileges for the two
-- API roles either (Supabase's default privileges grant them ALL on new public
-- tables). The requester's identity on an anonymous inquiry lives in these rows,
-- so they must be unreachable from a browser key (S2-AC4/AC7).
alter table public.inquiries         enable row level security;
alter table public.inquiry_targets   enable row level security;
alter table public.inquiry_proposals enable row level security;
alter table public.inquiry_reports   enable row level security;
alter table public.inquiry_views     enable row level security;

revoke all on public.inquiries, public.inquiry_targets, public.inquiry_proposals,
              public.inquiry_reports, public.inquiry_views
  from anon, authenticated;

-- ============================================================================
-- 6. Row triggers on the new tables.
-- ============================================================================

-- 6a. inquiries: updated_at is authoritative, and published_at is stamped the
--     first time the inquiry goes live — for every writer, so the 3-new-per-day
--     cap can't be dodged by a path that forgets to set it. A re-publish keeps
--     the original stamp (S1-AC6: re-publish doesn't count toward that cap).
create or replace function public.inquiries_before_write()
  returns trigger
  language plpgsql
  set search_path = public
as $$
begin
  new.updated_at := now();
  if new.published_at is null and new.status not in ('draft', 'archived') then
    new.published_at := now();
  end if;
  return new;
end;
$$;

create trigger inquiries_before_write
  before insert or update on public.inquiries
  for each row execute function public.inquiries_before_write();

-- 6b. inquiry_proposals: bump `version` when the content the requester judges
--     changes; pin it otherwise, so no writer can set it to an arbitrary value
--     and replay a stale accept.
create or replace function public.inquiry_proposals_before_update()
  returns trigger
  language plpgsql
  set search_path = public
as $$
begin
  if (new.abstract, new.outline_html, new.read_time_min, new.price_cents, new.deliver_by)
     is distinct from
     (old.abstract, old.outline_html, old.read_time_min, old.price_cents, old.deliver_by) then
    new.version := old.version + 1;
  else
    new.version := old.version;
  end if;
  new.updated_at := now();
  return new;
end;
$$;

create trigger inquiry_proposals_before_update
  before update on public.inquiry_proposals
  for each row execute function public.inquiry_proposals_before_update();

-- 6c. inquiry_targets: at most 10 per inquiry (S3-AC1). The inquiry row lock
--     serialises concurrent inserts; rows earlier in the same INSERT are visible
--     to this BEFORE ROW trigger, so a single 11-row insert is refused too.
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
  select count(*) into n
    from public.inquiry_targets
   where inquiry_id = new.inquiry_id
     and creator_auth_user_id is distinct from new.creator_auth_user_id;
  if n >= 10 then
    raise exception 'an inquiry can target at most 10 Insyters'
      using errcode = 'check_violation';
  end if;
  return new;
end;
$$;

create trigger inquiry_targets_cap
  before insert or update of inquiry_id on public.inquiry_targets
  for each row execute function public.inquiry_targets_cap();

-- ============================================================================
-- 7. insyts — privacy columns + the restrictive policy.
-- ============================================================================
alter table public.insyts
  add column if not exists visibility text not null default 'public'
    constraint insyts_visibility_check check (visibility in ('public', 'private')),
  -- 'infinity' = exclusive (private forever); else the public-flip moment (stage 5)
  add column if not exists private_until timestamptz,
  add column if not exists inquiry_proposal_id uuid
    references public.inquiry_proposals (id);

-- One insyt per proposal, ever (§3.5: a double-submit can't create a second one).
create unique index if not exists insyts_inquiry_proposal_id_key
  on public.insyts (inquiry_proposal_id)
  where inquiry_proposal_id is not null;

-- 🚨 THE GRANT (GET-116 / GET-190 / GET-277): insyts has COLUMN-level grants for
-- anon/authenticated, so a new column is unreadable — and every query naming it
-- 42501s — until granted. Grant ONLY `visibility`: private_until and
-- inquiry_proposal_id stay service-role-only, because after the public flip
-- they would reveal that an insyt came from an inquiry (feature.md §3.2).
grant select (visibility) on public.insyts to anon, authenticated;

comment on column public.insyts.visibility is
  'GET-318: public | private. Private = delivered against an inquiry proposal and '
  'not (yet) flipped public. Hidden from anon/authenticated by the RESTRICTIVE '
  'policy insyts_public_only. Granted to anon/authenticated (column-level grants, '
  'see search_vector comment); private_until / inquiry_proposal_id deliberately are NOT.';

-- Permissive policies are OR'd, so only a RESTRICTIVE one can hide rows that
-- "Public read published" / "buyers_read_purchased_insyts" / "Creators read own
-- insyts" would otherwise show. Covers every PostgREST / user-JWT caller,
-- including the author and the requester on web (S7-AC1, decision 19). The
-- service role bypasses RLS: the RN server's admin branches gate private reads
-- explicitly (stage 4).
create policy insyts_public_only on public.insyts
  as restrictive
  for select
  to anon, authenticated
  using (visibility = 'public');

-- ============================================================================
-- 8. insyt_ratings — refuse private insyts; own-row reads only.
-- ============================================================================

-- SECURITY DEFINER is load-bearing: run as the caller, the restrictive policy
-- above would HIDE the private insyt from this lookup and the guard would fail
-- open for any non-service writer. As the table owner it sees every row.
create or replace function public.insyt_ratings_refuse_private()
  returns trigger
  language plpgsql
  security definer
  set search_path = public
as $$
begin
  if exists (select 1 from public.insyts where id = new.insyt_id and visibility = 'private') then
    raise exception 'private insyts cannot be rated'
      using errcode = 'check_violation', hint = 'GET-318 S7-AC3';
  end if;
  return new;
end;
$$;

revoke execute on function public.insyt_ratings_refuse_private() from public, anon, authenticated, service_role;

create trigger insyt_ratings_refuse_private
  before insert or update on public.insyt_ratings
  for each row execute function public.insyt_ratings_refuse_private();

-- Was USING (true) for anon + authenticated (20260529173913): anyone could read
-- who rated what — after a non-exclusive private insyt flips public, that would
-- name the requester (decision 20, S2-AC7). Aggregates stay public via
-- insyts.rating_avg / rating_count; the web and RN read only the caller's row.
drop policy if exists insyt_ratings_select_all on public.insyt_ratings;
create policy insyt_ratings_select_own on public.insyt_ratings
  for select
  to authenticated
  using (user_id = auth.uid());

-- ============================================================================
-- 9. purchases.is_anonymous — stamped by the RN Stripe webhook at purchase time
--    (stage 6). A stamped column, not a join, so it survives account deletion
--    and the public flip and can't fail open.
-- ============================================================================
alter table public.purchases
  add column if not exists is_anonymous boolean not null default false;

-- ============================================================================
-- 10. Lifecycle — inquiry_reevaluate (§3.4, D1′/D2/D3). THE one place an
--     inquiry's stored state is derived. Called after every write that can
--     change its outcome (accept, decline, cancel, withdraw, delivered, archive,
--     unpublish, re-publish, takedown, demotion, deletion) — never on read:
--     expiry is derived at read time and changes nothing stored.
--
--       delivered = #delivered, filled = #(accepted|delivering|delivered)
--       archived              → cancel all submitted                      (D2)
--       delivered >= N        → completed, cancel all submitted       (D1′, D2)
--       open / in_progress    → in_progress if filled > 0 else open
--       unpublished / draft   → unchanged (revived by re-publish / extending open_until)
--
--     One refinement over the §3.4 pseudo-code, from its own precedence rule
--     (archived > unpublished > completed) and D1′ ("a moderated inquiry stays
--     unpublished"): a MODERATED inquiry whose last accepted proposal delivers
--     keeps `unpublished` (inquiries_moderated_stays_down enforces it) — its
--     submitted proposals are still cancelled, so nothing dangles.
--
--     At exactly N filled (not all delivered) nothing is cancelled: pending
--     proposals show "slots full", because a slot can free up again (S8-AC5).
--
--     Lock order everywhere in this file: the inquiry row, then its proposals.
-- ============================================================================
create or replace function public.inquiry_reevaluate(p_inquiry_id uuid)
  returns text
  language plpgsql
  security definer
  set search_path = public
as $$
declare
  v_status    text;
  v_wanted    integer;
  v_moderated boolean;
  v_delivered integer;
  v_filled    integer;
  v_next      text;
begin
  select status, insyts_wanted, moderated_at is not null
    into v_status, v_wanted, v_moderated
    from public.inquiries
   where id = p_inquiry_id
   for update;
  if not found then
    return null;
  end if;

  select count(*) filter (where status = 'delivered'),
         count(*) filter (where status in ('accepted', 'delivering', 'delivered'))
    into v_delivered, v_filled
    from public.inquiry_proposals
   where inquiry_id = p_inquiry_id;

  if v_status = 'archived' then
    update public.inquiry_proposals
       set status = 'cancelled', cancel_reason = 'inquiry_archived'
     where inquiry_id = p_inquiry_id and status = 'submitted';
    return v_status;
  end if;

  if v_delivered >= v_wanted then
    if v_status <> 'completed' and not v_moderated then
      update public.inquiries set status = 'completed' where id = p_inquiry_id;
      v_status := 'completed';
    end if;
    update public.inquiry_proposals
       set status = 'cancelled', cancel_reason = 'inquiry_completed'
     where inquiry_id = p_inquiry_id and status = 'submitted';
    return v_status;
  end if;

  if v_status in ('open', 'in_progress') then
    v_next := case when v_filled > 0 then 'in_progress' else 'open' end;
    if v_next <> v_status then
      update public.inquiries set status = v_next where id = p_inquiry_id;
      v_status := v_next;
    end if;
  end if;

  return v_status;
end;
$$;

-- ============================================================================
-- 11. RPCs the RN server calls (service role). Results are jsonb
--     { result: 'ok' | 'stale' | 'not_acceptable' | 'not_found', reason?, proposal? }
--     — the route maps them to HTTP (stale → 409 with the fresh proposal, S5-AC7).
--     'not_found' covers "not your inquiry" too, so the API is no existence oracle.
-- ============================================================================

-- accept: atomic — the inquiry row lock serialises concurrent accepts, so
-- filled slots can never exceed N, even on a double-tap (S5-AC3).
create or replace function public.accept_inquiry_proposal(
  p_proposal_id  uuid,
  p_requester    uuid,
  p_seen_version integer
)
  returns jsonb
  language plpgsql
  security definer
  set search_path = public
as $$
declare
  v_inquiry_id uuid;
  inq          public.inquiries%rowtype;
  prop         public.inquiry_proposals%rowtype;
  v_filled     integer;
begin
  select inquiry_id into v_inquiry_id from public.inquiry_proposals where id = p_proposal_id;
  if v_inquiry_id is null then
    return jsonb_build_object('result', 'not_found');
  end if;

  select * into inq from public.inquiries where id = v_inquiry_id for update;
  if not found or p_requester is null or inq.requester_auth_user_id is distinct from p_requester then
    return jsonb_build_object('result', 'not_found');
  end if;

  select * into prop from public.inquiry_proposals where id = p_proposal_id for update;

  -- Idempotent double-tap: already accepted at exactly the version the
  -- requester saw → the same answer as the first tap.
  if prop.status = 'accepted' and prop.version = p_seen_version then
    return jsonb_build_object('result', 'ok', 'proposal', to_jsonb(prop));
  end if;

  -- The Insyter edited it after the requester loaded it (S5-AC7).
  if prop.version is distinct from p_seen_version then
    return jsonb_build_object('result', 'stale', 'proposal', to_jsonb(prop));
  end if;

  if prop.status <> 'submitted' then
    return jsonb_build_object('result', 'not_acceptable', 'reason', 'status', 'proposal', to_jsonb(prop));
  end if;

  -- E2: not archived, not moderated, filled < N. (Expired / requester-
  -- unpublished inquiries can still accept.)
  if inq.status = 'archived' then
    return jsonb_build_object('result', 'not_acceptable', 'reason', 'archived', 'proposal', to_jsonb(prop));
  end if;
  if inq.moderated_at is not null then
    return jsonb_build_object('result', 'not_acceptable', 'reason', 'moderated', 'proposal', to_jsonb(prop));
  end if;
  select count(*) into v_filled
    from public.inquiry_proposals
   where inquiry_id = inq.id and status in ('accepted', 'delivering', 'delivered');
  if v_filled >= inq.insyts_wanted then
    return jsonb_build_object('result', 'not_acceptable', 'reason', 'full', 'proposal', to_jsonb(prop));
  end if;

  update public.inquiry_proposals
     set status = 'accepted', decided_at = now()
   where id = p_proposal_id
  returning * into prop;

  perform public.inquiry_reevaluate(inq.id);
  return jsonb_build_object('result', 'ok', 'proposal', to_jsonb(prop));
end;
$$;

-- decline: requester only, submitted → declined; repeat → ok.
create or replace function public.decline_inquiry_proposal(
  p_proposal_id uuid,
  p_requester   uuid
)
  returns jsonb
  language plpgsql
  security definer
  set search_path = public
as $$
declare
  v_inquiry_id uuid;
  inq          public.inquiries%rowtype;
  prop         public.inquiry_proposals%rowtype;
begin
  select inquiry_id into v_inquiry_id from public.inquiry_proposals where id = p_proposal_id;
  if v_inquiry_id is null then
    return jsonb_build_object('result', 'not_found');
  end if;

  select * into inq from public.inquiries where id = v_inquiry_id for update;
  if not found or p_requester is null or inq.requester_auth_user_id is distinct from p_requester then
    return jsonb_build_object('result', 'not_found');
  end if;

  select * into prop from public.inquiry_proposals where id = p_proposal_id for update;

  if prop.status = 'declined' then
    return jsonb_build_object('result', 'ok', 'proposal', to_jsonb(prop));
  end if;
  if prop.status <> 'submitted' then
    return jsonb_build_object('result', 'not_acceptable', 'reason', 'status', 'proposal', to_jsonb(prop));
  end if;

  update public.inquiry_proposals
     set status = 'declined', decided_at = now()
   where id = p_proposal_id
  returning * into prop;

  perform public.inquiry_reevaluate(inq.id);
  return jsonb_build_object('result', 'ok', 'proposal', to_jsonb(prop));
end;
$$;

-- cancel: frees a slot.
--   p_actor = the requester → only an `accepted` proposal whose deliver-by date
--             has passed (S5-AC6; `delivering` is never cancellable).
--   p_actor = null          → system (sweeps, takedown): any submitted/accepted.
-- p_reason is stored in cancel_reason (defaults: requester_overdue / system).
create or replace function public.cancel_inquiry_proposal(
  p_proposal_id uuid,
  p_actor       uuid,
  p_reason      text
)
  returns jsonb
  language plpgsql
  security definer
  set search_path = public
as $$
declare
  v_inquiry_id uuid;
  inq          public.inquiries%rowtype;
  prop         public.inquiry_proposals%rowtype;
begin
  select inquiry_id into v_inquiry_id from public.inquiry_proposals where id = p_proposal_id;
  if v_inquiry_id is null then
    return jsonb_build_object('result', 'not_found');
  end if;

  select * into inq from public.inquiries where id = v_inquiry_id for update;
  if not found or (p_actor is not null and inq.requester_auth_user_id is distinct from p_actor) then
    return jsonb_build_object('result', 'not_found');
  end if;

  select * into prop from public.inquiry_proposals where id = p_proposal_id for update;

  if prop.status = 'cancelled' then
    return jsonb_build_object('result', 'ok', 'proposal', to_jsonb(prop));
  end if;

  if p_actor is not null then
    if prop.status <> 'accepted' then
      return jsonb_build_object('result', 'not_acceptable', 'reason', 'status', 'proposal', to_jsonb(prop));
    end if;
    if prop.deliver_by >= current_date then
      return jsonb_build_object('result', 'not_acceptable', 'reason', 'not_overdue', 'proposal', to_jsonb(prop));
    end if;
  elsif prop.status not in ('submitted', 'accepted') then
    return jsonb_build_object('result', 'not_acceptable', 'reason', 'status', 'proposal', to_jsonb(prop));
  end if;

  update public.inquiry_proposals
     set status = 'cancelled',
         cancel_reason = coalesce(nullif(btrim(p_reason), ''),
                                  case when p_actor is null then 'system' else 'requester_overdue' end)
   where id = p_proposal_id
  returning * into prop;

  perform public.inquiry_reevaluate(inq.id);
  return jsonb_build_object('result', 'ok', 'proposal', to_jsonb(prop));
end;
$$;

-- ============================================================================
-- 12. Internal helpers for the users / FK-null triggers (not callable over /rpc).
-- ============================================================================

-- An Insyter is gone (demoted or deleted): cancel their submitted + accepted
-- proposals and free the slots (S8-AC3). `delivering` resolves normally.
-- Inquiries are locked in id order, before their proposals (the global order).
create or replace function public.inquiry_cancel_insyter_proposals(p_insyter uuid, p_reason text)
  returns void
  language plpgsql
  security definer
  set search_path = public
as $$
declare
  v_inquiry_id uuid;
begin
  if p_insyter is null then
    return;
  end if;
  for v_inquiry_id in
    select distinct inquiry_id
      from public.inquiry_proposals
     where insyter_auth_user_id = p_insyter
       and status in ('submitted', 'accepted')
     order by inquiry_id
  loop
    perform 1 from public.inquiries where id = v_inquiry_id for update;
    update public.inquiry_proposals
       set status = 'cancelled', cancel_reason = p_reason
     where inquiry_id = v_inquiry_id
       and insyter_auth_user_id = p_insyter
       and status in ('submitted', 'accepted');
    perform public.inquiry_reevaluate(v_inquiry_id);
  end loop;
end;
$$;

-- The requester's account is gone (D3, S8-AC4): archive the inquiry, wipe the
-- brief (title/description/tags/expertise — the proposals keep their own text,
-- they belong to the Insyters) and cancel its submitted + accepted proposals —
-- nobody is left to buy the delivery. `delivering` resolves normally and a
-- delivered private insyt stays private. Idempotent.
create or replace function public.inquiry_retire_for_deleted_requester(p_inquiry_id uuid)
  returns void
  language plpgsql
  security definer
  set search_path = public
as $$
begin
  perform 1 from public.inquiries where id = p_inquiry_id for update;
  if not found then
    return;
  end if;
  update public.inquiries
     set title = '[deleted]',
         description_html = '',
         tags = '{}',
         expertise_slugs = '{}',
         status = 'archived'
   where id = p_inquiry_id;
  update public.inquiry_proposals
     set status = 'cancelled', cancel_reason = 'requester_deleted'
   where inquiry_id = p_inquiry_id
     and status in ('submitted', 'accepted');
  perform public.inquiry_reevaluate(p_inquiry_id);
end;
$$;

-- ============================================================================
-- 13. users triggers — "by any path" (S8-AC3): the web, the RN server, n8n,
--     the delete-account edge fn and manual SQL all end here.
-- ============================================================================

-- Insyter status lost (is_creator true → false/null).
create or replace function public.users_inquiries_on_demote()
  returns trigger
  language plpgsql
  security definer
  set search_path = public
as $$
begin
  perform public.inquiry_cancel_insyter_proposals(new.auth_user_id, 'insyter_demoted');
  return null;
end;
$$;

create trigger users_inquiries_on_demote
  after update of is_creator on public.users
  for each row
  when (old.is_creator is true and new.is_creator is distinct from true)
  execute function public.users_inquiries_on_demote();

-- Account deletion. Both deletion paths remove this row: RN DELETE /api/me
-- deletes it directly (server/src/routes/me.ts), the delete-account edge fn
-- deletes auth.users and this row goes by cascade (users_id_fkey). BEFORE, so
-- the requester/insyter ids are still on the inquiry rows when it runs.
--
-- On the CASCADE path the auth.users row is already gone, so rewriting a
-- proposal that still references it can trip its FK re-check (Postgres re-runs
-- it for a row touched earlier in the same transaction). That path is owned by
-- the FK-null backstops below — they fire on the SET NULL itself, whichever
-- order the cascades run in — so this trigger only acts while the auth user
-- still exists (the RN path, and any manual public.users delete).
create or replace function public.users_inquiries_on_delete()
  returns trigger
  language plpgsql
  security definer
  set search_path = public
as $$
declare
  v_inquiry_id uuid;
begin
  if old.auth_user_id is null
     or not exists (select 1 from auth.users where id = old.auth_user_id) then
    return old;
  end if;
  perform public.inquiry_cancel_insyter_proposals(old.auth_user_id, 'insyter_deleted');
  for v_inquiry_id in
    select id from public.inquiries
     where requester_auth_user_id = old.auth_user_id
     order by id
  loop
    perform public.inquiry_retire_for_deleted_requester(v_inquiry_id);
  end loop;
  return old;
end;
$$;

create trigger users_inquiries_on_delete
  before delete on public.users
  for each row execute function public.users_inquiries_on_delete();

-- The auth.users cascade path. Deleting auth.users runs the FK actions on its
-- referencing tables (in RI-trigger NAME order, i.e. not one we can rely on):
-- these two fire on exactly the ON DELETE SET NULL of the requester / Insyter
-- column and do the same work as the users trigger above. When that trigger
-- already ran (RN path: public.users deleted first) they are no-ops — the
-- inquiry is already archived and wiped, the proposals already cancelled.
create or replace function public.inquiries_on_requester_gone()
  returns trigger
  language plpgsql
  security definer
  set search_path = public
as $$
begin
  perform public.inquiry_retire_for_deleted_requester(new.id);
  return null;
end;
$$;

create trigger inquiries_on_requester_gone
  after update of requester_auth_user_id on public.inquiries
  for each row
  when (old.requester_auth_user_id is not null and new.requester_auth_user_id is null)
  execute function public.inquiries_on_requester_gone();

create or replace function public.inquiry_proposals_on_insyter_gone()
  returns trigger
  language plpgsql
  security definer
  set search_path = public
as $$
begin
  perform 1 from public.inquiries where id = new.inquiry_id for update;
  update public.inquiry_proposals
     set status = 'cancelled', cancel_reason = 'insyter_deleted'
   where id = new.id
     and status in ('submitted', 'accepted');
  perform public.inquiry_reevaluate(new.inquiry_id);
  return null;
end;
$$;

create trigger inquiry_proposals_on_insyter_gone
  after update of insyter_auth_user_id on public.inquiry_proposals
  for each row
  when (old.insyter_auth_user_id is not null
        and new.insyter_auth_user_id is null
        and old.status in ('submitted', 'accepted'))
  execute function public.inquiry_proposals_on_insyter_gone();

-- ============================================================================
-- 14. EXECUTE: Supabase's default privileges grant EXECUTE on new public
--     functions to anon/authenticated/service_role — so every function above
--     would otherwise be callable over /rest/v1/rpc with a browser key. Revoke
--     everywhere; the four RPCs are granted to service_role only (the RN
--     server). The internal helpers and trigger functions are callable by
--     nobody over /rpc (triggers and the definer RPCs run them as the owner).
-- ============================================================================
revoke execute on function
  public.inquiries_before_write(),
  public.inquiry_proposals_before_update(),
  public.inquiry_targets_cap(),
  public.inquiry_reevaluate(uuid),
  public.accept_inquiry_proposal(uuid, uuid, integer),
  public.decline_inquiry_proposal(uuid, uuid),
  public.cancel_inquiry_proposal(uuid, uuid, text),
  public.inquiry_cancel_insyter_proposals(uuid, text),
  public.inquiry_retire_for_deleted_requester(uuid),
  public.users_inquiries_on_demote(),
  public.users_inquiries_on_delete(),
  public.inquiries_on_requester_gone(),
  public.inquiry_proposals_on_insyter_gone()
  from public, anon, authenticated, service_role;

grant execute on function
  public.inquiry_reevaluate(uuid),
  public.accept_inquiry_proposal(uuid, uuid, integer),
  public.decline_inquiry_proposal(uuid, uuid),
  public.cancel_inquiry_proposal(uuid, uuid, text)
  to service_role;

commit;
