-- GET-123 (SF3) — scope insyt_status reads to the owning creator; block anon.
--
-- insyt_status (renamed from insyt_errors) had a public read policy
-- `insyt_status_select_all USING (true)`, so anon could dump every creator's
-- creator_email + free-form error details via GET /rest/v1/insyt_status?select=*.
--
-- Replace it with an owner-scoped policy (an authenticated creator sees only their
-- own rows, matched on creator_email = their JWT email) and REVOKE the anon SELECT
-- grant. Safe for the publish-progress poll: create-insyt-native polls by
-- correlation_id AS the authenticated creator, and the create-insyt edge fn ALWAYS
-- writes creator_email (verified: 0 null of 276 rows), so the creator still sees
-- their own status rows. Writes are unaffected — the edge fn uses the service role,
-- which bypasses RLS.
drop policy if exists insyt_status_select_all on public.insyt_status;

create policy own_status_read on public.insyt_status
  for select to authenticated
  using (creator_email = (auth.jwt() ->> 'email'));

revoke select on public.insyt_status from anon;
