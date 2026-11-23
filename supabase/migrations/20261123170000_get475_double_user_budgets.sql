-- GET-475 (follow-up, staging-gatekeeper 2026-11-23): budgets now count in USER PRICE (our cost × 2 by
-- default). Per-user budgets were set by admins as our-cost amounts, so without this every raised budget would
-- silently allow half of what it did. Double each budget set before the switch, once.
--
-- Idempotent: only rows last changed before the switch (2026-11-23 17:00 UTC) are doubled, and each doubled
-- row gets updated_at = now(), so a second run changes nothing; a budget an admin sets after the switch is
-- already in user price and is left alone.
update public.social_search_budgets
   set daily_budget_usd = round(daily_budget_usd * 2, 2),
       updated_at = now(),
       updated_by = 'GET-475 migration: ×2 (budgets count in user price)'
 where updated_at < timestamptz '2026-11-23 17:00:00+00';
