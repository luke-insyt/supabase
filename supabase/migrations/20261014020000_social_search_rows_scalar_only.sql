-- Social Search: rows keep only what is filtered, sorted or summed. Every
-- detail payload lives in the private social-search-traces bucket, at a path
-- derived from the row id:
--   searches/<id>/result.json.gz   what the user asked and got back
--   searches/<id>/trace.json.gz    the full research trace
-- The jsonb columns dropped below were copied there before this ran.
--
-- IRREVERSIBLE: the drops below can't be rolled back; the bucket copy is the
-- backup. Safe because only staging ever had these columns (3 rows, copied by
-- hand to searches/<id>/{result,trace}.json.gz on 2026-10-13 — see
-- webflow-app-documentation/features/social-search/implementation.md). Prod
-- never had social_searches, so on prod this runs against an empty, fresh table.

alter table public.social_searches
  add column cost_usd numeric(10, 4),
  add column config_version integer,
  add column parent_search_id uuid references public.social_searches (id) on delete set null;

comment on column public.social_searches.cost_usd is
  'Model tokens + Brave calls in USD, at the prices in the search configuration when it ran. Summed for the daily budget.';
comment on column public.social_searches.config_version is
  'The search configuration version (prompts, questions, prices) the search ran with.';
comment on column public.social_searches.parent_search_id is
  'The search this one re-ran with a change typed in the chat.';

-- Backfill at the prices the server used until now: USD per 1M tokens
-- Sonnet 5.5 2 in / 10 out, Haiku 5.5 0.10 in / 0.50 out; Brave $5 per 1,000 calls.
update public.social_searches
set cost_usd = round(
  (
    coalesce((tokens_by_model #>> '{claude-sonnet-5-5,tokensIn}')::numeric, 0) * 2
    + coalesce((tokens_by_model #>> '{claude-sonnet-5-5,tokensOut}')::numeric, 0) * 10
    + coalesce((tokens_by_model #>> '{claude-haiku-5-5,tokensIn}')::numeric, 0) * 0.10
    + coalesce((tokens_by_model #>> '{claude-haiku-5-5,tokensOut}')::numeric, 0) * 0.50
  ) / 1000000
  + coalesce(brave_calls, 0) * 0.005,
  4
)
where status <> 'running';

alter table public.social_searches
  drop column answers,
  drop column profile,
  drop column result,
  drop column stages,
  drop column tokens_by_model,
  drop column trace_path;

-- The daily budget and a user's history both read one user's latest rows.
create index social_searches_user_created_idx on public.social_searches (auth_user_id, created_at desc);
create index social_searches_parent_idx on public.social_searches (parent_search_id) where parent_search_id is not null;
