-- GET-150 (correction): keep insyt_ratings writes LOCKED to service_role.
--
-- An earlier step in this ticket briefly added user-scoped INSERT/UPDATE
-- policies so the RN server could write ratings user-scoped. That was wrong:
-- with the anon key + a user JWT it lets the browser write insyt_ratings
-- DIRECTLY via PostgREST, bypassing the purchase/subscription eligibility gate
-- that insyt-rating-features.md §3.2 deliberately centralises in the trusted
-- writers. Ratings are now written by the RN server's upsertRating with
-- SERVICE-ROLE after it runs the same eligibility check as the web
-- submit-insyt-rating edge fn — so no user-scoped write policy is needed. Drop
-- them, restoring "only service_role can mutate insyt_ratings".
drop policy if exists "insyt_ratings_insert_own" on public.insyt_ratings;
drop policy if exists "insyt_ratings_update_own" on public.insyt_ratings;
