-- GET-458 Part C1: proof of the EU VIES check for B2B (reverse-charge) purchases.
-- Written by the n8n "GetInsyt Purchase Completed" workflow after its existing
-- purchases insert, and by the daily "VAT ID recheck" workflow. All nullable and
-- additive: a purchase with no VAT ID keeps every column null.
alter table public.purchases
  add column if not exists vat_id              text,
  add column if not exists vat_country         text,
  -- 'valid' | 'invalid' | 'unavailable'; null = no VAT ID given at checkout
  add column if not exists vat_status          text,
  add column if not exists vat_company_name    text,
  add column if not exists vat_company_address text,
  add column if not exists vat_checked_at      timestamptz,
  add column if not exists vat_check_attempts  int default 0;
