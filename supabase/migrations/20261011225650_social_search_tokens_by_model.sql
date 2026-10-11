-- Social Search (prototype, admin-only): token totals per model, so the admin
-- list can price each search (models are priced differently). Shape:
-- { "<model id>": { "calls": n, "tokensIn": n, "tokensOut": n } }.
-- Rows saved before this column were backfilled from their trace files on staging;
-- the detail endpoint also rebuilds a missing split from the trace.
ALTER TABLE public.social_searches
  ADD COLUMN IF NOT EXISTS tokens_by_model jsonb NOT NULL DEFAULT '{}'::jsonb;
