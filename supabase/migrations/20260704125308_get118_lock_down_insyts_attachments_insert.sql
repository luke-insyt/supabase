-- GET-118 (SF4 + SF7) — lock down INSERT on public.insyts + public.insyt_attachments.
--
-- Both tables had a permissive `WITH CHECK (true)` INSERT policy granted to `public`
-- plus table-level GRANT INSERT to anon/authenticated, so a client holding the
-- publishable key could insert arbitrary insyts / attachment rows (the latter is a
-- signed-URL-exfil primitive via get-insyt-content). All legitimate inserts go
-- through the service-role edge functions (create-insyt / submit-create-insyt),
-- which bypass RLS and keep their own grants — so this is backwards-compatible.
-- The frontend never inserts either table directly (verified). Non-destructive.

drop policy if exists "Service insert" on public.insyts;
drop policy if exists "Service insert attachments" on public.insyt_attachments;

revoke insert on public.insyts from anon, authenticated;
revoke insert on public.insyt_attachments from anon, authenticated;
