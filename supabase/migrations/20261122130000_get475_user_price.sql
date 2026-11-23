-- GET-475 (Player search: users see a price at 2× our cost; admins see both). Every cost record keeps two
-- numbers: cost_usd = what we pay the providers (unchanged), user_price_usd = what the user is charged
-- (cost_usd × the search config's priceMultiplier when the row is written; 2 = a 50% margin). Budgets
-- count in user price. Non-admin API responses never carry cost_usd (the server strips it).
--
-- Existing rows are backfilled at the default multiplier (cost_usd × 2, AC6). Scalar columns only, like
-- every Search table; RLS unchanged (server-only, no grants). Re-runnable.

alter table public.social_searches
  add column if not exists user_price_usd numeric(10, 4) check (user_price_usd is null or user_price_usd >= 0);
comment on column public.social_searches.user_price_usd is
  'GET-475: what the user was charged for this search (cost_usd × the config priceMultiplier when written). Users see only this.';

alter table public.social_search_clarify_rounds
  add column if not exists user_price_usd numeric(10, 4) check (user_price_usd is null or user_price_usd >= 0);
comment on column public.social_search_clarify_rounds.user_price_usd is
  'GET-475: what the user was charged for this follow-up round (cost_usd × the config priceMultiplier when written).';

alter table public.social_search_extra_costs
  add column if not exists user_price_usd numeric(10, 4) check (user_price_usd is null or user_price_usd >= 0);
comment on column public.social_search_extra_costs.user_price_usd is
  'GET-475: what the user was charged for this extra cost, e.g. a profile brief (cost_usd × the config priceMultiplier when written).';

-- AC6: existing rows at the default 50% margin
update public.social_searches set user_price_usd = round(cost_usd * 2, 4) where user_price_usd is null and cost_usd is not null;
update public.social_search_clarify_rounds set user_price_usd = round(cost_usd * 2, 4) where user_price_usd is null;
update public.social_search_extra_costs set user_price_usd = round(cost_usd * 2, 4) where user_price_usd is null;
