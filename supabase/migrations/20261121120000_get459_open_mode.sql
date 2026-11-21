-- GET-459 — Inquiries "Open for everyone": the access mode, the €0 release and "New" purchases.
--
-- Design: webflow-app-documentation/features/inquiries/open-mode-feature.md §2 (this file, in
--         that order), §3 (what delivery writes), §4 (the release RPC), §5 (the price lock).
-- Plan:   open-mode-implementation.md "P1 — Supabase".
-- Test:   supabase/tests/get459_open_mode_test.ts (PGlite, offline).
-- Mirror: getinsyts-native/db/schema.sql (local-dev approximation).
--
-- What this adds (additive only — nothing is dropped, every new column is nullable):
--   1. inquiries.access_mode  'exclusive' | 'timed' | 'open', null only on a draft (D11)
--   2. backfill: is_exclusive → 'exclusive', else 'timed' — drafts too
--   3. trigger inquiries_access_mode_sync keeps access_mode and the deprecated is_exclusive in
--      step for every writer, so a client that only knows is_exclusive keeps working (S1-AC5, D2)
--   4. insyts.release_price_cents  null = keep the Insyter's price; 0 = free at release (§3)
--   5. insyts.released_at  stamped once by the release; the idempotency key + price-lock signal (D3)
--   6. purchases.opened_at  first open by the buyer — drives "New" (§7.3, D5)
--   7. RPC release_inquiry_insyt(p_id) — the one atomic release, service_role only (§4, D9)
--   8. the sweep's partial index on insyts
--
-- Grants: release_price_cents / released_at stay service-role-only like private_until (§2
-- "Grants unchanged"): insyts has COLUMN-level grants, so not granting them is what keeps them
-- out of every browser-key read. After the release they would reveal an inquiry origin.

-- 🚨 EXPLICIT TRANSACTION (same rule as get277 / get318): our deploy path does not wrap a
-- file, and a failure half-way must never leave a trigger disabled or the RPC callable
-- before its EXECUTE revoke.
begin;
set local lock_timeout      = '3s';    -- bound the wait for ACCESS EXCLUSIVE on insyts / inquiries
set local statement_timeout = '30s';

-- ============================================================================
-- 1. inquiries.access_mode — nullable on purpose: a new draft has no mode, so the RN publish
--    validation (S1-AC2) is reachable. Both checks go in NOT VALID and are validated after the
--    backfill (step 2): validating now would fail on every existing published row.
--    `archived` is exempt alongside `draft`, as in inquiries_publishable: the account-deletion
--    wipe archives drafts too, and that must never fail an account deletion.
-- ============================================================================
alter table public.inquiries add column if not exists access_mode text;

alter table public.inquiries drop constraint if exists inquiries_access_mode_check;
alter table public.inquiries
  add constraint inquiries_access_mode_check
  check (access_mode in ('exclusive', 'timed', 'open')) not valid;

alter table public.inquiries drop constraint if exists inquiries_access_mode_required;
alter table public.inquiries
  add constraint inquiries_access_mode_required
  check (status in ('draft', 'archived') or access_mode is not null) not valid;

comment on column public.inquiries.access_mode is
  'GET-459: who gets the delivered insyt. exclusive = only the requester, never public; '
  'timed = public at the Insyter''s price 30 days after delivery; open = free for everyone '
  'once the requester buys. Null only on a draft. Kept in sync with the deprecated '
  'is_exclusive by inquiries_access_mode_sync.';

-- ============================================================================
-- 2. Backfill every existing row, drafts too (they publish unchanged).
--    inquiries_before_write is suppressed around it: it sets updated_at = now() on every
--    update, which would stamp every inquiry with the same transaction time. The column add
--    above already holds ACCESS EXCLUSIVE, and the explicit transaction guarantees the trigger
--    comes back if anything aborts.
-- ============================================================================
alter table public.inquiries disable trigger inquiries_before_write;

update public.inquiries
   set access_mode = case when is_exclusive then 'exclusive' else 'timed' end
 where access_mode is null;

alter table public.inquiries enable trigger inquiries_before_write;

alter table public.inquiries validate constraint inquiries_access_mode_check;
alter table public.inquiries validate constraint inquiries_access_mode_required;

-- ============================================================================
-- 3. The sync trigger — created AFTER the backfill, so the backfill can't be rewritten by it.
--
--    INSERT:
--      * a mode wins and derives is_exclusive;
--      * no mode + is_exclusive true → 'exclusive' (an old client);
--      * no mode on a non-draft → mapped from is_exclusive (an old client creating it live);
--      * a plain new draft (no mode, is_exclusive at its default false) keeps a null mode.
--    UPDATE:
--      * access_mode changed → derive is_exclusive;
--      * else is_exclusive changed → map it to the mode;
--      * else a row leaving draft with no mode → mapped from is_exclusive. This is the old
--        client's publish (`update({ status: 'open' })` on a draft it created without a mode).
--        Without it, every publish by a pre-GET-459 RN server — the window between this
--        migration and the server deploy, or a server rollback — would hit
--        inquiries_access_mode_required. The new server refuses a mode-less publish with a 400
--        before it writes (S1-AC2), so it never relies on this.
--      * a mode set back to null on a published row is NOT re-derived: the check refuses it.
--    is_exclusive is deprecated and dropped in a later cleanup ticket.
-- ============================================================================
create or replace function public.inquiries_access_mode_sync()
  returns trigger
  language plpgsql
  set search_path = public
as $$
begin
  if tg_op = 'INSERT' then
    if new.access_mode is not null then
      new.is_exclusive := (new.access_mode = 'exclusive');
    elsif new.is_exclusive then
      new.access_mode := 'exclusive';
    elsif new.status not in ('draft', 'archived') then
      new.access_mode := 'timed';
    end if;
    return new;
  end if;

  if new.access_mode is distinct from old.access_mode then
    new.is_exclusive := coalesce(new.access_mode = 'exclusive', false);
  elsif new.is_exclusive is distinct from old.is_exclusive then
    new.access_mode := case when new.is_exclusive then 'exclusive' else 'timed' end;
  elsif new.access_mode is null and new.status not in ('draft', 'archived') then
    new.access_mode := case when new.is_exclusive then 'exclusive' else 'timed' end;
  end if;
  return new;
end;
$$;

drop trigger if exists inquiries_access_mode_sync on public.inquiries;
create trigger inquiries_access_mode_sync
  before insert or update on public.inquiries
  for each row execute function public.inquiries_access_mode_sync();

-- ============================================================================
-- 4. insyts.release_price_cents — the price the insyt takes at release. Written at delivery by
--    submit-create-insyt: 0 for open mode, null otherwise (= keep the Insyter's price).
--    price_eur holds cents despite its name (submit-create-insyt writes price_cents into it).
-- ============================================================================
alter table public.insyts
  add column if not exists release_price_cents integer
    constraint insyts_release_price_cents_check
    check (release_price_cents is null or release_price_cents >= 0);

comment on column public.insyts.release_price_cents is
  'GET-459: price_eur (cents) at release. null = keep the Insyter''s price; 0 = free at release '
  '(open mode). Server-only: deliberately not granted to anon/authenticated.';

-- ============================================================================
-- 5. insyts.released_at — stamped exactly once by release_inquiry_insyt (step 7).
--    Backfilled for inquiry insyts that are already public (the GET-331 stage-5 flips), so the
--    lock and the UI state are true for old rows; the sweep doesn't need it (it filters on
--    visibility = 'private').
--    touch_insyts_updated_at is suppressed around the backfill — same defect get277 §3(b)
--    reproduced: it would give every backfilled row the identical updated_at and break the web
--    feed's `updated_at desc` sort, irreversibly. The ADD COLUMN already holds ACCESS EXCLUSIVE.
-- ============================================================================
alter table public.insyts add column if not exists released_at timestamptz;

comment on column public.insyts.released_at is
  'GET-459: when the inquiry insyt went public (purchase release or timed flip). The release '
  'idempotency key; with release_price_cents = 0 it also locks the price at €0. Server-only.';

alter table public.insyts disable trigger touch_insyts_updated_at;

update public.insyts
   set released_at = coalesce(published_at, updated_at)
 where inquiry_proposal_id is not null
   and visibility = 'public'
   and released_at is null;

alter table public.insyts enable trigger touch_insyts_updated_at;

-- ============================================================================
-- 6. purchases.opened_at — the first time the buyer opened the purchased insyt (§7.3).
--    Set by the RN server (service role) only while null, so it is naturally idempotent.
-- ============================================================================
alter table public.purchases add column if not exists opened_at timestamptz;

comment on column public.purchases.opened_at is
  'GET-459: first time the buyer opened this purchase; null = "New". Written by the RN server.';

-- ============================================================================
-- 7. release_inquiry_insyt(p_id) — THE release (§4). One conditional UPDATE:
--      * visibility = 'private' and released_at is null → idempotent: under READ COMMITTED a
--        second, concurrent call re-evaluates the WHERE on the committed row and returns no
--        row, so its caller sends no second notify (S4-AC3);
--      * status in PUBLISHED_STATUSES ('live', 'published', server
--        data/inquiry-public-flip-rules.ts) → a delivery draft is never released (the flipDue
--        guard);
--      * inquiry_proposal_id is not null → only an inquiry insyt, whatever id is passed;
--      * price_eur = coalesce(release_price_cents, price_eur) → €0 for open mode, the
--        Insyter's price for timed. This is why it is SQL and not a supabase-js update.
--    Returns the fields the server's side effects need (wantsMakePublic reads is_hidden).
--    The spec's `slug` is insyts.insyt_id (the public slug in /insyts/:id).
--    SECURITY DEFINER: it must write visibility, which no user may; EXECUTE is service_role
--    only (the RN server).
-- ============================================================================
create or replace function public.release_inquiry_insyt(p_id uuid)
  returns table (id uuid, insyt_id text, price_eur integer, is_hidden boolean, inquiry_proposal_id uuid)
  language sql
  security definer
  set search_path = public
as $$
  update public.insyts as i
     set visibility   = 'public',
         released_at  = now(),
         published_at = now(),
         price_eur    = coalesce(i.release_price_cents, i.price_eur)
   where i.id = p_id
     and i.visibility = 'private'
     and i.released_at is null
     and i.status in ('live', 'published')
     and i.inquiry_proposal_id is not null
  returning i.id, i.insyt_id::text, i.price_eur, i.is_hidden, i.inquiry_proposal_id;
$$;

comment on function public.release_inquiry_insyt(uuid) is
  'GET-459: release one private, published inquiry insyt (public, released_at, published_at, '
  'price = coalesce(release_price_cents, price_eur)). Returns no row when already released, '
  'unpublished or not private. service_role only.';

-- Supabase's default privileges grant EXECUTE on new public functions to anon/authenticated,
-- so revoking from PUBLIC alone is not enough.
revoke execute on function public.release_inquiry_insyt(uuid) from public, anon, authenticated;
grant execute on function public.release_inquiry_insyt(uuid) to service_role;

revoke execute on function public.inquiries_access_mode_sync() from public, anon, authenticated, service_role;

-- ============================================================================
-- 8. The sweep's index: private, unreleased inquiry insyts (§4 "Schedule trigger").
--    Not CONCURRENTLY: that can't run inside the transaction, the partial predicate keeps it
--    tiny, and get318 built insyts_inquiry_proposal_id_key the same way.
-- ============================================================================
create index if not exists insyts_inquiry_release_idx
  on public.insyts (visibility, released_at)
  where inquiry_proposal_id is not null;

commit;
