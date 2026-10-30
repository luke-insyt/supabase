-- GET-131 · Capture subscription payments — harden subscription_invoices + ground payout schema
-- Design: webflow-app-documentation/features/subscription-payments/feature.md (D1)
--
-- 1. Precondition guard: refuse to harden if out-of-contract rows exist.
--    (Prod §9 order: NULL-probe → delete + backfill → THEN this migration.)
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM public.subscription_invoices WHERE stripe_invoice_id IS NULL) THEN
    RAISE EXCEPTION 'NULL stripe_invoice_id rows present — resolve before hardening (GET-131 D1.1)';
  END IF;
  IF EXISTS (SELECT 1 FROM public.subscription_invoices WHERE status NOT IN ('paid', 'failed')) THEN
    RAISE EXCEPTION 'out-of-contract status values present — resolve before adding the CHECK';
  END IF;
END $$;

-- 2. Close the nullable-UNIQUE loophole (AC1: idempotency key must always exist).
ALTER TABLE public.subscription_invoices
  ALTER COLUMN stripe_invoice_id SET NOT NULL;

-- 3. Enforce the status contract (idempotent — ADD CONSTRAINT has no IF NOT EXISTS).
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'subscription_invoices_status_check'
      AND conrelid = 'public.subscription_invoices'::regclass
  ) THEN
    ALTER TABLE public.subscription_invoices
      ADD CONSTRAINT subscription_invoices_status_check CHECK (status IN ('paid', 'failed'));
  END IF;
END $$;

-- 4. Capture the drifted payout schema (no-op on live DBs — grounds fresh DBs / the repo).
--    DDL mirrored from the live staging DB via information_schema/pg_constraint, 2026-07-07.
CREATE TABLE IF NOT EXISTS public.creator_payouts (
  id bigint GENERATED ALWAYS AS IDENTITY,
  creator_auth_user_id uuid NOT NULL,
  amount_cents bigint NOT NULL,
  receipt_number text,
  paid_by_email text NOT NULL,
  paid_at timestamptz NOT NULL DEFAULT now(),
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT creator_payouts_pkey PRIMARY KEY (id),
  CONSTRAINT creator_payouts_creator_auth_user_id_fkey
    FOREIGN KEY (creator_auth_user_id) REFERENCES public.users (auth_user_id),
  CONSTRAINT creator_payouts_amount_cents_check CHECK (amount_cents >= 0),
  CONSTRAINT creator_payouts_receipt_number_check CHECK (char_length(receipt_number) <= 64)
);
CREATE INDEX IF NOT EXISTS creator_payouts_creator_idx
  ON public.creator_payouts (creator_auth_user_id, paid_at DESC);
ALTER TABLE public.creator_payouts ENABLE ROW LEVEL SECURITY;

CREATE TABLE IF NOT EXISTS public.creator_payout_items (
  id bigint GENERATED ALWAYS AS IDENTITY,
  payout_id bigint NOT NULL,
  source text NOT NULL DEFAULT 'purchase',
  purchase_id bigint,
  stripe_payment_id text,
  amount_cents bigint NOT NULL DEFAULT 0,
  CONSTRAINT creator_payout_items_pkey PRIMARY KEY (id),
  CONSTRAINT creator_payout_items_payout_id_fkey
    FOREIGN KEY (payout_id) REFERENCES public.creator_payouts (id) ON DELETE CASCADE,
  CONSTRAINT creator_payout_items_purchase_id_fkey
    FOREIGN KEY (purchase_id) REFERENCES public.purchases (id),
  CONSTRAINT creator_payout_items_source_check
    CHECK (source = ANY (ARRAY['purchase'::text, 'subscription'::text])),
  CONSTRAINT creator_payout_items_amount_cents_check CHECK (amount_cents >= 0),
  CONSTRAINT payout_items_has_reference
    CHECK ((purchase_id IS NOT NULL) OR (stripe_payment_id IS NOT NULL)),
  CONSTRAINT payout_items_purchase_once UNIQUE (purchase_id),
  CONSTRAINT payout_items_stripe_once UNIQUE (stripe_payment_id)
);
CREATE INDEX IF NOT EXISTS creator_payout_items_payout_idx
  ON public.creator_payout_items (payout_id);
ALTER TABLE public.creator_payout_items ENABLE ROW LEVEL SECURITY;

-- 5. No-double-payout guarantee (AC5): the live table already carries
--    payout_items_stripe_once UNIQUE (stripe_payment_id) — a FULL unique constraint, strictly
--    stronger than the design's planned partial index (creator_payout_items_sub_invoice_uniq),
--    which is therefore intentionally NOT created (it would be a redundant duplicate index).

-- 6. OQ2: payout currency (per-item, follows the invoice's currency).
ALTER TABLE public.creator_payout_items
  ADD COLUMN IF NOT EXISTS currency text NOT NULL DEFAULT 'eur';
