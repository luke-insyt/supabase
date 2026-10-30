-- GET-116 (SF1) — CORRECTION to 20260704124405_get116_revoke_paid_columns_from_anon.sql.
--
-- That migration ran `REVOKE SELECT (body_html, video_url) … FROM anon, authenticated`,
-- but it had NO effect: `anon`/`authenticated` also hold a **table-level** `GRANT SELECT
-- ON public.insyts` (all columns), and in PostgreSQL a table-wide SELECT grant lets a
-- role read every column regardless of column-level REVOKEs. Verified live: after the
-- column REVOKE, `GET /rest/v1/insyts?select=body_html` with the anon publishable key
-- still returned the paid body_html (HTTP 200) — the paywall bypass was still open.
--
-- Correct fix: drop the table-level SELECT, then GRANT SELECT back on ONLY the non-paid
-- columns. Paid content (body_html, video_url) then has neither a table nor a column
-- grant for anon/authenticated, so PostgREST returns 42501 — paid text/video are
-- reachable ONLY via the service-role get-insyt-content edge fn (which gates on
-- purchase / active subscription / creator-owner). RLS (row visibility) is untouched.
--
-- The re-granted column list is exactly the live set MINUS body_html/video_url, so every
-- non-paid read (feed, my-insyts, insyt-detail, the create-editor prefill of non-paid
-- fields) is unaffected. Idempotent; no data change.
--
-- ⚠️ Column-list assumption: this GRANT enumerates the columns present when authored
-- (2026-07-04). If a later migration ADDS a column to public.insyts, remember to grant
-- SELECT on it to anon/authenticated too (a new column is ungranted by default now that
-- the table-wide grant is gone) — or reads of that column will 42501.

revoke select on public.insyts from anon, authenticated;

grant select (
  id, title, abstract, content_type, sport, storage_path, thumbnail_url, price_eur,
  stripe_product_id, stripe_price_id, stripe_payment_link_url, stripe_payment_link_id,
  webflow_item_id, status, created_at, creator_email, insyt_id, tags, updated_at,
  is_hidden, video_storage_path, read_time_min, correlation_id, creator_display_name,
  search_vector, creator_auth_user_id, rating_avg, rating_count, view_count
) on public.insyts to anon, authenticated;

-- Belt + braces: clear any residual column-level SELECT on the paid columns.
revoke select (body_html, video_url) on public.insyts from anon, authenticated;
