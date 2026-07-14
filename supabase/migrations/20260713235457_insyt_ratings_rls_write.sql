-- GET-150: allow an authenticated user to upsert their OWN insyt rating.
--
-- insyt_ratings had RLS enabled but ONLY a SELECT policy, so a user-scoped
-- client (role `authenticated`) was denied INSERT/UPDATE. The web app dodged
-- this by writing via the `submit-insyt-rating` edge function (service role,
-- bypasses RLS); the RN server writes user-scoped (`supabaseForUser`), so every
-- rating from the RN app was denied and the star never filled ("can't select a
-- star value"). These policies let a user write only their own row
-- (user_id = auth.uid()); the PK (insyt_id, user_id) still owns "one rating per
-- user". Idempotent (drop-then-create).
drop policy if exists "insyt_ratings_insert_own" on public.insyt_ratings;
create policy "insyt_ratings_insert_own" on public.insyt_ratings
  for insert to authenticated
  with check (user_id = auth.uid());

drop policy if exists "insyt_ratings_update_own" on public.insyt_ratings;
create policy "insyt_ratings_update_own" on public.insyt_ratings
  for update to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());
